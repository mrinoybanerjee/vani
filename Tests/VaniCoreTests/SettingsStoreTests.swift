import CoreGraphics
import Foundation
import Testing

@testable import VaniCore

@Test
func defaultSettingsUseLeftFunctionShortcut() {
  #expect(VaniSettings.default.shortcut == .function)
  #expect(HoldShortcut.function.label == "Left Fn")
  #expect(VaniSettings.default.snippets.isEmpty)
  #expect(!VaniSettings.default.smartFormattingEnabled)
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
    shortcut: .function,
    historyEnabled: true,
    historyLimit: 42,
    dictionary: [DictionaryEntry(spoken: "voice", replacement: "Vani")],
    snippets: [SnippetEntry(trigger: "sign off", expansion: "Thanks,\nMrinoy")],
    smartFormattingEnabled: true
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
