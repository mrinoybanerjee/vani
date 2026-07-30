import ApplicationServices
import Foundation

struct TextInsertionRead: Equatable {
  let observation: TextInsertionObservation
  let insertedText: String?
  let isSecureTextField: Bool
}

@MainActor
protocol TextInsertionEnvironment: AnyObject {
  var canPostPaste: Bool { get }

  func read(target: TextTarget, insertedRange: NSRange?) -> TextInsertionRead?
  func postPasteShortcut(
    to processIdentifier: Int32,
    interval: Duration,
    beforePaste: @MainActor () throws -> Void
  ) async throws -> Bool
}

enum AccessibilityFocusResolver {
  static func focusedElement(for processIdentifier: Int32) -> AXUIElement? {
    let application = AXUIElementCreateApplication(processIdentifier)
    if let element = focusedElement(on: application),
      belongsToProcess(element, processIdentifier: processIdentifier)
    {
      return element
    }

    guard let element = focusedElement(on: AXUIElementCreateSystemWide()),
      belongsToProcess(element, processIdentifier: processIdentifier)
    else {
      return nil
    }
    return element
  }

  static func isSecureTextField(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSubroleAttribute as CFString,
        &value
      ) == .success,
      let subrole = value as? String
    else {
      return false
    }
    return subrole == (kAXSecureTextFieldSubrole as String)
  }

  private static func focusedElement(on owner: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        owner,
        kAXFocusedUIElementAttribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private static func belongsToProcess(
    _ element: AXUIElement,
    processIdentifier: Int32
  ) -> Bool {
    var owner: pid_t = 0
    return AXUIElementGetPid(element, &owner) == .success
      && owner == processIdentifier
  }
}

@MainActor
final class SystemTextInsertionEnvironment: TextInsertionEnvironment {
  private static let commandKeyCode: CGKeyCode = 55
  private static let vKeyCode: CGKeyCode = 9
  private static let maximumReadableValueCharacters = 1_000_000

  var canPostPaste: Bool {
    CGPreflightPostEventAccess()
  }

  func read(target: TextTarget, insertedRange: NSRange?) -> TextInsertionRead? {
    guard AXIsProcessTrusted() else { return nil }
    guard
      let element = AccessibilityFocusResolver.focusedElement(
        for: target.processIdentifier
      )
    else {
      return nil
    }

    let characterCount = integerAttribute(
      kAXNumberOfCharactersAttribute as CFString,
      on: element
    )
    let value: String? =
      if characterCount.map({ $0 <= Self.maximumReadableValueCharacters }) != false {
        readableValue(of: element)
      } else {
        nil
      }

    return TextInsertionRead(
      observation: TextInsertionObservation(
        value: value,
        selectedRange: selectedTextRange(of: element),
        characterCount: characterCount
      ),
      insertedText: insertedRange.flatMap { string(in: $0, on: element) },
      isSecureTextField: AccessibilityFocusResolver.isSecureTextField(element)
    )
  }

  func postPasteShortcut(
    to processIdentifier: Int32,
    interval: Duration,
    beforePaste: @MainActor () throws -> Void
  ) async throws -> Bool {
    guard canPostPaste else { return false }
    guard let source = CGEventSource(stateID: .privateState),
      let commandDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: Self.commandKeyCode,
        keyDown: true
      ),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: Self.vKeyCode,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: Self.vKeyCode,
        keyDown: false
      ),
      let commandUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: Self.commandKeyCode,
        keyDown: false
      )
    else {
      return false
    }

    commandDown.flags = .maskCommand
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    commandUp.flags = []

    let sequence = PasteKeySequence(
      processIdentifier: processIdentifier,
      commandDown: commandDown,
      keyDown: keyDown,
      keyUp: keyUp,
      commandUp: commandUp
    )
    return try await withTaskCancellationHandler {
      defer { sequence.releasePressedKeys() }

      guard sequence.postCommandDown() else { throw CancellationError() }
      if interval > .zero {
        try await Task.sleep(for: interval)
      }

      try beforePaste()
      guard sequence.postKeyDown() else { throw CancellationError() }
      if interval > .zero {
        try await Task.sleep(for: interval)
      }

      sequence.postKeyUp()
      if interval > .zero {
        try await Task.sleep(for: interval)
      }

      sequence.postCommandUp()
      return true
    } onCancel: {
      sequence.cancelAndReleasePressedKeys()
    }
  }

  private func readableValue(of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXValueAttribute as CFString,
        &value
      ) == .success
    else {
      return nil
    }
    return SystemTextInserter.readableString(from: value)
  }

  private func selectedTextRange(of element: AXUIElement) -> NSRange? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }

    var range = CFRange()
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cfRange,
      AXValueGetValue(axValue, .cfRange, &range)
    else {
      return nil
    }
    return NSRange(location: range.location, length: range.length)
  }

  private func integerAttribute(_ attribute: CFString, on element: AXUIElement) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return (value as? NSNumber)?.intValue
  }

  private func string(in range: NSRange, on element: AXUIElement) -> String? {
    var cfRange = CFRange(location: range.location, length: range.length)
    guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }

    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXStringForRangeParameterizedAttribute as CFString,
        rangeValue,
        &value
      ) == .success
    else {
      return nil
    }
    return SystemTextInserter.readableString(from: value)
  }
}

/// Serializes synthetic key state so cancellation can release modifiers immediately.
final class PasteKeySequence: @unchecked Sendable {
  typealias EventPoster = @Sendable (CGEvent, Int32) -> Void

  private let lock = NSLock()
  private let processIdentifier: Int32
  private let commandDown: CGEvent
  private let keyDown: CGEvent
  private let keyUp: CGEvent
  private let commandUp: CGEvent
  private let post: EventPoster
  private var isCancelled = false
  private var commandIsDown = false
  private var keyIsDown = false

  init(
    processIdentifier: Int32,
    commandDown: CGEvent,
    keyDown: CGEvent,
    keyUp: CGEvent,
    commandUp: CGEvent,
    post: @escaping EventPoster = { event, processIdentifier in
      event.postToPid(processIdentifier)
    }
  ) {
    self.processIdentifier = processIdentifier
    self.commandDown = commandDown
    self.keyDown = keyDown
    self.keyUp = keyUp
    self.commandUp = commandUp
    self.post = post
  }

  func postCommandDown() -> Bool {
    lock.withLock {
      guard !isCancelled else { return false }
      post(commandDown, processIdentifier)
      commandIsDown = true
      return true
    }
  }

  func postKeyDown() -> Bool {
    lock.withLock {
      guard !isCancelled else { return false }
      post(keyDown, processIdentifier)
      keyIsDown = true
      return true
    }
  }

  func postKeyUp() {
    lock.withLock {
      guard keyIsDown else { return }
      post(keyUp, processIdentifier)
      keyIsDown = false
    }
  }

  func postCommandUp() {
    lock.withLock {
      guard commandIsDown else { return }
      post(commandUp, processIdentifier)
      commandIsDown = false
    }
  }

  func cancelAndReleasePressedKeys() {
    lock.withLock {
      isCancelled = true
      releasePressedKeysLocked()
    }
  }

  func releasePressedKeys() {
    lock.withLock {
      releasePressedKeysLocked()
    }
  }

  private func releasePressedKeysLocked() {
    if keyIsDown {
      post(keyUp, processIdentifier)
      keyIsDown = false
    }
    if commandIsDown {
      post(commandUp, processIdentifier)
      commandIsDown = false
    }
  }
}
