import Foundation

private func normalizedPhrase(_ phrase: String) -> String {
  phrase
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(
      of: #"[\t\n\r ]+"#,
      with: " ",
      options: .regularExpression
    )
}

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
  public static let maximumSpokenLength = 100
  public static let maximumReplacementLength = 1_000

  public let id: UUID
  public var spoken: String
  public var replacement: String

  public init(id: UUID = UUID(), spoken: String, replacement: String) {
    self.id = id
    self.spoken = spoken
    self.replacement = replacement
  }

  public var normalizedSpoken: String {
    normalizedPhrase(spoken)
  }

  public var isValid: Bool {
    !normalizedSpoken.isEmpty
      && normalizedSpoken.count <= Self.maximumSpokenLength
      && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && replacement.count <= Self.maximumReplacementLength
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
    normalizedPhrase(trigger)
  }

  public var isValid: Bool {
    !normalizedTrigger.isEmpty
      && normalizedTrigger.count <= Self.maximumTriggerLength
      && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && expansion.count <= Self.maximumExpansionLength
  }
}

public struct VaniSettings: Codable, Sendable, Equatable {
  public static let maximumDictionaryEntryCount = 500
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

    var dictionaryKeys = Set<String>()
    var boundedDictionary: [DictionaryEntry] = []
    boundedDictionary.reserveCapacity(
      min(dictionary.count, Self.maximumDictionaryEntryCount)
    )
    for entry in dictionary where entry.isValid {
      guard dictionaryKeys.insert(entry.normalizedSpoken.lowercased()).inserted else {
        continue
      }
      boundedDictionary.append(entry)
      if boundedDictionary.count == Self.maximumDictionaryEntryCount {
        break
      }
    }
    self.dictionary = boundedDictionary

    var snippetKeys = Set<String>()
    var boundedSnippets: [SnippetEntry] = []
    boundedSnippets.reserveCapacity(min(snippets.count, Self.maximumSnippetCount))
    for entry in snippets where entry.isValid {
      let key = entry.normalizedTrigger.lowercased()
      guard !dictionaryKeys.contains(key),
        snippetKeys.insert(key).inserted
      else {
        continue
      }
      boundedSnippets.append(entry)
      if boundedSnippets.count == Self.maximumSnippetCount {
        break
      }
    }
    self.snippets = boundedSnippets
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
