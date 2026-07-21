import Foundation
import Testing

@testable import VaniCore

private let textPipeline = TextPipeline()

@Test @MainActor
func readsPlainAndAttributedAccessibilityText() {
  #expect(SystemTextInserter.readableString(from: "plain") == "plain")
  #expect(
    SystemTextInserter.readableString(from: NSAttributedString(string: "rich")) == "rich"
  )
  #expect(SystemTextInserter.readableString(from: 42) == nil)
}

@Test @MainActor
func verifiesRichTextInsertionFromSelectedRangeWhenFullValueIsUnavailable() {
  let before = TextInsertionObservation(
    value: nil,
    selectedRange: NSRange(location: 4, length: 0),
    characterCount: nil
  )
  let after = TextInsertionObservation(
    value: nil,
    selectedRange: NSRange(location: 15, length: 0),
    characterCount: nil
  )

  #expect(
    SystemTextInserter.verifyInsertion(
      "hello world",
      before: before,
      after: after,
      insertedText: nil
    )
  )
}

@Test @MainActor
func verifiesRichTextInsertionFromParameterizedRangeText() {
  let before = TextInsertionObservation(
    value: nil,
    selectedRange: NSRange(location: 4, length: 0),
    characterCount: 10
  )
  let after = TextInsertionObservation(
    value: nil,
    selectedRange: nil,
    characterCount: 21
  )

  #expect(
    SystemTextInserter.verifyInsertion(
      "hello world",
      before: before,
      after: after,
      insertedText: "hello world"
    )
  )
}

@Test @MainActor
func verifiesInsertionWhenRichTextAddsATrailingParagraphMarker() {
  let before = TextInsertionObservation(
    value: "prefix ",
    selectedRange: NSRange(location: 7, length: 0),
    characterCount: 7
  )
  let after = TextInsertionObservation(
    value: "prefix hello world\n",
    selectedRange: NSRange(location: 19, length: 0),
    characterCount: 19
  )

  #expect(
    SystemTextInserter.verifyInsertion(
      "hello world",
      before: before,
      after: after,
      insertedText: "hello world"
    )
  )
}

@Test @MainActor
func verifiesParameterizedRangeWithAFormattingCharacterCountDelta() {
  let before = TextInsertionObservation(
    value: nil,
    selectedRange: NSRange(location: 0, length: 0),
    characterCount: 0
  )
  let after = TextInsertionObservation(
    value: nil,
    selectedRange: nil,
    characterCount: 12
  )

  #expect(
    SystemTextInserter.verifyInsertion(
      "hello world",
      before: before,
      after: after,
      insertedText: "hello world"
    )
  )
}

@Test @MainActor
func rejectsPreexistingParameterizedRangeTextWithoutStateChange() {
  let unchanged = TextInsertionObservation(
    value: nil,
    selectedRange: NSRange(location: 4, length: 0),
    characterCount: 10
  )

  #expect(
    !SystemTextInserter.verifyInsertion(
      "hello world",
      before: unchanged,
      after: unchanged,
      insertedText: "hello world"
    )
  )
}

@Test @MainActor
func rejectsUnchangedAccessibilityStateAfterPaste() {
  let unchanged = TextInsertionObservation(
    value: "existing",
    selectedRange: NSRange(location: 8, length: 0),
    characterCount: 8
  )

  #expect(
    !SystemTextInserter.verifyInsertion(
      "hello world",
      before: unchanged,
      after: unchanged,
      insertedText: nil
    )
  )
}

@Test @MainActor
func rejectsSelectionMovementWithAnInconsistentCharacterCount() {
  let before = TextInsertionObservation(
    value: nil,
    selectedRange: NSRange(location: 4, length: 3),
    characterCount: 12
  )
  let after = TextInsertionObservation(
    value: nil,
    selectedRange: NSRange(location: 15, length: 0),
    characterCount: 12
  )

  #expect(
    !SystemTextInserter.verifyInsertion(
      "hello world",
      before: before,
      after: after,
      insertedText: nil
    )
  )
}

@Test
func performsConservativeWhitespaceCleanup() {
  #expect(
    textPipeline.process("  hello   world  ! \n", dictionary: [])
      == "hello world!"
  )
}

@Test
func dictionaryUsesWordBoundariesAndIgnoresCase() {
  let dictionary = [DictionaryEntry(spoken: "vani", replacement: "Vani")]
  #expect(
    textPipeline.process("VANI helps vanishing ideas", dictionary: dictionary)
      == "Vani helps vanishing ideas"
  )
}

@Test
func invalidDictionaryEntriesAreIgnored() {
  let dictionary = [DictionaryEntry(spoken: " ", replacement: "unsafe")]
  #expect(textPipeline.process("keep this", dictionary: dictionary) == "keep this")
}

@Test
func doesNotInventCapitalizationOrPunctuation() {
  #expect(textPipeline.process("hello world", dictionary: []) == "hello world")
}

@Test
func dictionaryReplacementTreatsDollarAndBackslashAsLiteralText() {
  let dictionary = [
    DictionaryEntry(spoken: "price", replacement: "$5\\item")
  ]

  #expect(textPipeline.process("the price", dictionary: dictionary) == "the $5\\item")
}
