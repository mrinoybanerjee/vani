import Foundation
import Testing

@testable import VaniCore

@Test
func defaultSettingsUseLeftFunctionShortcut() {
  #expect(VaniSettings.default.shortcut == .function)
  #expect(HoldShortcut.function.label == "Left Fn")
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
func settingsRoundTrip() async throws {
  let suite = "VaniCoreTests.\(UUID().uuidString)"
  let store = SettingsStore(suiteName: suite)
  let settings = VaniSettings(
    shortcut: .function,
    historyEnabled: true,
    historyLimit: 42,
    dictionary: [DictionaryEntry(spoken: "voice", replacement: "Vani")]
  )

  try await store.save(settings)
  let loaded = await store.load()

  #expect(loaded == settings)
  await store.clearSuiteForTesting()
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
