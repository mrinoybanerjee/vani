import AppKit
import ApplicationServices
import Foundation

struct TextInsertionObservation: Equatable {
  let value: String?
  let selectedRange: NSRange?
  let characterCount: Int?
}

private enum TextInsertionEvidence: String {
  case exactValue = "exact_value"
  case valueAtRange = "value_at_range"
  case changedValue = "changed_value"
  case parameterizedRange = "parameterized_range"
  case cursorAndCount = "cursor_and_count"
  case cursorMovement = "cursor_movement"
}

@MainActor
public final class SystemTextInserter: TextInserting {
  private let focusProvider: any FocusProviding
  private let pasteDelay: Duration
  private let verificationTimeout: Duration
  private let verificationPollInterval: Duration

  public init(
    focusProvider: any FocusProviding = SystemFocusProvider(),
    pasteDelay: Duration = .milliseconds(140),
    verificationTimeout: Duration = .milliseconds(600),
    verificationPollInterval: Duration = .milliseconds(50)
  ) {
    self.focusProvider = focusProvider
    self.pasteDelay = pasteDelay
    self.verificationTimeout = verificationTimeout
    self.verificationPollInterval = verificationPollInterval
  }

  public func insert(
    _ text: String,
    into target: TextTarget?
  ) async throws -> TextInsertionResult {
    guard !text.isEmpty else { throw VaniFailure.emptyTranscript }
    try verifyFocus(target)

    if AXIsProcessTrusted(), let element = focusedElement() {
      try verifyElement(element, matches: target)
      return try await pasteAndVerify(
        text,
        target: target,
        element: element,
        before: observation(of: element)
      )
    }

    try copyForManualPaste(text)
    return .manualPasteRequired
  }

  public func copyForManualPaste(_ text: String) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      throw VaniFailure.insertionFailed
    }
  }

  private func pasteAndVerify(
    _ text: String,
    target: TextTarget?,
    element: AXUIElement,
    before: TextInsertionObservation
  ) async throws -> TextInsertionResult {
    let pasteboard = NSPasteboard.general
    let original = PasteboardSnapshot.capture(from: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      throw VaniFailure.insertionFailed
    }
    let transcriptChangeCount = pasteboard.changeCount

    guard postPasteShortcut(to: target?.processIdentifier) else {
      return .manualPasteRequired
    }

    try await Task.sleep(for: pasteDelay)
    try verifyFocus(target)

    guard
      let evidence = try await waitForInsertion(
        text,
        before: before,
        initialElement: element,
        target: target,
        initialDelay: .zero
      )
    else {
      if pasteboard.changeCount != transcriptChangeCount {
        throw VaniFailure.clipboardChanged
      }
      VaniLog.event(category: .insertion, code: "paste_unverified")
      return .unverifiedClipboardPreserved
    }
    VaniLog.event(category: .insertion, code: "paste_verified_\(evidence.rawValue)")

    guard pasteboard.changeCount == transcriptChangeCount else {
      return .verifiedClipboardPreserved
    }
    return original.restore(to: pasteboard)
      ? .verified
      : .verifiedClipboardPreserved
  }

  private func verifyFocus(_ target: TextTarget?) throws {
    guard let target else { return }
    guard let current = focusProvider.currentTarget(),
      current.processIdentifier == target.processIdentifier,
      target.focusedElementIdentifier == nil
        || current.focusedElementIdentifier == target.focusedElementIdentifier
    else {
      throw VaniFailure.focusChanged
    }
  }

  private func verifyElement(_ element: AXUIElement, matches target: TextTarget?) throws {
    guard let expected = target?.focusedElementIdentifier else { return }
    guard CFHash(element) == expected else {
      throw VaniFailure.focusChanged
    }
  }

  private func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedUIElementAttribute as CFString,
        &value
      ) == .success
    else {
      return nil
    }
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
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
    return Self.readableString(from: value)
  }

  static func readableString(from value: Any?) -> String? {
    if let string = value as? String {
      return string
    }
    if let attributedString = value as? NSAttributedString {
      return attributedString.string
    }
    return nil
  }

  static func verifyInsertion(
    _ text: String,
    before: TextInsertionObservation,
    after: TextInsertionObservation,
    insertedText: String?
  ) -> Bool {
    insertionEvidence(
      text,
      before: before,
      after: after,
      insertedText: insertedText
    ) != nil
  }

  private static func insertionEvidence(
    _ text: String,
    before: TextInsertionObservation,
    after: TextInsertionObservation,
    insertedText: String?
  ) -> TextInsertionEvidence? {
    let insertedLength = text.utf16.count
    if let beforeValue = before.value,
      let afterValue = after.value
    {
      if let selectedRange = before.selectedRange,
        NSMaxRange(selectedRange) <= (beforeValue as NSString).length
      {
        let expectedValue = (beforeValue as NSString).replacingCharacters(
          in: selectedRange,
          with: text
        )
        if afterValue == expectedValue {
          return .exactValue
        }
        if beforeValue != afterValue,
          valueShowsInsertion(
            text,
            selectedRange: selectedRange,
            beforeValue: beforeValue,
            afterValue: afterValue
          )
        {
          return .valueAtRange
        }
      } else if beforeValue != afterValue, afterValue.contains(text) {
        return .changedValue
      }
    }

    let contentStateChanged =
      before.value != after.value || before.characterCount != after.characterCount
    if insertedText == text, contentStateChanged {
      return .parameterizedRange
    }

    guard let beforeRange = before.selectedRange,
      let afterRange = after.selectedRange,
      afterRange.location == beforeRange.location + insertedLength,
      afterRange.length == 0
    else {
      return nil
    }

    guard let beforeCount = before.characterCount,
      let afterCount = after.characterCount
    else {
      return .cursorMovement
    }
    return afterCount == beforeCount - beforeRange.length + insertedLength
      ? .cursorAndCount
      : nil
  }

  private static func valueShowsInsertion(
    _ text: String,
    selectedRange: NSRange,
    beforeValue: String,
    afterValue: String
  ) -> Bool {
    let before = beforeValue as NSString
    let after = afterValue as NSString
    let insertedRange = NSRange(location: selectedRange.location, length: text.utf16.count)
    guard NSMaxRange(selectedRange) <= before.length,
      NSMaxRange(insertedRange) <= after.length,
      after.substring(with: insertedRange) == text
    else {
      return false
    }

    let prefix = before.substring(to: selectedRange.location)
    let suffix = before.substring(from: NSMaxRange(selectedRange))
    return afterValue.hasPrefix(prefix) && afterValue.hasSuffix(suffix)
  }

  private func observation(of element: AXUIElement) -> TextInsertionObservation {
    TextInsertionObservation(
      value: readableValue(of: element),
      selectedRange: selectedTextRange(of: element),
      characterCount: integerAttribute(kAXNumberOfCharactersAttribute as CFString, on: element)
    )
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

  private func stringForInsertedRange(
    _ text: String,
    before: TextInsertionObservation,
    element: AXUIElement
  ) -> String? {
    guard let selectedRange = before.selectedRange else { return nil }
    var range = CFRange(
      location: selectedRange.location,
      length: text.utf16.count
    )
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

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
    return Self.readableString(from: value)
  }

  private func waitForInsertion(
    _ text: String,
    before: TextInsertionObservation,
    initialElement: AXUIElement,
    target: TextTarget?,
    initialDelay: Duration
  ) async throws -> TextInsertionEvidence? {
    if initialDelay > .zero {
      try await Task.sleep(for: initialDelay)
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: verificationTimeout)
    while true {
      try verifyFocus(target)
      let element = focusedElement() ?? initialElement
      try verifyElement(element, matches: target)
      if let evidence = Self.insertionEvidence(
        text,
        before: before,
        after: observation(of: element),
        insertedText: stringForInsertedRange(text, before: before, element: element)
      ) {
        return evidence
      }
      guard clock.now < deadline else { return nil }
      try await Task.sleep(for: verificationPollInterval)
    }
  }

  private func postPasteShortcut(to processIdentifier: Int32?) -> Bool {
    guard CGPreflightPostEventAccess() else { return false }
    guard let source = CGEventSource(stateID: .privateState),
      let commandDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: 55,
        keyDown: true
      ),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: false
      ),
      let commandUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: 55,
        keyDown: false
      )
    else {
      return false
    }

    commandDown.flags = .maskCommand
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    let events = [commandDown, keyDown, keyUp, commandUp]
    if let processIdentifier {
      for event in events {
        event.postToPid(processIdentifier)
      }
    } else {
      for event in events {
        event.post(tap: .cghidEventTap)
      }
    }
    return true
  }
}

private struct PasteboardSnapshot {
  struct Item {
    let values: [String: Data]
  }

  let items: [Item]

  static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
    let items = (pasteboard.pasteboardItems ?? []).map { item in
      var values: [String: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          values[type.rawValue] = data
        }
      }
      return Item(values: values)
    }
    return PasteboardSnapshot(items: items)
  }

  func restore(to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    guard !items.isEmpty else { return true }

    let restoredItems = items.map { snapshot -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (rawType, data) in snapshot.values {
        item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
      }
      return item
    }
    return pasteboard.writeObjects(restoredItems)
  }
}
