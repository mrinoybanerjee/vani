import ApplicationServices
import Foundation

struct TextInsertionRead: Equatable {
  let observation: TextInsertionObservation
  let insertedText: String?
}

@MainActor
protocol TextInsertionEnvironment: AnyObject {
  var canPostPaste: Bool { get }

  func read(target: TextTarget, insertedRange: NSRange?) -> TextInsertionRead?
  func postPasteShortcut(to processIdentifier: Int32, interval: Duration) async -> Bool
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

    return TextInsertionRead(
      observation: TextInsertionObservation(
        value: readableValue(of: element),
        selectedRange: selectedTextRange(of: element),
        characterCount: integerAttribute(
          kAXNumberOfCharactersAttribute as CFString,
          on: element
        )
      ),
      insertedText: insertedRange.flatMap { string(in: $0, on: element) }
    )
  }

  func postPasteShortcut(
    to processIdentifier: Int32,
    interval: Duration
  ) async -> Bool {
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

    let events = [commandDown, keyDown, keyUp, commandUp]
    for (index, event) in events.enumerated() {
      event.postToPid(processIdentifier)
      if index < events.count - 1, interval > .zero {
        try? await Task.sleep(for: interval)
      }
    }
    return true
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
