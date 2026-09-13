import AppKit
import Foundation
import Testing

@testable import VaniCore

@MainActor
private final class InsertionFocusProvider: FocusProviding {
  var target = TextTarget(processIdentifier: 42, bundleIdentifier: "test.target")
  var onCurrentTarget: (() -> Void)?

  func currentTarget() -> TextTarget? {
    onCurrentTarget?()
    return target
  }
}

@MainActor
private final class InsertionEnvironment: TextInsertionEnvironment {
  var canPostPaste = true
  var reads: [TextInsertionRead?]
  var postResult = true
  var errorBeforeDelivery: (any Error)?
  var errorAfterDelivery: (any Error)?
  var onRead: (() -> Void)?
  var onPost: (() -> Void)?
  var onDelivery: (() -> Void)?
  private(set) var postCount = 0
  private(set) var deliveryCount = 0
  private var lastRead: TextInsertionRead?

  init(reads: [TextInsertionRead?]) {
    self.reads = reads
  }

  func read(target: TextTarget, insertedRange: NSRange?) -> TextInsertionRead? {
    onRead?()
    guard !reads.isEmpty else { return lastRead }
    let next = reads.removeFirst()
    lastRead = next
    return next
  }

  func postPasteShortcut(
    to processIdentifier: Int32,
    interval: Duration,
    beforePaste: @MainActor () throws -> Void
  ) async throws -> Bool {
    postCount += 1
    onPost?()
    try beforePaste()
    if let errorBeforeDelivery { throw errorBeforeDelivery }
    deliveryCount += 1
    onDelivery?()
    if let errorAfterDelivery { throw errorAfterDelivery }
    return postResult
  }
}

private func insertionRead(
  value: String?,
  range: NSRange?,
  count: Int?,
  insertedText: String? = nil,
  isSecureTextField: Bool = false
) -> TextInsertionRead {
  TextInsertionRead(
    observation: TextInsertionObservation(
      value: value,
      selectedRange: range,
      characterCount: count
    ),
    insertedText: insertedText,
    isSecureTextField: isSecureTextField
  )
}

private struct PostedKeyEvent: Equatable {
  let processIdentifier: Int32
  let keyCode: Int64
  let typeRawValue: UInt32
  let flagsRawValue: UInt64
}

private final class KeyEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [PostedKeyEvent] = []

  func record(_ event: CGEvent, processIdentifier: Int32) {
    lock.withLock {
      events.append(
        PostedKeyEvent(
          processIdentifier: processIdentifier,
          keyCode: event.getIntegerValueField(.keyboardEventKeycode),
          typeRawValue: event.type.rawValue,
          flagsRawValue: event.flags.rawValue
        )
      )
    }
  }

  func snapshot() -> [PostedKeyEvent] {
    lock.withLock { events }
  }
}

private func keyEvent(
  source: CGEventSource,
  keyCode: CGKeyCode,
  isDown: Bool,
  flags: CGEventFlags
) -> CGEvent {
  let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)!
  event.flags = flags
  return event
}

@MainActor
private func makeInserter(
  focus: InsertionFocusProvider,
  environment: InsertionEnvironment,
  pasteboard: NSPasteboard
) -> SystemTextInserter {
  SystemTextInserter(
    focusProvider: focus,
    environment: environment,
    pasteboard: pasteboard,
    pasteDelay: .zero,
    verificationTimeout: .milliseconds(50),
    verificationPollInterval: .milliseconds(1),
    eventInterval: .zero,
    clipboardRestoreDelay: .zero
  )
}

@Test
func cancelledPasteSequenceReleasesEachPressedKeyExactlyOnce() throws {
  let source = try #require(CGEventSource(stateID: .privateState))
  let recorder = KeyEventRecorder()
  let processIdentifier: Int32 = 42
  let sequence = PasteKeySequence(
    processIdentifier: processIdentifier,
    commandDown: keyEvent(
      source: source,
      keyCode: 55,
      isDown: true,
      flags: .maskCommand
    ),
    keyDown: keyEvent(
      source: source,
      keyCode: 9,
      isDown: true,
      flags: .maskCommand
    ),
    keyUp: keyEvent(
      source: source,
      keyCode: 9,
      isDown: false,
      flags: .maskCommand
    ),
    commandUp: keyEvent(source: source, keyCode: 55, isDown: false, flags: []),
    post: recorder.record
  )

  #expect(sequence.postCommandDown())
  #expect(sequence.postKeyDown())
  sequence.cancelAndReleasePressedKeys()
  sequence.releasePressedKeys()
  sequence.postKeyUp()
  sequence.postCommandUp()
  #expect(!sequence.postCommandDown())
  #expect(!sequence.postKeyDown())

  #expect(
    recorder.snapshot()
      == [
        PostedKeyEvent(
          processIdentifier: 42,
          keyCode: 55,
          typeRawValue: CGEventType.flagsChanged.rawValue,
          flagsRawValue: CGEventFlags.maskCommand.rawValue
        ),
        PostedKeyEvent(
          processIdentifier: 42,
          keyCode: 9,
          typeRawValue: CGEventType.keyDown.rawValue,
          flagsRawValue: CGEventFlags.maskCommand.rawValue
        ),
        PostedKeyEvent(
          processIdentifier: 42,
          keyCode: 9,
          typeRawValue: CGEventType.keyUp.rawValue,
          flagsRawValue: CGEventFlags.maskCommand.rawValue
        ),
        PostedKeyEvent(
          processIdentifier: 42,
          keyCode: 55,
          typeRawValue: CGEventType.flagsChanged.rawValue,
          flagsRawValue: 0
        ),
      ]
  )
}

@Test @MainActor
func missingAccessibilityObservationStillPostsPasteAndPreservesTranscript() async throws {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [nil])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  let result = try await makeInserter(
    focus: focus,
    environment: environment,
    pasteboard: pasteboard
  ).insert("hello", into: focus.target)

  #expect(result == .unverifiedClipboardPreserved)
  #expect(environment.postCount == 1)
  #expect(pasteboard.string(forType: .string) == "hello")
}

@Test @MainActor
func sameForegroundApplicationDoesNotRequireAccessibilityElementIdentity() async throws {
  let focus = InsertionFocusProvider()
  let capturedTarget = focus.target
  let environment = InsertionEnvironment(reads: [nil])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }

  let result = try await makeInserter(
    focus: focus,
    environment: environment,
    pasteboard: pasteboard
  ).insert("dynamic field", into: capturedTarget)

  #expect(result == .unverifiedClipboardPreserved)
  #expect(environment.postCount == 1)
}

@Test @MainActor
func missingTargetNeverPostsASystemWidePaste() async throws {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }

  let result = try await makeInserter(
    focus: focus,
    environment: environment,
    pasteboard: pasteboard
  ).insert("manual only", into: nil)

  #expect(result == .manualPasteRequired)
  #expect(environment.postCount == 0)
  #expect(pasteboard.string(forType: .string) == "manual only")
}

@Test @MainActor
func changedForegroundApplicationAbortsBeforeTouchingTheClipboard() async {
  let focus = InsertionFocusProvider()
  let capturedTarget = focus.target
  focus.target = TextTarget(processIdentifier: 99, bundleIdentifier: "other.target")
  let environment = InsertionEnvironment(reads: [])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  await #expect(throws: VaniFailure.focusChanged) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("do not paste", into: capturedTarget)
  }

  #expect(environment.postCount == 0)
  #expect(pasteboard.string(forType: .string) == "original")
}

@Test @MainActor
func secureTextFieldAbortsBeforeTouchingTheClipboard() async {
  let focus = InsertionFocusProvider()
  let secureRead = insertionRead(
    value: nil,
    range: nil,
    count: nil,
    isSecureTextField: true
  )
  let environment = InsertionEnvironment(reads: [secureRead])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  await #expect(throws: VaniFailure.secureTextField) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("do not paste", into: focus.target)
  }

  #expect(environment.postCount == 0)
  #expect(pasteboard.string(forType: .string) == "original")
}

@Test @MainActor
func focusChangeDuringPreflightRestoresClipboardAndDoesNotPost() async {
  let focus = InsertionFocusProvider()
  let capturedTarget = focus.target
  let environment = InsertionEnvironment(reads: [nil])
  environment.onRead = {
    focus.target = TextTarget(processIdentifier: 99, bundleIdentifier: "other.target")
  }
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  await #expect(throws: VaniFailure.focusChanged) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("do not paste", into: capturedTarget)
  }

  #expect(environment.postCount == 0)
  #expect(pasteboard.string(forType: .string) == "original")
}

@Test @MainActor
func clipboardChangeBeforePasteDeliveryAbortsWithoutPosting() async {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [nil])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  var focusReadCount = 0
  focus.onCurrentTarget = {
    focusReadCount += 1
    if focusReadCount == 2 {
      pasteboard.clearContents()
      pasteboard.setString("newer", forType: .string)
    }
  }

  await #expect(throws: VaniFailure.clipboardChanged) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("do not paste", into: focus.target)
  }

  #expect(environment.postCount == 0)
  #expect(pasteboard.string(forType: .string) == "newer")
}

@Test @MainActor
func secureFieldChangeAtPasteBoundaryRestoresClipboardAndDoesNotDeliver() async {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [nil])
  environment.onPost = {
    focus.target = TextTarget(
      processIdentifier: 42,
      bundleIdentifier: "test.target",
      isSecureTextField: true
    )
  }
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  await #expect(throws: VaniFailure.secureTextField) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("do not paste", into: focus.target)
  }

  #expect(environment.postCount == 1)
  #expect(environment.deliveryCount == 0)
  #expect(pasteboard.string(forType: .string) == "original")
}

@Test @MainActor
func cancellationRestoresClipboardOnlyBeforePasteDispatch() async throws {
  let focus = InsertionFocusProvider()
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)
  let before = InsertionEnvironment(reads: [nil])
  before.errorBeforeDelivery = CancellationError()
  await #expect(throws: CancellationError.self) {
    try await makeInserter(focus: focus, environment: before, pasteboard: pasteboard)
      .insert("transcript", into: focus.target)
  }
  #expect(before.deliveryCount == 0)
  #expect(pasteboard.string(forType: .string) == "original")

  let after = InsertionEnvironment(reads: [nil])
  after.errorAfterDelivery = PasteShortcutError.interruptedAfterDispatch
  let result = try await makeInserter(focus: focus, environment: after, pasteboard: pasteboard)
    .insert("transcript", into: focus.target)
  #expect(after.deliveryCount == 1)
  #expect(result == .unverifiedClipboardPreserved)
  #expect(pasteboard.string(forType: .string) == "transcript")

  let changedAfter = InsertionEnvironment(reads: [nil])
  changedAfter.errorAfterDelivery = PasteShortcutError.interruptedAfterDispatch
  changedAfter.onDelivery = {
    pasteboard.clearContents()
    pasteboard.setString("newer clipboard", forType: .string)
  }
  await #expect(throws: VaniFailure.clipboardChanged) {
    try await makeInserter(focus: focus, environment: changedAfter, pasteboard: pasteboard)
      .insert("transcript", into: focus.target)
  }
  #expect(changedAfter.deliveryCount == 1)
  #expect(pasteboard.string(forType: .string) == "newer clipboard")
}

@Test @MainActor
func focusChangeDuringVerificationCannotProduceFalseSuccess() async {
  let focus = InsertionFocusProvider()
  let capturedTarget = focus.target
  let before = insertionRead(
    value: "prefix ",
    range: NSRange(location: 7, length: 0),
    count: 7
  )
  let after = insertionRead(
    value: "prefix hello",
    range: NSRange(location: 12, length: 0),
    count: 12,
    insertedText: "hello"
  )
  let environment = InsertionEnvironment(reads: [before, after])
  var readCount = 0
  environment.onRead = {
    readCount += 1
    if readCount == 2 {
      focus.target = TextTarget(processIdentifier: 99, bundleIdentifier: "other.target")
    }
  }
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  await #expect(throws: VaniFailure.focusChanged) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("hello", into: capturedTarget)
  }

  #expect(environment.postCount == 1)
  #expect(pasteboard.string(forType: .string) == "hello")
}

@Test @MainActor
func eventPermissionFailureCopiesTranscriptWithoutPosting() async {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [])
  environment.canPostPaste = false
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }

  await #expect(throws: VaniFailure.accessibilityPermissionDenied) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("recover me", into: focus.target)
  }

  #expect(environment.postCount == 0)
  #expect(pasteboard.string(forType: .string) == "recover me")
}

@Test @MainActor
func delayedObservableInsertionRestoresTheOriginalClipboard() async throws {
  let focus = InsertionFocusProvider()
  let before = insertionRead(
    value: "prefix ",
    range: NSRange(location: 7, length: 0),
    count: 7
  )
  let environment = InsertionEnvironment(reads: [
    before,
    before,
    insertionRead(
      value: "prefix hello",
      range: NSRange(location: 12, length: 0),
      count: 12,
      insertedText: "hello"
    ),
  ])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  let result = try await makeInserter(
    focus: focus,
    environment: environment,
    pasteboard: pasteboard
  ).insert("hello", into: focus.target)

  #expect(result == .verified)
  #expect(environment.postCount == 1)
  #expect(pasteboard.string(forType: .string) == "original")
}

@Test @MainActor
func standaloneStructuralNewlineIsVerifiedAndRestoresTheOriginalClipboard() async throws {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [
    insertionRead(
      value: "first line",
      range: NSRange(location: 10, length: 0),
      count: 10
    ),
    insertionRead(
      value: "first line\n",
      range: NSRange(location: 11, length: 0),
      count: 11,
      insertedText: "\n"
    ),
  ])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  let result = try await makeInserter(
    focus: focus,
    environment: environment,
    pasteboard: pasteboard
  ).insert("\n", into: focus.target)

  #expect(result == .verified)
  #expect(environment.postCount == 1)
  #expect(pasteboard.string(forType: .string) == "original")
}

@Test @MainActor
func observableVerificationTimeoutPreservesTranscript() async throws {
  let focus = InsertionFocusProvider()
  let unchanged = insertionRead(
    value: "prefix ",
    range: NSRange(location: 7, length: 0),
    count: 7
  )
  let environment = InsertionEnvironment(reads: [unchanged])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)

  let result = try await makeInserter(
    focus: focus,
    environment: environment,
    pasteboard: pasteboard
  ).insert("hello", into: focus.target)

  #expect(result == .unverifiedClipboardPreserved)
  #expect(environment.postCount == 1)
  #expect(pasteboard.string(forType: .string) == "hello")
}

@Test @MainActor
func externalClipboardChangeIsNeverOverwritten() async {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [nil])
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  pasteboard.setString("original", forType: .string)
  environment.onPost = {
    pasteboard.clearContents()
    pasteboard.setString("newer", forType: .string)
  }

  await #expect(throws: VaniFailure.clipboardChanged) {
    try await makeInserter(
      focus: focus,
      environment: environment,
      pasteboard: pasteboard
    ).insert("hello", into: focus.target)
  }

  #expect(environment.postCount == 1)
  #expect(environment.deliveryCount == 0)
  #expect(pasteboard.string(forType: .string) == "newer")
}

@Test @MainActor
func failedEventConstructionLeavesTranscriptReadyForManualPaste() async throws {
  let focus = InsertionFocusProvider()
  let environment = InsertionEnvironment(reads: [nil])
  environment.postResult = false
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }

  let result = try await makeInserter(
    focus: focus,
    environment: environment,
    pasteboard: pasteboard
  ).insert("manual", into: focus.target)

  #expect(result == .manualPasteRequired)
  #expect(environment.postCount == 1)
  #expect(pasteboard.string(forType: .string) == "manual")
}
