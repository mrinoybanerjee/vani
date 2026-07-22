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

@Test
func snippetsExpandWholePhrasesOnceAndIgnoreCase() {
  let snippets = [
    SnippetEntry(trigger: "sign off", expansion: "Use greeting"),
    SnippetEntry(trigger: "greeting", expansion: "Hello,\nMrinoy"),
  ]

  #expect(
    textPipeline.process(
      "SIGN OFF then greeting",
      dictionary: [],
      snippets: snippets
    ) == "Use greeting then Hello,\nMrinoy"
  )
}

@Test
func snippetsAbsorbRecognizerPunctuationWhenExpansionAlreadyEndsWithPunctuation() {
  let snippet = SnippetEntry(
    trigger: "test snippet",
    expansion: "Vani snippet live test passed."
  )

  for smartFormattingEnabled in [false, true] {
    for artifact in [".", "!", "?", ",", ";", ":", "...", "…"] {
      #expect(
        textPipeline.process(
          "test snippet\(artifact)",
          dictionary: [],
          snippets: [snippet],
          smartFormattingEnabled: smartFormattingEnabled
        ) == "Vani snippet live test passed."
      )
    }
  }
}

@Test
func snippetsRespectWordBoundariesAndPreferTheLongestTrigger() {
  let snippets = [
    SnippetEntry(trigger: "off", expansion: "wrong"),
    SnippetEntry(trigger: "sign off", expansion: "Thanks"),
    SnippetEntry(trigger: "cat", expansion: "pet"),
  ]

  #expect(
    textPipeline.process(
      "sign off and concatenate cat",
      dictionary: [],
      snippets: snippets
    ) == "Thanks and concatenate pet"
  )
}

@Test
func dictionaryCorrectionsCanFeedSnippetTriggers() {
  #expect(
    textPipeline.process(
      "vee any",
      dictionary: [DictionaryEntry(spoken: "vee any", replacement: "vani")],
      snippets: [SnippetEntry(trigger: "vani", expansion: "Vani project")]
    ) == "Vani project"
  )
}

@Test
func smartFormattingIsOptIn() {
  #expect(
    textPipeline.process(
      "um hello comma new line world period",
      dictionary: []
    ) == "um hello comma new line world period"
  )
}

@Test
func smartFormattingHandlesConservativeFillersPunctuationAndStructure() {
  #expect(
    textPipeline.process(
      "um, hello comma new line uh this is fine period new paragraph next thought question mark",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "Hello,\nThis is fine.\n\nNext thought?"
  )
}

@Test
func smartFormattingAbsorbsRecognizerPunctuationAroundCommands() {
  #expect(
    textPipeline.process(
      "Hello, comma, this is a test, period, new paragraph, it works.",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "Hello, this is a test.\n\nIt works."
  )
}

@Test
func smartFormattingPreservesSentenceEndBeforeAParagraphCommand() {
  #expect(
    textPipeline.process(
      "first thought. new paragraph, next thought",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "First thought.\n\nNext thought"
  )
}

@Test
func smartFormattingPreservesSnippetTextExactly() {
  #expect(
    textPipeline.process(
      "sign off period next sentence period",
      dictionary: [],
      snippets: [SnippetEntry(trigger: "sign off", expansion: "thanks period,\nMrinoy")],
      smartFormattingEnabled: true
    ) == "thanks period,\nMrinoy. Next sentence."
  )
}

@Test
func snippetExpansionTreatsDollarAndBackslashAsLiteralText() {
  #expect(
    textPipeline.process(
      "price block",
      dictionary: [],
      snippets: [SnippetEntry(trigger: "price block", expansion: "$5\\item")]
    ) == "$5\\item"
  )
  #expect(
    textPipeline.process(
      "price block.",
      dictionary: [],
      snippets: [SnippetEntry(trigger: "price block", expansion: "$5\\item.")]
    ) == "$5\\item."
  )
}

@Test
func maximumSnippetSetUsesTheExpectedLiteralMatch() {
  let snippets = (0..<VaniSettings.maximumSnippetCount).map {
    SnippetEntry(trigger: "trigger \($0)", expansion: "replacement \($0)")
  }

  #expect(
    textPipeline.process(
      "trigger 199",
      dictionary: [],
      snippets: snippets
    ) == "replacement 199"
  )
}
