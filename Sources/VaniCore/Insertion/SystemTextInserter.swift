import AppKit
import Foundation

struct TextInsertionObservation: Equatable {
  let value: String?
  let selectedRange: NSRange?
  let characterCount: Int?

  init(value: String?, selectedRange: NSRange?, characterCount: Int?) {
    self.value = value
    self.selectedRange = selectedRange.flatMap {
      Self.validatedRange(location: $0.location, length: $0.length)
    }
    self.characterCount = characterCount.flatMap { $0 >= 0 ? $0 : nil }
  }

  static func validatedRange(location: Int, length: Int) -> NSRange? {
    guard location >= 0, location != NSNotFound, length >= 0,
      length <= Int.max - location
    else { return nil }
    return NSRange(location: location, length: length)
  }
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
  private let environment: any TextInsertionEnvironment
  private let pasteboard: NSPasteboard
  private let pasteDelay: Duration
  private let verificationTimeout: Duration
  private let verificationPollInterval: Duration
  private let eventInterval: Duration
  private let clipboardRestoreDelay: Duration

  public convenience init(
    focusProvider: any FocusProviding = SystemFocusProvider(),
    pasteDelay: Duration = .milliseconds(140),
    verificationTimeout: Duration = .seconds(2),
    verificationPollInterval: Duration = .milliseconds(50),
    eventInterval: Duration = .milliseconds(8),
    clipboardRestoreDelay: Duration = .milliseconds(80)
  ) {
    self.init(
      focusProvider: focusProvider,
      environment: SystemTextInsertionEnvironment(),
      pasteboard: .general,
      pasteDelay: pasteDelay,
      verificationTimeout: verificationTimeout,
      verificationPollInterval: verificationPollInterval,
      eventInterval: eventInterval,
      clipboardRestoreDelay: clipboardRestoreDelay
    )
  }

  init(
    focusProvider: any FocusProviding,
    environment: any TextInsertionEnvironment,
    pasteboard: NSPasteboard,
    pasteDelay: Duration = .milliseconds(140),
    verificationTimeout: Duration = .seconds(2),
    verificationPollInterval: Duration = .milliseconds(50),
    eventInterval: Duration = .milliseconds(8),
    clipboardRestoreDelay: Duration = .milliseconds(80)
  ) {
    self.focusProvider = focusProvider
    self.environment = environment
    self.pasteboard = pasteboard
    self.pasteDelay = pasteDelay
    self.verificationTimeout = verificationTimeout
    self.verificationPollInterval = verificationPollInterval
    self.eventInterval = eventInterval
    self.clipboardRestoreDelay = clipboardRestoreDelay
  }

  public func insert(
    _ text: String,
    into target: TextTarget?
  ) async throws -> TextInsertionResult {
    guard !text.isEmpty else { throw VaniFailure.emptyTranscript }
    guard let target else {
      try copyForManualPaste(text)
      return .manualPasteRequired
    }
    try verifyFocus(target)
    guard !target.isSecureTextField else {
      VaniLog.event(category: .insertion, code: "secure_field_blocked")
      throw VaniFailure.secureTextField
    }

    guard environment.canPostPaste else {
      VaniLog.event(category: .insertion, code: "paste_event_access_denied")
      try copyForManualPaste(text)
      throw VaniFailure.accessibilityPermissionDenied
    }

    let preflight = environment.read(target: target, insertedRange: nil)
    guard preflight?.isSecureTextField != true else {
      VaniLog.event(category: .insertion, code: "secure_field_blocked")
      throw VaniFailure.secureTextField
    }
    let before = preflight?.observation
    VaniLog.event(
      category: .insertion,
      code: before == nil ? "paste_preflight_unobservable" : "paste_preflight_observable"
    )
    return try await pasteAndVerify(text, target: target, before: before)
  }

  public func copyForManualPaste(_ text: String) throws {
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      throw VaniFailure.insertionFailed
    }
  }

  private func pasteAndVerify(
    _ text: String,
    target: TextTarget,
    before: TextInsertionObservation?
  ) async throws -> TextInsertionResult {
    let original = PasteboardSnapshot.capture(from: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      throw VaniFailure.insertionFailed
    }
    let transcriptChangeCount = pasteboard.changeCount

    do {
      try verifyFocus(target)
      guard pasteboard.changeCount == transcriptChangeCount else {
        throw VaniFailure.clipboardChanged
      }
    } catch {
      if pasteboard.changeCount == transcriptChangeCount {
        _ = original.restore(to: pasteboard)
      }
      throw error
    }

    let posted: Bool
    do {
      posted = try await environment.postPasteShortcut(
        to: target.processIdentifier,
        interval: eventInterval
      ) {
        try self.verifyFocus(target)
        guard self.pasteboard.changeCount == transcriptChangeCount else {
          throw VaniFailure.clipboardChanged
        }
      }
    } catch PasteShortcutError.interruptedAfterDispatch {
      guard pasteboard.changeCount == transcriptChangeCount else {
        throw VaniFailure.clipboardChanged
      }
      return .unverifiedClipboardPreserved
    } catch {
      if pasteboard.changeCount == transcriptChangeCount {
        _ = original.restore(to: pasteboard)
      }
      throw error
    }
    guard posted else {
      VaniLog.event(category: .insertion, code: "paste_event_post_failed")
      return .manualPasteRequired
    }
    VaniLog.event(category: .insertion, code: "paste_event_posted")

    try await Task.sleep(for: pasteDelay)
    try verifyFocus(target)

    let evidence: TextInsertionEvidence?
    if let before {
      evidence = try await waitForInsertion(text, before: before, target: target)
    } else {
      evidence = nil
    }

    if let evidence {
      VaniLog.event(category: .insertion, code: "paste_verified_\(evidence.rawValue)")
      if clipboardRestoreDelay > .zero {
        try await Task.sleep(for: clipboardRestoreDelay)
      }
      guard pasteboard.changeCount == transcriptChangeCount else {
        return .verifiedClipboardPreserved
      }
      return original.restore(to: pasteboard)
        ? .verified
        : .verifiedClipboardPreserved
    }

    if pasteboard.changeCount != transcriptChangeCount {
      throw VaniFailure.clipboardChanged
    }
    VaniLog.event(
      category: .insertion,
      code: before == nil ? "paste_unobservable" : "paste_unverified_timeout"
    )
    return .unverifiedClipboardPreserved
  }

  private func verifyFocus(_ target: TextTarget) throws {
    guard let current = focusProvider.currentTarget(),
      current.processIdentifier == target.processIdentifier,
      target.bundleIdentifier == nil || current.bundleIdentifier == target.bundleIdentifier
    else {
      throw VaniFailure.focusChanged
    }
    guard !current.isSecureTextField else {
      throw VaniFailure.secureTextField
    }
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
      } else if beforeValue != afterValue,
        valueShowsUnpositionedInsertion(
          text,
          beforeValue: beforeValue,
          afterValue: afterValue
        )
      {
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
      let expectedRange = TextInsertionObservation.validatedRange(
        location: beforeRange.location, length: insertedLength),
      afterRange.location == NSMaxRange(expectedRange),
      afterRange.length == 0
    else {
      return nil
    }

    guard let beforeCount = before.characterCount,
      let afterCount = after.characterCount
    else {
      return .cursorMovement
    }
    guard beforeCount >= beforeRange.length,
      insertedLength <= Int.max - (beforeCount - beforeRange.length)
    else { return nil }
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

  private static func valueShowsUnpositionedInsertion(
    _ text: String,
    beforeValue: String,
    afterValue: String
  ) -> Bool {
    let before = beforeValue as NSString
    let after = afterValue as NSString
    let insertedLength = text.utf16.count
    guard after.length == before.length + insertedLength else { return false }

    var searchRange = NSRange(location: 0, length: after.length)
    while searchRange.length >= insertedLength {
      let match = after.range(of: text, options: [], range: searchRange)
      guard match.location != NSNotFound else { return false }
      if after.replacingCharacters(in: match, with: "") == beforeValue {
        return true
      }
      let nextLocation = match.location + max(match.length, 1)
      searchRange = NSRange(
        location: nextLocation,
        length: after.length - nextLocation
      )
    }
    return false
  }

  private func waitForInsertion(
    _ text: String,
    before: TextInsertionObservation,
    target: TextTarget
  ) async throws -> TextInsertionEvidence? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: verificationTimeout)
    let insertedRange = before.selectedRange.flatMap {
      TextInsertionObservation.validatedRange(location: $0.location, length: text.utf16.count)
    }
    while true {
      try verifyFocus(target)
      if let read = environment.read(target: target, insertedRange: insertedRange) {
        try verifyFocus(target)
        if let evidence = Self.insertionEvidence(
          text,
          before: before,
          after: read.observation,
          insertedText: read.insertedText
        ) {
          return evidence
        }
      }
      guard clock.now < deadline else { return nil }
      try await Task.sleep(for: verificationPollInterval)
    }
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
