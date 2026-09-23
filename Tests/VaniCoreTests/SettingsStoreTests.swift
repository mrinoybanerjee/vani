import CoreGraphics
import Foundation
import Testing

@testable import VaniCore

@Test
func defaultSettingsUseLeftFunctionShortcut() {
  #expect(VaniSettings.default.shortcut == .function)
  #expect(HoldShortcut.function.label == "Left Fn")
  #expect(HoldShortcut.leftControl.label == "Left Control")
  #expect(VaniSettings.default.snippets.isEmpty)
  #expect(!VaniSettings.default.smartFormattingEnabled)
  #expect(VaniSettings.default.soundFeedbackEnabled)
}

@Test
func functionShortcutUsesEventModifierState() {
  #expect(
    HoldShortcut.function.resolvedPressedState(
      keyStateIsPressed: false,
      functionModifierIsSet: true
    )
  )
  #expect(
    !HoldShortcut.function.resolvedPressedState(
      keyStateIsPressed: true,
      functionModifierIsSet: false
    )
  )
  #expect(
    HoldShortcut.rightOption.resolvedPressedState(
      keyStateIsPressed: true,
      functionModifierIsSet: false
    )
  )
  #expect(HoldShortcut.function.matchesModifierEvent(keyCode: 63))
  #expect(HoldShortcut.function.matchesModifierEvent(keyCode: 0))
  #expect(HoldShortcut.rightOption.matchesModifierEvent(keyCode: 61))
  #expect(!HoldShortcut.rightOption.matchesModifierEvent(keyCode: 58))
  #expect(HoldShortcut.leftControl.matchesModifierEvent(keyCode: 59))
  #expect(!HoldShortcut.leftControl.matchesModifierEvent(keyCode: 62))
  #expect(
    HoldShortcut.leftControl.yieldsToCommandChord(
      keyCode: 54,
      keyStateIsPressed: true,
      commandModifierIsSet: true
    )
  )
  #expect(
    HoldShortcut.leftControl.yieldsToCommandChord(
      keyCode: 55,
      keyStateIsPressed: true,
      commandModifierIsSet: true
    )
  )
  #expect(
    HoldShortcut.leftControl.yieldsToCommandChord(
      keyCode: 59,
      keyStateIsPressed: true,
      commandModifierIsSet: true
    )
  )
  #expect(
    !HoldShortcut.leftControl.yieldsToCommandChord(
      keyCode: 54,
      keyStateIsPressed: false,
      commandModifierIsSet: false
    )
  )
  #expect(
    !HoldShortcut.rightOption.yieldsToCommandChord(
      keyCode: 54,
      keyStateIsPressed: true,
      commandModifierIsSet: true
    )
  )
}

@Test
func lastTranscriptShortcutsRequireExactCommandAndControlChord() {
  let commandAndControl =
    CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue

  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 9,
      modifierFlagsRawValue: commandAndControl,
      isRepeat: false
    ) == .paste
  )
  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 8,
      modifierFlagsRawValue: commandAndControl,
      isRepeat: false
    ) == .copy
  )
  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 9,
      modifierFlagsRawValue: CGEventFlags.maskCommand.rawValue,
      isRepeat: false
    ) == nil
  )
  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 9,
      modifierFlagsRawValue: commandAndControl | CGEventFlags.maskShift.rawValue,
      isRepeat: false
    ) == nil
  )
  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 9,
      modifierFlagsRawValue: commandAndControl,
      isRepeat: true
    ) == nil
  )
}

@Test
func settingsRoundTrip() async throws {
  let suite = "VaniCoreTests.\(UUID().uuidString)"
  let store = SettingsStore(suiteName: suite)
  let settings = VaniSettings(
    shortcut: .leftControl,
    historyEnabled: true,
    historyLimit: 42,
    dictionary: [DictionaryEntry(spoken: "voice", replacement: "Vani")],
    snippets: [SnippetEntry(trigger: "sign off", expansion: "Thanks,\nMrinoy")],
    smartFormattingEnabled: true,
    soundFeedbackEnabled: false
  )

  try await store.save(settings)
  let loaded = await store.load()

  #expect(loaded == settings)
  await store.clearSuiteForTesting()
}

@Test
func settingsFromEarlierVersionsKeepTheirSavedValues() async throws {
  let suite = "VaniCoreTests.\(UUID().uuidString)"
  let store = SettingsStore(suiteName: suite)
  let legacyJSON = Data(
    """
    {
      "shortcut": "rightOption",
      "launchAtLogin": true,
      "historyEnabled": true,
      "historyLimit": 42,
      "dictionary": [
        {"id": "B680F390-659E-4E76-9B54-4C5537AB3149", "spoken": "voice", "replacement": "Vani"}
      ]
    }
    """.utf8
  )
  await store.storeRawDataForTesting(legacyJSON)

  let loaded = await store.load()

  #expect(loaded.shortcut == .rightOption)
  #expect(loaded.launchAtLogin)
  #expect(loaded.historyEnabled)
  #expect(loaded.historyLimit == 42)
  #expect(loaded.dictionary.map(\.replacement) == ["Vani"])
  #expect(loaded.snippets.isEmpty)
  #expect(!loaded.smartFormattingEnabled)
  #expect(loaded.soundFeedbackEnabled)
  await store.clearSuiteForTesting()
}

@Test
func legacySettingsGiveDictionaryEntriesPrecedenceOverConflictingSnippets() async {
  let suite = "VaniCoreTests.\(UUID().uuidString)"
  let store = SettingsStore(suiteName: suite)
  let legacyJSON = Data(
    """
    {
      "dictionary": [
        {"id": "B680F390-659E-4E76-9B54-4C5537AB3149", "spoken": "sign off", "replacement": "Goodbye"}
      ],
      "snippets": [
        {"id": "FB761B62-6D10-43D6-9907-9CDDE07AB76A", "trigger": "SIGN   OFF", "expansion": "Thanks"}
      ]
    }
    """.utf8
  )
  await store.storeRawDataForTesting(legacyJSON)

  let loaded = await store.load()

  #expect(loaded.dictionary.map(\.replacement) == ["Goodbye"])
  #expect(loaded.snippets.isEmpty)
  await store.clearSuiteForTesting()
}

@Test
func invalidOrOversizedSnippetsAreFilteredFromSettings() {
  let settings = VaniSettings(snippets: [
    SnippetEntry(trigger: " ", expansion: "text"),
    SnippetEntry(trigger: "valid", expansion: " "),
    SnippetEntry(
      trigger: "valid",
      expansion: String(repeating: "a", count: SnippetEntry.maximumExpansionLength + 1)
    ),
    SnippetEntry(trigger: "works", expansion: "Saved text"),
  ])

  #expect(settings.snippets.map(\.trigger) == ["works"])
}

@Test
func settingsNormalizeDeduplicateAndBoundDictionaryEntries() {
  let entries =
    [
      DictionaryEntry(spoken: "  voice\tflow ", replacement: "Vani"),
      DictionaryEntry(spoken: "VOICE FLOW", replacement: "duplicate"),
      DictionaryEntry(
        spoken: String(repeating: "a", count: DictionaryEntry.maximumSpokenLength + 1),
        replacement: "too long"
      ),
    ]
    + (0..<VaniSettings.maximumDictionaryEntryCount).map {
      DictionaryEntry(spoken: "phrase \($0)", replacement: "replacement \($0)")
    }

  let settings = VaniSettings(dictionary: entries)

  #expect(settings.dictionary.count == VaniSettings.maximumDictionaryEntryCount)
  #expect(settings.dictionary.first?.normalizedSpoken == "voice flow")
  #expect(!settings.dictionary.contains(where: { $0.replacement == "duplicate" }))
  #expect(!settings.dictionary.contains(where: { $0.replacement == "too long" }))
}

@Test
func settingsDeduplicateSnippetTriggersAfterNormalization() {
  let settings = VaniSettings(snippets: [
    SnippetEntry(trigger: " sign   off ", expansion: "First"),
    SnippetEntry(trigger: "SIGN OFF", expansion: "Second"),
  ])

  #expect(settings.snippets.map(\.expansion) == ["First"])
}

@Test
func settingsBoundTheSnippetCollection() {
  let snippets = (0...VaniSettings.maximumSnippetCount).map {
    SnippetEntry(trigger: "trigger \($0)", expansion: "text \($0)")
  }

  #expect(VaniSettings(snippets: snippets).snippets.count == VaniSettings.maximumSnippetCount)
}

@Test
func corruptSettingsFallBackToDefaults() async throws {
  let suite = "VaniCoreTests.\(UUID().uuidString)"
  let store = SettingsStore(suiteName: suite)
  await store.storeRawDataForTesting(Data("not-json".utf8))

  let loaded = await store.load()

  #expect(loaded == .default)
  await store.clearSuiteForTesting()
}

@Test
func staleSettingsRevisionCannotOverwriteNewerSettings() async throws {
  let suite = "VaniTests.\(UUID().uuidString)"
  let store = SettingsStore(suiteName: suite)

  var newer = VaniSettings.default
  newer.shortcut = .function
  var stale = VaniSettings.default
  stale.shortcut = .rightCommand

  #expect(try await store.save(newer, revision: 2))
  #expect(try await !store.save(stale, revision: 1))
  #expect(await store.load().shortcut == .function)
  await store.clearSuiteForTesting()
}

@Test
func lastTranscriptShortcutsFollowTheConfiguredChord() {
  let optionCommand = CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
  let controlCommand = CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue

  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 9, modifierFlagsRawValue: optionCommand, isRepeat: false,
      binding: .optionCommand) == .paste)
  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 9, modifierFlagsRawValue: controlCommand, isRepeat: false,
      binding: .optionCommand) == nil)
  #expect(
    LastTranscriptShortcutResolver.action(
      keyCode: 8, modifierFlagsRawValue: controlCommand, isRepeat: false,
      binding: .disabled) == nil)
}

@Test
func unknownSettingValuesResetOnlyThemselvesAndKeepTheUsersVocabulary() throws {
  let json = """
    {"shortcut":"futureKey","historyEnabled":true,
     "dictionary":[{"id":"\(UUID().uuidString)","spoken":"vani","replacement":"Vani"},
                   {"spoken":"missing id"}],
     "snippets":[{"id":"\(UUID().uuidString)","trigger":"sig","expansion":"Best, M"}],
     "lastTranscriptBinding":"unknownChord"}
    """
  let settings = try JSONDecoder().decode(VaniSettings.self, from: Data(json.utf8))

  #expect(settings.shortcut == .function)
  #expect(settings.historyEnabled)
  #expect(settings.dictionary.map(\.replacement) == ["Vani"])
  #expect(settings.snippets.map(\.expansion) == ["Best, M"])
  #expect(settings.lastTranscriptBinding == .controlCommand)
  #expect(settings.handsFreeEnabled)
  #expect(settings.escapeCancelsEnabled)
}
