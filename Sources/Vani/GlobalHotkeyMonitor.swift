import ApplicationServices
import CoreGraphics
import Foundation
import VaniCore

@MainActor
final class GlobalHotkeyMonitor {
  var onPress: (() -> Void)?
  var onRelease: (() -> Void)?

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var shortcut: HoldShortcut = .function
  private var isPressed = false

  func start(shortcut: HoldShortcut) throws {
    stop()
    guard AXIsProcessTrusted() else {
      throw VaniFailure.accessibilityPermissionDenied
    }

    self.shortcut = shortcut
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
      throw VaniFailure.accessibilityPermissionDenied
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
  }

  func stop() {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
    }
    runLoopSource = nil
    eventTap = nil
    isPressed = false
  }

  private func handle(
    typeRawValue: UInt32,
    keyCode: Int64,
    keyStateIsPressed: Bool,
    functionModifierIsSet: Bool
  ) {
    guard let type = CGEventType(rawValue: typeRawValue) else { return }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return
    }
    guard type == .flagsChanged, keyCode == shortcut.keyCode else { return }
    let keyIsPressed = shortcut.resolvedPressedState(
      keyStateIsPressed: keyStateIsPressed,
      functionModifierIsSet: functionModifierIsSet
    )

    guard keyIsPressed != isPressed else { return }
    isPressed = keyIsPressed
    if keyIsPressed {
      onPress?()
    } else {
      onRelease?()
    }
  }

  private static let callback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalHotkeyMonitor>
      .fromOpaque(userInfo)
      .takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let keyStateIsPressed = CGEventSource.keyState(
      .combinedSessionState,
      key: CGKeyCode(keyCode)
    )
    let functionModifierIsSet = event.flags.contains(.maskSecondaryFn)
    let typeRawValue = type.rawValue

    Task { @MainActor in
      monitor.handle(
        typeRawValue: typeRawValue,
        keyCode: keyCode,
        keyStateIsPressed: keyStateIsPressed,
        functionModifierIsSet: functionModifierIsSet
      )
    }
    return Unmanaged.passUnretained(event)
  }
}

extension HoldShortcut {
  fileprivate var keyCode: Int64 {
    switch self {
    case .rightOption: 61
    case .rightCommand: 54
    case .function: 63
    }
  }
}
