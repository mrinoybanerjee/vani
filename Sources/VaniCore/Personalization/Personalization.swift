import Foundation

public struct LearnedCorrection: Identifiable, Codable, Sendable, Equatable {
  public static let maximumSpokenLength = 200
  public static let maximumReplacementLength = 1_000

  public let id: UUID
  public var spoken: String
  public var replacement: String
  public var applicationBundleIdentifier: String?
  public var confirmationCount: Int
  public var lastConfirmedAt: Date

  public init(
    id: UUID = UUID(),
    spoken: String,
    replacement: String,
    applicationBundleIdentifier: String? = nil,
    confirmationCount: Int = 1,
    lastConfirmedAt: Date = Date()
  ) {
    self.id = id
    self.spoken = Self.normalize(spoken)
    self.replacement = Self.normalize(replacement)
    self.applicationBundleIdentifier = Self.normalizedBundleIdentifier(
      applicationBundleIdentifier
    )
    self.confirmationCount = min(max(confirmationCount, 1), 10_000)
    self.lastConfirmedAt = lastConfirmedAt
  }

  public var normalizedSpoken: String { Self.normalize(spoken) }

  public var isValid: Bool {
    !normalizedSpoken.isEmpty
      && normalizedSpoken.count <= Self.maximumSpokenLength
      && replacement.count <= Self.maximumReplacementLength
      && !normalizedSpoken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && !replacement.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  static func normalize(_ phrase: String) -> String {
    phrase
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"[\t\n\r ]+"#, with: " ", options: .regularExpression)
  }

  private static func normalizedBundleIdentifier(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = normalize(value)
    guard !normalized.isEmpty, normalized.count <= 255,
      !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      return nil
    }
    return normalized
  }
}

public struct SpeechPersonalizationTerm: Sendable, Equatable {
  public let canonical: String
  public let aliases: [String]

  public init(canonical: String, aliases: [String]) {
    self.canonical = canonical
    self.aliases = aliases
  }
}

public struct PersonalizationLearningResult: Sendable, Equatable {
  public let corrections: [LearnedCorrection]
  public let learned: [LearnedCorrection]

  public init(corrections: [LearnedCorrection], learned: [LearnedCorrection]) {
    self.corrections = corrections
    self.learned = learned
  }
}

public struct CorrectionCandidate: Sendable, Equatable {
  public let id: UUID
  public let rawTranscript: String
  public let recognizedTranscript: String
  public let finalTranscript: String
  public let applicationBundleIdentifier: String?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    rawTranscript: String,
    recognizedTranscript: String,
    finalTranscript: String,
    applicationBundleIdentifier: String?,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.rawTranscript = rawTranscript
    self.recognizedTranscript = recognizedTranscript
    self.finalTranscript = finalTranscript
    self.applicationBundleIdentifier = applicationBundleIdentifier
    self.createdAt = createdAt
  }

  public var transcript: String { finalTranscript }
}

public struct PersonalizationEngine: Sendable {
  public static let maximumCorrectionCount = 200
  public static let maximumActiveAcousticTerms = 50
  public static let maximumCorrectionCharacters = 20_000
  public static let maximumDiffTokens = 400
  public static let maximumLearnedSpanTokens = 8

  public init() {}

  public func learn(
    original: String,
    corrected: String,
    applicationBundleIdentifier: String?,
    existing: [LearnedCorrection],
    now: Date = Date()
  ) -> PersonalizationLearningResult {
    let original = Self.bounded(original)
    let corrected = Self.bounded(corrected)
    guard original != corrected else {
      return PersonalizationLearningResult(
        corrections: Self.normalizedProfile(existing),
        learned: []
      )
    }

    let candidates = correctionSpans(from: original, to: corrected).compactMap {
      span -> LearnedCorrection? in
      let candidate = LearnedCorrection(
        spoken: span.original,
        replacement: span.corrected,
        applicationBundleIdentifier: applicationBundleIdentifier,
        lastConfirmedAt: now
      )
      return candidate.isValid ? candidate : nil
    }

    guard !candidates.isEmpty else {
      return PersonalizationLearningResult(
        corrections: Self.normalizedProfile(existing),
        learned: []
      )
    }

    var profile = Self.normalizedProfile(existing)
    var learned: [LearnedCorrection] = []

    for candidate in candidates {
      let spokenKey = candidate.normalizedSpoken.lowercased()
      let replacementKey = candidate.replacement.lowercased()
      if let index = profile.firstIndex(where: {
        $0.normalizedSpoken.lowercased() == spokenKey
          && $0.replacement.lowercased() == replacementKey
      }) {
        profile[index].confirmationCount = min(profile[index].confirmationCount + 1, 10_000)
        profile[index].lastConfirmedAt = now
        if profile[index].applicationBundleIdentifier == nil {
          profile[index].applicationBundleIdentifier = candidate.applicationBundleIdentifier
        } else if profile[index].applicationBundleIdentifier
          != candidate.applicationBundleIdentifier
        {
          profile[index].applicationBundleIdentifier = nil
        }
        learned.append(profile[index])
      } else {
        profile.removeAll {
          $0.normalizedSpoken.lowercased() == spokenKey
            && $0.applicationBundleIdentifier == candidate.applicationBundleIdentifier
        }
        profile.append(candidate)
        learned.append(candidate)
      }
    }

    profile.sort(by: Self.isHigherPriority)
    if profile.count > Self.maximumCorrectionCount {
      profile.removeLast(profile.count - Self.maximumCorrectionCount)
    }
    return PersonalizationLearningResult(corrections: profile, learned: learned)
  }

  public func apply(
    _ text: String,
    corrections: [LearnedCorrection],
    manualDictionary: [DictionaryEntry],
    snippets: [SnippetEntry] = [],
    applicationBundleIdentifier: String? = nil
  ) -> String {
    let manualTriggers = Set(
      manualDictionary.filter(\.isValid).map { $0.normalizedSpoken.lowercased() }
    )
    let snippetTriggers = Set(
      snippets.filter(\.isValid).map { $0.normalizedTrigger.lowercased() }
    )
    let active = Self.preferredCorrections(
      corrections,
      applicationBundleIdentifier: applicationBundleIdentifier
    )
    .filter {
      !manualTriggers.contains($0.normalizedSpoken.lowercased())
        && !snippetTriggers.contains($0.normalizedSpoken.lowercased())
        && !snippetTriggers.contains($0.replacement.lowercased())
    }
    .sorted {
      if $0.normalizedSpoken.count != $1.normalizedSpoken.count {
        return $0.normalizedSpoken.count > $1.normalizedSpoken.count
      }
      return Self.isHigherPriority($0, $1)
    }

    guard !active.isEmpty else { return text }
    let replacementBySpoken = Dictionary(
      uniqueKeysWithValues: active.map {
        ($0.normalizedSpoken.lowercased(), $0.replacement)
      }
    )
    let alternatives = active.map {
      NSRegularExpression.escapedPattern(for: $0.normalizedSpoken)
    }.joined(separator: "|")
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(?:"# + alternatives + #")(?![\p{L}\p{N}])"#
      )
    else {
      return text
    }
    let original = text as NSString
    let mutable = NSMutableString(string: text)
    let matches = expression.matches(
      in: text,
      range: NSRange(location: 0, length: original.length)
    )
    for match in matches.reversed() {
      let spoken = original.substring(with: match.range).lowercased()
      guard let replacement = replacementBySpoken[spoken] else { continue }
      mutable.replaceCharacters(in: match.range, with: replacement)
    }
    return mutable as String
  }

  public func activeAcousticTerms(
    corrections: [LearnedCorrection],
    applicationBundleIdentifier: String?,
    manualDictionary: [DictionaryEntry],
    snippets: [SnippetEntry] = []
  ) -> [SpeechPersonalizationTerm] {
    let manualTriggers = Set(
      manualDictionary.filter(\.isValid).map { $0.normalizedSpoken.lowercased() }
    )
    let snippetTriggers = Set(
      snippets.filter(\.isValid).map { $0.normalizedTrigger.lowercased() }
    )
    let eligible = Self.preferredCorrections(
      corrections,
      applicationBundleIdentifier: applicationBundleIdentifier
    ).filter {
      !$0.replacement.isEmpty
        && $0.replacement.count >= 4
        && $0.confirmationCount >= 2
        && !manualTriggers.contains($0.normalizedSpoken.lowercased())
        && !snippetTriggers.contains($0.normalizedSpoken.lowercased())
        && !snippetTriggers.contains($0.replacement.lowercased())
    }
    let ranked = eligible.sorted { lhs, rhs in
      let lhsApp = lhs.applicationBundleIdentifier == applicationBundleIdentifier ? 1 : 0
      let rhsApp = rhs.applicationBundleIdentifier == applicationBundleIdentifier ? 1 : 0
      if lhsApp != rhsApp { return lhsApp > rhsApp }
      return Self.isHigherPriority(lhs, rhs)
    }

    var order: [String] = []
    var aliasesByCanonical: [String: [String]] = [:]
    var canonicalByKey: [String: String] = [:]
    for correction in ranked {
      let key = correction.replacement.lowercased()
      if canonicalByKey[key] == nil {
        canonicalByKey[key] = correction.replacement
        order.append(key)
      }
      var aliases = aliasesByCanonical[key, default: []]
      if correction.normalizedSpoken.count >= 3,
        correction.normalizedSpoken.caseInsensitiveCompare(correction.replacement) != .orderedSame,
        !aliases.contains(where: {
          $0.caseInsensitiveCompare(correction.normalizedSpoken) == .orderedSame
        }), aliases.count < 8
      {
        aliases.append(correction.normalizedSpoken)
      }
      aliasesByCanonical[key] = aliases
    }

    return order.prefix(Self.maximumActiveAcousticTerms).compactMap { key in
      guard let canonical = canonicalByKey[key] else { return nil }
      return SpeechPersonalizationTerm(
        canonical: canonical,
        aliases: aliasesByCanonical[key] ?? []
      )
    }
  }

  public static func normalizedProfile(_ corrections: [LearnedCorrection]) -> [LearnedCorrection] {
    var seen = Set<String>()
    var result: [LearnedCorrection] = []
    for correction in corrections where correction.isValid {
      let normalized = LearnedCorrection(
        id: correction.id,
        spoken: correction.spoken,
        replacement: correction.replacement,
        applicationBundleIdentifier: correction.applicationBundleIdentifier,
        confirmationCount: correction.confirmationCount,
        lastConfirmedAt: correction.lastConfirmedAt
      )
      let key = [
        normalized.normalizedSpoken.lowercased(),
        normalized.replacement.lowercased(),
        normalized.applicationBundleIdentifier?.lowercased() ?? "",
      ].joined(separator: "\u{001F}")
      guard seen.insert(key).inserted else { continue }
      result.append(normalized)
    }
    result.sort(by: isHigherPriority)
    return Array(result.prefix(maximumCorrectionCount))
  }

  private func correctionSpans(
    from original: String,
    to corrected: String
  ) -> [(original: String, corrected: String)] {
    let originalTokens = Self.tokens(in: original)
    let correctedTokens = Self.tokens(in: corrected)
    guard !originalTokens.isEmpty else { return [] }

    if originalTokens.count > Self.maximumDiffTokens
      || correctedTokens.count > Self.maximumDiffTokens
    {
      return Self.singleBoundedSpan(from: originalTokens, to: correctedTokens)
    }

    let rows = originalTokens.count + 1
    let columns = correctedTokens.count + 1
    var table = Array(repeating: 0, count: rows * columns)
    func index(_ row: Int, _ column: Int) -> Int { row * columns + column }
    for row in stride(from: originalTokens.count - 1, through: 0, by: -1) {
      for column in stride(from: correctedTokens.count - 1, through: 0, by: -1) {
        if originalTokens[row] == correctedTokens[column] {
          table[index(row, column)] = table[index(row + 1, column + 1)] + 1
        } else {
          table[index(row, column)] = max(
            table[index(row + 1, column)],
            table[index(row, column + 1)]
          )
        }
      }
    }

    enum Operation {
      case equal(String)
      case remove(String)
      case insert(String)
    }
    var operations: [Operation] = []
    var row = 0
    var column = 0
    while row < originalTokens.count || column < correctedTokens.count {
      if row < originalTokens.count, column < correctedTokens.count,
        originalTokens[row] == correctedTokens[column]
      {
        operations.append(.equal(originalTokens[row]))
        row += 1
        column += 1
      } else if column < correctedTokens.count,
        row == originalTokens.count
          || table[index(row, column + 1)] >= table[index(row + 1, column)]
      {
        operations.append(.insert(correctedTokens[column]))
        column += 1
      } else {
        operations.append(.remove(originalTokens[row]))
        row += 1
      }
    }

    var spans: [(original: [String], corrected: [String])] = []
    var removed: [String] = []
    var inserted: [String] = []
    func flush() {
      guard !removed.isEmpty else {
        inserted.removeAll(keepingCapacity: true)
        return
      }
      if removed.count <= Self.maximumLearnedSpanTokens,
        inserted.count <= Self.maximumLearnedSpanTokens
      {
        spans.append((removed, inserted))
      }
      removed.removeAll(keepingCapacity: true)
      inserted.removeAll(keepingCapacity: true)
    }

    for operation in operations {
      switch operation {
      case .equal:
        flush()
      case .remove(let token):
        removed.append(token)
      case .insert(let token):
        inserted.append(token)
      }
    }
    flush()
    return spans.map { ($0.original.joined(separator: " "), $0.corrected.joined(separator: " ")) }
  }

  private static func singleBoundedSpan(
    from original: [String],
    to corrected: [String]
  ) -> [(original: String, corrected: String)] {
    var prefix = 0
    while prefix < original.count, prefix < corrected.count,
      original[prefix] == corrected[prefix]
    {
      prefix += 1
    }
    var originalSuffix = original.count
    var correctedSuffix = corrected.count
    while originalSuffix > prefix, correctedSuffix > prefix,
      original[originalSuffix - 1] == corrected[correctedSuffix - 1]
    {
      originalSuffix -= 1
      correctedSuffix -= 1
    }
    let removed = Array(original[prefix..<originalSuffix])
    let inserted = Array(corrected[prefix..<correctedSuffix])
    guard !removed.isEmpty,
      removed.count <= maximumLearnedSpanTokens,
      inserted.count <= maximumLearnedSpanTokens
    else {
      return []
    }
    return [(removed.joined(separator: " "), inserted.joined(separator: " "))]
  }

  private static func preferredCorrections(
    _ corrections: [LearnedCorrection],
    applicationBundleIdentifier: String?
  ) -> [LearnedCorrection] {
    let profile = normalizedProfile(corrections)
    var selected: [String: LearnedCorrection] = [:]
    for correction in profile
    where scopeRank(correction, for: applicationBundleIdentifier) > 0 {
      let key = correction.normalizedSpoken.lowercased()
      guard let current = selected[key] else {
        selected[key] = correction
        continue
      }
      if scopeRank(correction, for: applicationBundleIdentifier)
        > scopeRank(current, for: applicationBundleIdentifier)
      {
        selected[key] = correction
      }
    }
    return selected.values.sorted(by: isHigherPriority)
  }

  private static func scopeRank(
    _ correction: LearnedCorrection,
    for applicationBundleIdentifier: String?
  ) -> Int {
    if let applicationBundleIdentifier,
      correction.applicationBundleIdentifier == applicationBundleIdentifier
    {
      return 2
    }
    return correction.applicationBundleIdentifier == nil ? 1 : 0
  }

  private static func tokens(in text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  private static func bounded(_ text: String) -> String {
    let prefix = text.prefix(maximumCorrectionCharacters)
    return LearnedCorrection.normalize(String(prefix))
  }

  private static func isHigherPriority(_ lhs: LearnedCorrection, _ rhs: LearnedCorrection) -> Bool {
    if lhs.confirmationCount != rhs.confirmationCount {
      return lhs.confirmationCount > rhs.confirmationCount
    }
    if lhs.lastConfirmedAt != rhs.lastConfirmedAt {
      return lhs.lastConfirmedAt > rhs.lastConfirmedAt
    }
    if lhs.normalizedSpoken.count != rhs.normalizedSpoken.count {
      return lhs.normalizedSpoken.count > rhs.normalizedSpoken.count
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
