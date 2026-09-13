import Foundation
import Testing

@testable import VaniCore

@Test
func learnsOnlyChangedSpansFromAConfirmedCorrection() {
  let engine = PersonalizationEngine()
  let now = Date(timeIntervalSince1970: 1_000)
  let result = engine.learn(
    original: "Vanny uses core ml and pie torch",
    corrected: "Vani uses Core ML and PyTorch",
    applicationBundleIdentifier: "com.apple.dt.Xcode",
    existing: [],
    now: now
  )

  #expect(result.learned.count == 3)
  #expect(result.learned.map(\.spoken) == ["Vanny", "core ml", "pie torch"])
  #expect(result.learned.map(\.replacement) == ["Vani", "Core ML", "PyTorch"])
  #expect(
    result.learned.allSatisfy {
      $0.applicationBundleIdentifier == "com.apple.dt.Xcode"
    })
}

@Test
func ignoresUnchangedAndInsertionOnlyCorrections() {
  let engine = PersonalizationEngine()
  #expect(
    engine.learn(
      original: "hello world",
      corrected: "hello world",
      applicationBundleIdentifier: nil,
      existing: []
    ).learned.isEmpty
  )
  #expect(
    engine.learn(
      original: "hello world",
      corrected: "hello kind world",
      applicationBundleIdentifier: nil,
      existing: []
    ).learned.isEmpty
  )
}

@Test
func learnsExplicitRemovalAndAppliesItAtWordBoundaries() {
  let engine = PersonalizationEngine()
  let learned = engine.learn(
    original: "we should um ship this",
    corrected: "we should ship this",
    applicationBundleIdentifier: nil,
    existing: []
  ).corrections

  let output = engine.apply(
    "um we should um ship this summer",
    corrections: learned,
    manualDictionary: []
  )
  #expect(output == " we should  ship this summer")

  let pipelineOutput = TextPipeline().process(
    "um we should um ship this summer",
    dictionary: [],
    learnedCorrections: learned
  )
  #expect(pipelineOutput == "we should ship this summer")
}

@Test
func repeatedConfirmationMergesAndRaisesConfidence() {
  let engine = PersonalizationEngine()
  let first = engine.learn(
    original: "Vanny",
    corrected: "Vani",
    applicationBundleIdentifier: "one.app",
    existing: [],
    now: Date(timeIntervalSince1970: 1)
  )
  let second = engine.learn(
    original: "vanny",
    corrected: "Vani",
    applicationBundleIdentifier: "two.app",
    existing: first.corrections,
    now: Date(timeIntervalSince1970: 2)
  )

  #expect(second.corrections.count == 1)
  #expect(second.corrections[0].confirmationCount == 2)
  #expect(second.corrections[0].lastConfirmedAt == Date(timeIntervalSince1970: 2))
  #expect(second.corrections[0].applicationBundleIdentifier == nil)
}

@Test
func appSpecificConflictsChooseOneRuleAndNeverCascade() {
  let corrections = [
    LearnedCorrection(
      spoken: "vanny",
      replacement: "Vani",
      applicationBundleIdentifier: "first.app",
      confirmationCount: 10
    ),
    LearnedCorrection(
      spoken: "vanny",
      replacement: "Vanny Pro",
      applicationBundleIdentifier: "second.app",
      confirmationCount: 2
    ),
    LearnedCorrection(
      spoken: "Vani",
      replacement: "Cascaded",
      confirmationCount: 10
    ),
  ]

  let output = PersonalizationEngine().apply(
    "vanny",
    corrections: corrections,
    manualDictionary: [],
    applicationBundleIdentifier: "second.app"
  )
  #expect(output == "Vanny Pro")
}

@Test
func latestConfirmedCasingUpdatesAnExistingCorrectionWithoutDuplicatingIt() {
  let engine = PersonalizationEngine()
  let first = engine.learn(
    original: "Vanny", corrected: "Vani", applicationBundleIdentifier: "test.app", existing: [])
  let second = engine.learn(
    original: "Vanny", corrected: "VANI", applicationBundleIdentifier: "test.app",
    existing: first.corrections)

  #expect(second.corrections.count == 1)
  #expect(second.corrections.first?.id == first.corrections.first?.id)
  #expect(second.corrections.first?.confirmationCount == 2)
  #expect(second.learned.first?.replacement == "VANI")
  #expect(
    engine.apply(
      "Vanny works", corrections: second.corrections, manualDictionary: [],
      applicationBundleIdentifier: "test.app") == "VANI works")
}

@Test
func appSpecificCorrectionsNeverApplyOutsideTheirApp() {
  let correction = LearnedCorrection(
    spoken: "vanny",
    replacement: "Vani",
    applicationBundleIdentifier: "first.app",
    confirmationCount: 3
  )
  let engine = PersonalizationEngine()

  #expect(
    engine.apply(
      "vanny",
      corrections: [correction],
      manualDictionary: [],
      applicationBundleIdentifier: "second.app"
    ) == "vanny"
  )
  #expect(
    engine.apply(
      "vanny",
      corrections: [correction],
      manualDictionary: [],
      applicationBundleIdentifier: nil
    ) == "vanny"
  )
  #expect(
    TextPipeline().process(
      "vanny",
      dictionary: [],
      learnedCorrections: [correction],
      applicationBundleIdentifier: "second.app"
    ) == "vanny"
  )
}

@Test
func manualDictionaryOverridesLearnedCorrection() {
  let learned = LearnedCorrection(spoken: "flow", replacement: "Flow")
  let manual = DictionaryEntry(spoken: "flow", replacement: "FLOW")
  let output = TextPipeline().process(
    "flow",
    dictionary: [manual],
    learnedCorrections: [learned]
  )
  #expect(output == "FLOW")
}

@Test
func acousticTermsAreRankedScopedGroupedAndBounded() {
  let engine = PersonalizationEngine()
  let now = Date(timeIntervalSince1970: 10_000)
  var corrections: [LearnedCorrection] = [
    LearnedCorrection(
      spoken: "vanny",
      replacement: "Vani",
      applicationBundleIdentifier: "preferred.app",
      confirmationCount: 2,
      lastConfirmedAt: now
    ),
    LearnedCorrection(
      spoken: "van knee",
      replacement: "Vani",
      applicationBundleIdentifier: "other.app",
      confirmationCount: 9,
      lastConfirmedAt: now
    ),
    LearnedCorrection(spoken: "um", replacement: ""),
  ]
  for index in 0..<60 {
    corrections.append(
      LearnedCorrection(
        spoken: "heard term \(index)",
        replacement: "Canonical Term \(index)",
        confirmationCount: 2,
        lastConfirmedAt: Date(timeIntervalSince1970: Double(index))
      ))
  }

  let terms = engine.activeAcousticTerms(
    corrections: corrections,
    applicationBundleIdentifier: "preferred.app",
    manualDictionary: []
  )

  #expect(terms.count == PersonalizationEngine.maximumActiveAcousticTerms)
  #expect(terms.first?.canonical == "Vani")
  #expect(terms.first?.aliases == ["vanny"])
  #expect(!terms.contains(where: { $0.canonical.isEmpty }))
}

@Test
func acousticTermsNeverCrossApplicationScopes() {
  let correction = LearnedCorrection(
    spoken: "vanny",
    replacement: "Vani",
    applicationBundleIdentifier: "first.app",
    confirmationCount: 2
  )
  let engine = PersonalizationEngine()

  #expect(
    engine.activeAcousticTerms(
      corrections: [correction],
      applicationBundleIdentifier: "second.app",
      manualDictionary: []
    ).isEmpty
  )
  #expect(
    engine.activeAcousticTerms(
      corrections: [correction],
      applicationBundleIdentifier: nil,
      manualDictionary: []
    ).isEmpty
  )
}

@Test
func learnedCorrectionsCannotAccidentallyTriggerASnippet() {
  let output = TextPipeline().process(
    "male signature",
    dictionary: [],
    snippets: [SnippetEntry(trigger: "my signature", expansion: "Private expansion")],
    learnedCorrections: [
      LearnedCorrection(spoken: "male signature", replacement: "my signature")
    ]
  )
  #expect(output == "male signature")
}

@Test
func learnedCorrectionsCannotComposeASnippetTriggerWithAdjacentWords() {
  let snippets = [SnippetEntry(trigger: "my signature", expansion: "Private expansion")]

  let deletionOutput = TextPipeline().process(
    "my um signature",
    dictionary: [],
    snippets: snippets,
    learnedCorrections: [LearnedCorrection(spoken: "um", replacement: "")]
  )
  #expect(deletionOutput == "my um signature")

  let replacementOutput = TextPipeline().process(
    "male signature",
    dictionary: [],
    snippets: snippets,
    learnedCorrections: [LearnedCorrection(spoken: "male", replacement: "my")]
  )
  #expect(replacementOutput == "male signature")
}

@Test
func profileRejectsInvalidEntriesDeduplicatesAndBoundsCapacity() {
  var corrections = (0..<250).map {
    LearnedCorrection(
      spoken: "phrase \($0)",
      replacement: "replacement \($0)",
      confirmationCount: $0 + 1,
      lastConfirmedAt: Date(timeIntervalSince1970: Double($0))
    )
  }
  corrections.append(corrections[249])
  corrections.append(LearnedCorrection(spoken: "", replacement: "invalid"))

  let normalized = PersonalizationEngine.normalizedProfile(corrections)
  #expect(normalized.count == PersonalizationEngine.maximumCorrectionCount)
  #expect(normalized.first?.spoken == "phrase 249")
  #expect(!normalized.contains(where: { $0.spoken.isEmpty }))
}

@Test
func maximumProfileProcessesABoundedLongTranscript() {
  let corrections = (0..<PersonalizationEngine.maximumCorrectionCount).map { index in
    LearnedCorrection(
      spoken: "heard-term-\(index)",
      replacement: "Canonical-Term-\(index)",
      confirmationCount: index + 1
    )
  }
  let phrase = "heard-term-199 and ordinary words "
  let repetitions = PersonalizationEngine.maximumCorrectionCharacters / phrase.count
  let input = String(repeating: phrase, count: repetitions)

  let output = PersonalizationEngine().apply(
    input,
    corrections: corrections,
    manualDictionary: []
  )

  #expect(output.hasPrefix("Canonical-Term-199 and ordinary words"))
  #expect(!output.contains("heard-term-199"))
}

@Test
func settingsFromBeforePersonalizationDecodeWithLearningDisabled() throws {
  let legacy = #"{"shortcut":"function","historyEnabled":false,"historyLimit":100}"#
  let settings = try JSONDecoder().decode(VaniSettings.self, from: Data(legacy.utf8))
  #expect(!settings.personalizationEnabled)
}

@Test
func crossApplicationCorrectionStaysGlobalAfterFurtherConfirmations() {
  let engine = PersonalizationEngine()
  var corrections: [LearnedCorrection] = []
  for app in ["one.app", "two.app", "one.app", "three.app"] {
    corrections =
      engine.learn(
        original: "Vanny",
        corrected: "Vani",
        applicationBundleIdentifier: app,
        existing: corrections
      ).corrections
    if corrections[0].confirmationCount >= 2 {
      #expect(corrections[0].applicationBundleIdentifier == nil)
    }
  }

  #expect(corrections.count == 1)
  #expect(corrections[0].confirmationCount == 4)
  #expect(corrections[0].applicationBundleIdentifier == nil)
  #expect(
    engine.apply(
      "Vanny",
      corrections: corrections,
      manualDictionary: [],
      applicationBundleIdentifier: "another.app"
    ) == "Vani")
}
