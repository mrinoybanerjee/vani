import Testing

@testable import VaniCore

private let textPipeline = TextPipeline()

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
