import Foundation

public enum HoldShortcut: String, Codable, CaseIterable, Sendable, Equatable, Identifiable {
  case rightOption
  case rightCommand
  case function

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .rightOption: "Right Option"
    case .rightCommand: "Right Command"
    case .function: "Left Fn"
    }
  }

  public func resolvedPressedState(
    keyStateIsPressed: Bool,
    functionModifierIsSet: Bool
  ) -> Bool {
    self == .function ? functionModifierIsSet : keyStateIsPressed
  }
}

public struct DictionaryEntry: Identifiable, Codable, Sendable, Equatable {
  public let id: UUID
  public var spoken: String
  public var replacement: String

  public init(id: UUID = UUID(), spoken: String, replacement: String) {
    self.id = id
    self.spoken = spoken
    self.replacement = replacement
  }

  public var isValid: Bool {
    !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

public struct VaniSettings: Codable, Sendable, Equatable {
  public var shortcut: HoldShortcut
  public var launchAtLogin: Bool
  public var historyEnabled: Bool
  public var historyLimit: Int
  public var dictionary: [DictionaryEntry]

  public init(
    shortcut: HoldShortcut = .function,
    launchAtLogin: Bool = false,
    historyEnabled: Bool = false,
    historyLimit: Int = 100,
    dictionary: [DictionaryEntry] = []
  ) {
    self.shortcut = shortcut
    self.launchAtLogin = launchAtLogin
    self.historyEnabled = historyEnabled
    self.historyLimit = min(max(historyLimit, 10), 500)
    self.dictionary = dictionary.filter(\.isValid)
  }

  public static let `default` = VaniSettings()
}
