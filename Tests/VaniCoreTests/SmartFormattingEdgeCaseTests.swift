import Foundation
import Testing

@testable import VaniCore

private let edgeCasePipeline = TextPipeline()

@Test
func smartFormattingSupportsEveryPunctuationCommandAndCaseVariant() {
  let commands = [
    ("comma", ","),
    ("period", "."),
    ("full stop", "."),
    ("question mark", "?"),
    ("exclamation mark", "!"),
    ("exclamation point", "!"),
    ("colon", ":"),
    ("semicolon", ";"),
  ]

  for (phrase, replacement) in commands {
    for variant in [phrase, phrase.uppercased(), phrase.capitalized] {
      let output = edgeCasePipeline.process(
        "alpha \(variant) beta",
        dictionary: [],
        smartFormattingEnabled: true
      )
      let nextWord = ".!?".contains(replacement) ? "Beta" : "beta"
      #expect(output == "Alpha\(replacement) \(nextWord)")
    }
  }
}

@Test
func smartFormattingAbsorbsEveryRecognizerArtifactAroundPunctuationCommands() {
  let commands = [
    ("comma", ","),
    ("period", "."),
    ("full stop", "."),
    ("question mark", "?"),
    ("exclamation mark", "!"),
    ("exclamation point", "!"),
    ("colon", ":"),
    ("semicolon", ";"),
  ]
  let artifacts = [",", ".", ";", ":", "!", "?", "...", "…"]

  for (phrase, replacement) in commands {
    for leading in artifacts {
      for trailing in artifacts {
        let output = edgeCasePipeline.process(
          "alpha\(leading)\(phrase)\(trailing)beta",
          dictionary: [],
          smartFormattingEnabled: true
        )
        let nextWord = ".!?".contains(replacement) ? "Beta" : "beta"
        #expect(output == "Alpha\(replacement) \(nextWord)")
      }
    }
  }
}

@Test
func smartFormattingHandlesEveryStructuralCommandArtifactCombination() {
  let commands = [("new line", "\n"), ("new paragraph", "\n\n")]
  let disposableLeadingArtifacts = [",", ";", ":"]
  let sentenceEndArtifacts = [".", "!", "?", "...", "…"]
  let trailingArtifacts = [",", ".", ";", ":", "!", "?", "...", "…"]

  for (phrase, replacement) in commands {
    for leading in disposableLeadingArtifacts {
      for trailing in trailingArtifacts {
        let output = edgeCasePipeline.process(
          "alpha\(leading)\(phrase)\(trailing)beta",
          dictionary: [],
          smartFormattingEnabled: true
        )
        #expect(output == "Alpha\(replacement)Beta")
      }
    }

    for leading in sentenceEndArtifacts {
      for trailing in trailingArtifacts {
        let output = edgeCasePipeline.process(
          "alpha\(leading)\(phrase)\(trailing)beta",
          dictionary: [],
          smartFormattingEnabled: true
        )
        #expect(output == "Alpha\(leading)\(replacement)Beta")
      }
    }
  }
}

@Test
func smartFormattingRemovesOnlyStandaloneFillersAndTheirArtifacts() {
  let fillers = ["um", "ummm", "uh", "uhhh", "erm", "ermmm"]
  let artifacts = [",", ".", ";", ":", "!", "?", "...", "…", ""]

  for filler in fillers {
    for variant in [filler, filler.uppercased(), filler.capitalized] {
      for artifact in artifacts {
        let output = edgeCasePipeline.process(
          "\(variant)\(artifact) hello",
          dictionary: [],
          smartFormattingEnabled: true
        )
        #expect(output == "Hello")
      }
    }
  }

  #expect(
    edgeCasePipeline.process(
      "album, thermal, column, ermine, uh-oh, uh's, and say-um",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "Album, thermal, column, ermine, uh-oh, uh's, and say-um"
  )
  #expect(
    edgeCasePipeline.process(
      "first. um, second",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "First. Second"
  )
  #expect(
    edgeCasePipeline.process(
      "well,um,...maybe first.uh,second",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "Well, maybe first. Second"
  )
  #expect(
    edgeCasePipeline.process(
      "um, uh... erm!",
      dictionary: [],
      smartFormattingEnabled: true
    ).isEmpty
  )
  #expect(
    edgeCasePipeline.process(
      "",
      dictionary: [],
      smartFormattingEnabled: true
    ).isEmpty
  )
}

@Test
func smartFormattingDoesNotTreatCommandsInsideWordsAsCommands() {
  let input =
    "comma-separated, comma_delimited, comma's, periodic, semicolons, colonial, and renewal"

  #expect(
    edgeCasePipeline.process(
      input,
      dictionary: [],
      smartFormattingEnabled: true
    ) == "Comma-separated, comma_delimited, comma's, periodic, semicolons, colonial, and renewal"
  )
}

@Test
func smartFormattingCapitalizesUnicodeButPreservesMixedCaseNames() {
  #expect(
    edgeCasePipeline.process(
      "elan period éclair period über",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "Elan. Éclair. Über"
  )
  #expect(
    edgeCasePipeline.process(
      "iPhone period eBay period macOS period NASA",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "iPhone. eBay. macOS. NASA"
  )
  #expect(
    edgeCasePipeline.process(
      "eye phone period",
      dictionary: [DictionaryEntry(spoken: "eye phone", replacement: "iPhone")],
      smartFormattingEnabled: true
    ) == "iPhone."
  )
}

@Test
func smartFormattingCapitalizesInsideSentenceQuotesAndBrackets() {
  #expect(
    edgeCasePipeline.process(
      #""hello." “world.” (again!) [finished?]"#,
      dictionary: [],
      smartFormattingEnabled: true
    ) == #""Hello." “World.” (Again!) [Finished?]"#
  )
}

@Test
func smartFormattingOffLeavesCommandsFillersAndModelPunctuationLiteral() {
  let input =
    "um, iPhone comma period question mark exclamation mark colon semicolon new line new paragraph."

  #expect(
    edgeCasePipeline.process(
      input,
      dictionary: [],
      smartFormattingEnabled: false
    ) == input
  )
}

@Test
func smartFormattingPreservesURLsNumbersEmojiAndUnrelatedUnicode() {
  let input = "version 1.2.3 costs $4.50 at https://example.com/path?q=1. café 中文 👋"

  #expect(
    edgeCasePipeline.process(
      input,
      dictionary: [],
      smartFormattingEnabled: true
    ) == "Version 1.2.3 costs $4.50 at https://example.com/path?q=1. Café 中文 👋"
  )
  #expect(
    edgeCasePipeline.process(
      "https://example.com period user@example.com period www.example.com",
      dictionary: [],
      smartFormattingEnabled: true
    ) == "https://example.com. user@example.com. www.example.com"
  )
  #expect(
    edgeCasePipeline.process(
      "https://comma.com/period?filler=um period comma@example.com period user@comma.com period www.period.com. next",
      dictionary: [],
      smartFormattingEnabled: true
    )
      == "https://comma.com/period?filler=um. comma@example.com. user@comma.com. www.period.com. Next"
  )
}

@Test
func smartFormattingIsDeterministicAcrossAdversarialGeneratedInputs() {
  let tokens = [
    "alpha", "BETA", "iPhone", "éclair", "中文", "👋", "42", "1.25",
    "comma", "period", "question mark", "exclamation point", "colon", "semicolon",
    "new line", "new paragraph", "um", "uhhh", "erm", "uh-oh", "comma-separated",
    "https://example.com", "user@example.com",
  ]
  let separators = [" ", "  ", "\t", "\n", "\u{00A0}", ",", ", ", "...", "? "]
  var generator = DeterministicGenerator(seed: 0x5641_4E49)

  for _ in 0..<500 {
    let tokenCount = 1 + generator.next(upperBound: 30)
    var raw = ""
    for index in 0..<tokenCount {
      if index > 0 {
        raw += separators[generator.next(upperBound: separators.count)]
      }
      raw += tokens[generator.next(upperBound: tokens.count)]
    }

    let first = edgeCasePipeline.process(
      raw,
      dictionary: [],
      smartFormattingEnabled: true
    )
    let second = edgeCasePipeline.process(
      raw,
      dictionary: [],
      smartFormattingEnabled: true
    )

    #expect(first == second)
    #expect(!first.contains("\t"))
    #expect(!first.contains("\r"))
    #expect(!first.contains("\u{00A0}"))
    #expect(!first.contains("\n\n\n"))
    #expect(first.range(of: #"[ \t]+[,.;:!?]"#, options: .regularExpression) == nil)
  }
}

@Test
func smartFormattingHandlesALongTranscriptWithoutLosingStructure() {
  let phrase = "alpha comma beta period new paragraph"
  let raw = Array(repeating: phrase, count: 2_000).joined(separator: " ")
  let output = edgeCasePipeline.process(
    raw,
    dictionary: [],
    smartFormattingEnabled: true
  )

  #expect(output.hasPrefix("Alpha, beta.\n\nAlpha, beta."))
  #expect(output.hasSuffix("Alpha, beta."))
  #expect(output.components(separatedBy: "\n\n").count == 2_000)
  #expect(!output.contains("comma"))
  #expect(!output.contains("period"))
  #expect(!output.contains("new paragraph"))
}

private struct DeterministicGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next(upperBound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int(state % UInt64(upperBound))
  }
}
