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

  public func matchesModifierEvent(keyCode: Int64) -> Bool {
    switch self {
    case .rightOption: keyCode == 61
    case .rightCommand: keyCode == 54
    case .function: true
    }
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

public struct SnippetEntry: Identifiable, Codable, Sendable, Equatable {
  public static let maximumTriggerLength = 100
  public static let maximumExpansionLength = 4_000

  public let id: UUID
  public var trigger: String
  public var expansion: String

  public init(id: UUID = UUID(), trigger: String, expansion: String) {
    self.id = id
    self.trigger = trigger
    self.expansion = expansion
  }

  public var normalizedTrigger: String {
    trigger
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(
        of: #"[\t\n\r ]+"#,
        with: " ",
        options: .regularExpression
      )
  }

  public var isValid: Bool {
    !normalizedTrigger.isEmpty
      && normalizedTrigger.count <= Self.maximumTriggerLength
      && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && expansion.count <= Self.maximumExpansionLength
  }
}

public struct VaniSettings: Codable, Sendable, Equatable {
  public static let maximumSnippetCount = 200

  public var shortcut: HoldShortcut
  public var launchAtLogin: Bool
  public var historyEnabled: Bool
  public var historyLimit: Int
  public var dictionary: [DictionaryEntry]
  public var snippets: [SnippetEntry]
  public var smartFormattingEnabled: Bool

  public init(
    shortcut: HoldShortcut = .function,
    launchAtLogin: Bool = false,
    historyEnabled: Bool = false,
    historyLimit: Int = 100,
    dictionary: [DictionaryEntry] = [],
    snippets: [SnippetEntry] = [],
    smartFormattingEnabled: Bool = false
  ) {
    self.shortcut = shortcut
    self.launchAtLogin = launchAtLogin
    self.historyEnabled = historyEnabled
    self.historyLimit = min(max(historyLimit, 10), 500)
    self.dictionary = dictionary.filter(\.isValid)
    self.snippets = Array(snippets.filter(\.isValid).prefix(Self.maximumSnippetCount))
    self.smartFormattingEnabled = smartFormattingEnabled
  }

  public static let `default` = VaniSettings()

  private enum CodingKeys: String, CodingKey {
    case shortcut
    case launchAtLogin
    case historyEnabled
    case historyLimit
    case dictionary
    case snippets
    case smartFormattingEnabled
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      shortcut: try container.decodeIfPresent(HoldShortcut.self, forKey: .shortcut) ?? .function,
      launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
      historyEnabled: try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? false,
      historyLimit: try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 100,
      dictionary: try container.decodeIfPresent([DictionaryEntry].self, forKey: .dictionary) ?? [],
      snippets: try container.decodeIfPresent([SnippetEntry].self, forKey: .snippets) ?? [],
      smartFormattingEnabled: try container.decodeIfPresent(
        Bool.self,
        forKey: .smartFormattingEnabled
      ) ?? false
    )
  }
}
