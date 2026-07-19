import AppKit
import ApplicationServices
import Foundation

@MainActor
public final class SystemTextInserter: TextInserting {
  private let focusProvider: any FocusProviding
  private let pasteDelay: Duration

  public init(
    focusProvider: any FocusProviding = SystemFocusProvider(),
    pasteDelay: Duration = .milliseconds(140)
  ) {
    self.focusProvider = focusProvider
    self.pasteDelay = pasteDelay
  }

  public func insert(
    _ text: String,
    into target: TextTarget?
  ) async throws -> TextInsertionResult {
    guard !text.isEmpty else { throw VaniFailure.emptyTranscript }
    try verifyFocus(target)

    if AXIsProcessTrusted(), let element = focusedElement() {
      try verifyElement(element, matches: target)
      let before = readableValue(of: element)
      if before != nil,
        isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
      {
        let result = AXUIElementSetAttributeValue(
          element,
          kAXSelectedTextAttribute as CFString,
          text as CFTypeRef
        )
        if result == .success {
          guard verifyInsertion(text, before: before, element: element) else {
            try copyForManualPaste(text)
            return .manualPasteRequired
          }
          return .verified
        }
      }

      return try await pasteAndVerify(
        text,
        target: target,
        element: element,
        before: before
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
    before: String?
  ) async throws -> TextInsertionResult {
    let pasteboard = NSPasteboard.general
    let original = PasteboardSnapshot.capture(from: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      throw VaniFailure.insertionFailed
    }
    let transcriptChangeCount = pasteboard.changeCount

    guard postPasteShortcut() else {
      return .manualPasteRequired
    }

    try await Task.sleep(for: pasteDelay)
    try verifyFocus(target)

    guard verifyInsertion(text, before: before, element: element) else {
      if pasteboard.changeCount != transcriptChangeCount {
        throw VaniFailure.clipboardChanged
      }
      return .manualPasteRequired
    }

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
    return value as? String
  }

  private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
      && settable.boolValue
  }

  private func verifyInsertion(
    _ text: String,
    before: String?,
    element: AXUIElement
  ) -> Bool {
    guard let before, let after = readableValue(of: element) else { return false }
    guard before != after else { return false }
    return after.contains(text)
  }

  private func postPasteShortcut() -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: 9,
        keyDown: false
      )
    else {
      return false
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
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
