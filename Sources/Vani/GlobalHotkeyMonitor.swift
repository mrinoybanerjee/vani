import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VaniCore
import os

private let escapeKeyCode: Int64 = 53

@MainActor
final class GlobalHotkeyMonitor {
  var onPress: (() -> Void)?
  var onRelease: (() -> Void)?
  var onPasteLast: (() -> Void)?
  var onCopyLast: (() -> Void)?
  /// Escape, without modifiers. The listen-only tap never consumes the key.
  var onEscape: (() -> Void)?
  /// Any other key pressed while the hold shortcut is down: the user is typing a
  /// chord such as Fn-Delete or Control-C, not dictating.
  var onKeyDuringHold: (() -> Void)?

  /// Read from the event-tap callback, which is not actor-isolated.
  nonisolated let lastTranscriptBinding = OSAllocatedUnfairLock(
    initialState: LastTranscriptBinding.controlCommand)
  /// Set by the coordinator while a recording is starting or active, so the callback
  /// forwards Escape only when it can cancel something.
  nonisolated let recordingActive = OSAllocatedUnfairLock(initialState: false)
  private nonisolated let holdDown = OSAllocatedUnfairLock(initialState: false)
  private var isPressed = false {
    didSet {
      let pressed = isPressed
      holdDown.withLock { $0 = pressed }
    }
  }

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var shortcut: HoldShortcut = .function

  func start(shortcut: HoldShortcut) throws {
    if self.shortcut == shortcut,
      let eventTap,
      CFMachPortIsValid(eventTap),
      globalMonitor != nil,
      localMonitor != nil
    {
      return
    }

    if isPressed {
      isPressed = false
      VaniLog.event(category: .capture, code: "shortcut_released_before_reconfigure")
      onRelease?()
    }
    stop()
    guard AXIsProcessTrusted() else {
      throw VaniFailure.accessibilityPermissionDenied
    }
    guard CGPreflightListenEventAccess() else {
      throw VaniFailure.inputMonitoringPermissionDenied
    }

    self.shortcut = shortcut
    let mask =
      CGEventMask(1 << CGEventType.flagsChanged.rawValue)
      | CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: Self.callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      throw VaniFailure.inputMonitoringPermissionDenied
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
    installAppKitMonitors()
    guard globalMonitor != nil, localMonitor != nil else {
      stop()
      throw VaniFailure.inputMonitoringPermissionDenied
    }
  }

  func stop() {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
    }
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
    }
    runLoopSource = nil
    eventTap = nil
    globalMonitor = nil
    localMonitor = nil
    isPressed = false
  }

  private func installAppKitMonitors() {
    // AppKit covers Fn transitions that some keyboards omit from the CGEvent tap.
    // isPressed deduplicates events observed by both paths.
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      let keyCode = Int64(event.keyCode)
      let functionModifierIsSet = event.modifierFlags.contains(.function)
      let commandModifierIsSet = event.modifierFlags.contains(.command)
      Task { @MainActor [weak self] in
        self?.handleModifierEvent(
          keyCode: keyCode,
          functionModifierIsSet: functionModifierIsSet,
          commandModifierIsSet: commandModifierIsSet
        )
      }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      let keyCode = Int64(event.keyCode)
      let functionModifierIsSet = event.modifierFlags.contains(.function)
      let commandModifierIsSet = event.modifierFlags.contains(.command)
      Task { @MainActor [weak self] in
        self?.handleModifierEvent(
          keyCode: keyCode,
          functionModifierIsSet: functionModifierIsSet,
          commandModifierIsSet: commandModifierIsSet
        )
      }
      return event
    }
  }

  private func handleModifierEvent(
    keyCode: Int64,
    functionModifierIsSet: Bool,
    commandModifierIsSet: Bool
  ) {
    let keyStateIsPressed = CGEventSource.keyState(
      .combinedSessionState,
      key: CGKeyCode(keyCode)
    )
    handle(
      typeRawValue: CGEventType.flagsChanged.rawValue,
      keyCode: keyCode,
      keyStateIsPressed: keyStateIsPressed,
      functionModifierIsSet: functionModifierIsSet,
      commandModifierIsSet: commandModifierIsSet
    )
  }

  private func handle(
    typeRawValue: UInt32,
    keyCode: Int64,
    keyStateIsPressed: Bool,
    functionModifierIsSet: Bool,
    commandModifierIsSet: Bool
  ) {
    guard let type = CGEventType(rawValue: typeRawValue) else { return }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return
    }
    if type == .flagsChanged,
      shortcut.yieldsToCommandChord(
        keyCode: keyCode,
        keyStateIsPressed: keyStateIsPressed,
        commandModifierIsSet: commandModifierIsSet
      )
    {
      if isPressed {
        isPressed = false
        VaniLog.event(category: .capture, code: "shortcut_yielded_to_command_chord")
        onRelease?()
      }
      return
    }
    guard type == .flagsChanged, shortcut.matchesModifierEvent(keyCode: keyCode) else {
      return
    }
    let keyIsPressed = shortcut.resolvedPressedState(
      keyStateIsPressed: keyStateIsPressed,
      functionModifierIsSet: functionModifierIsSet
    )

    guard keyIsPressed != isPressed else { return }
    isPressed = keyIsPressed
    VaniLog.event(
      category: .capture,
      code: keyIsPressed ? "shortcut_pressed" : "shortcut_released"
    )
    if keyIsPressed {
      onPress?()
    } else {
      onRelease?()
    }
  }

  private func handleKeyDown(keyCode: Int64, isRepeat: Bool, hasCommandOrControl: Bool) {
    if keyCode == escapeKeyCode, !isRepeat, !hasCommandOrControl {
      onEscape?()
      return
    }
    if isPressed {
      VaniLog.event(category: .capture, code: "shortcut_chord_detected")
      onKeyDuringHold?()
    }
  }

  private func handleLastTranscriptShortcut(_ action: LastTranscriptShortcutAction) {
    switch action {
    case .paste:
      VaniLog.event(category: .insertion, code: "paste_last_shortcut")
      onPasteLast?()
    case .copy:
      VaniLog.event(category: .recovery, code: "copy_last_shortcut")
      onCopyLast?()
    }
  }

  private static let callback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalHotkeyMonitor>
      .fromOpaque(userInfo)
      .takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let typeRawValue = type.rawValue

    if type == .keyDown {
      let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
      if let action = LastTranscriptShortcutResolver.action(
        keyCode: keyCode,
        modifierFlagsRawValue: event.flags.rawValue,
        isRepeat: isRepeat,
        binding: monitor.lastTranscriptBinding.withLock { $0 }
      ) {
        Task { @MainActor in
          monitor.handleLastTranscriptShortcut(action)
        }
        return Unmanaged.passUnretained(event)
      }
      // Ordinary typing never leaves the callback. Only a key code and modifier
      // presence cross to the main actor, and only during a hold or recording.
      let isEscape = keyCode == escapeKeyCode
      guard monitor.holdDown.withLock({ $0 })
        || (isEscape && monitor.recordingActive.withLock({ $0 }))
      else { return Unmanaged.passUnretained(event) }
      let hasCommandOrControl =
        event.flags.contains(.maskCommand) || event.flags.contains(.maskControl)
      Task { @MainActor in
        monitor.handleKeyDown(
          keyCode: keyCode, isRepeat: isRepeat, hasCommandOrControl: hasCommandOrControl)
      }
      return Unmanaged.passUnretained(event)
    }

    let commandModifierIsSet = event.flags.contains(.maskCommand)
    Task { @MainActor in
      let keyStateIsPressed = CGEventSource.keyState(
        .combinedSessionState,
        key: CGKeyCode(keyCode)
      )
      let functionModifierIsSet = CGEventSource.flagsState(
        .combinedSessionState
      ).contains(.maskSecondaryFn)
      monitor.handle(
        typeRawValue: typeRawValue,
        keyCode: keyCode,
        keyStateIsPressed: keyStateIsPressed,
        functionModifierIsSet: functionModifierIsSet,
        commandModifierIsSet: commandModifierIsSet
      )
    }
    return Unmanaged.passUnretained(event)
  }
}
