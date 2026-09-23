import Foundation

public struct TextPipeline: Sendable {
  public init() {}

  public func process(
    _ rawText: String,
    dictionary: [DictionaryEntry],
    snippets: [SnippetEntry] = [],
    smartFormattingEnabled: Bool = false,
    learnedCorrections: [LearnedCorrection] = [],
    applicationBundleIdentifier: String? = nil
  ) -> String {
    var text = cleanSpacing(in: normalizeInlineWhitespace(rawText))
    let beforePersonalization = text
    let personalized = cleanSpacing(
      in: PersonalizationEngine().apply(
        text,
        corrections: learnedCorrections,
        manualDictionary: dictionary,
        snippets: snippets,
        applicationBundleIdentifier: applicationBundleIdentifier
      )
    )
    if learnedCorrections.isEmpty || snippets.isEmpty {
      text = personalized
    } else {
      let originalSnippetTriggerCounts = snippetTriggerCounts(snippets, in: text)
      let personalizedSnippetTriggerCounts = snippetTriggerCounts(snippets, in: personalized)
      let introducedSnippetTrigger = personalizedSnippetTriggerCounts.contains {
        trigger, count in
        count > originalSnippetTriggerCounts[trigger, default: 0]
      }
      text = introducedSnippetTrigger ? beforePersonalization : personalized
    }
    text = cleanSpacing(in: text)
    text = applyDictionary(dictionary, to: text)

    let protected = protectSnippets(snippets, in: text)
    text = protected.text

    if smartFormattingEnabled {
      text = applySmartFormatting(to: text)
    }

    for replacement in protected.replacements {
      text = restoreSnippet(replacement, in: text)
    }
    let boundaryCharacters: CharacterSet =
      smartFormattingEnabled ? .whitespaces : .whitespacesAndNewlines
    return text.trimmingCharacters(in: boundaryCharacters)
  }

  private func restoreSnippet(_ replacement: ProtectedSnippet, in text: String) -> String {
    var result = text
    if replacement.expansion.last.map(Self.snippetBoundaryPunctuation.contains) == true {
      let pattern =
        NSRegularExpression.escapedPattern(for: replacement.token)
        + #"[ \t]*[,.;:!?…]+"#
      result = result.replacingOccurrences(
        of: pattern,
        with: NSRegularExpression.escapedTemplate(for: replacement.expansion),
        options: .regularExpression
      )
    }
    return result.replacingOccurrences(of: replacement.token, with: replacement.expansion)
  }

  private func normalizeInlineWhitespace(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\u{00A0}", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(
        of: #"[\t\n\r ]+"#,
        with: " ",
        options: .regularExpression
      )
  }

  private func applyDictionary(_ dictionary: [DictionaryEntry], to text: String) -> String {
    var result = text
    for entry in dictionary where entry.isValid {
      let escaped = NSRegularExpression.escapedPattern(
        for: entry.normalizedSpoken
      )
      result = result.replacingOccurrences(
        of: #"(?i)(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#,
        with: NSRegularExpression.escapedTemplate(for: entry.replacement),
        options: .regularExpression
      )
    }
    return result
  }

  private func protectSnippets(
    _ snippets: [SnippetEntry],
    in text: String
  ) -> (text: String, replacements: [ProtectedSnippet]) {
    var seen = Set<String>()
    let prepared =
      snippets
      .enumerated()
      .compactMap { order, entry -> PreparedSnippet? in
        guard entry.isValid else { return nil }
        return PreparedSnippet(
          order: order,
          trigger: entry.normalizedTrigger,
          expansion: entry.expansion
        )
      }
      .sorted { lhs, rhs in
        if lhs.trigger.count != rhs.trigger.count {
          return lhs.trigger.count > rhs.trigger.count
        }
        return lhs.order < rhs.order
      }
      .filter { seen.insert($0.trigger.lowercased()).inserted }

    guard !prepared.isEmpty else { return (text, []) }

    let alternatives = prepared.map {
      NSRegularExpression.escapedPattern(for: $0.trigger)
    }.joined(separator: "|")
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:"# + alternatives + #")(?![\p{L}\p{N}])"#,
        options: .caseInsensitive
      )
    else {
      return (text, [])
    }

    let nonce = UUID().uuidString
    let replacements = prepared.enumerated().map { index, snippet in
      ProtectedSnippet(
        trigger: snippet.trigger.lowercased(),
        token: "\u{E000}VANI_\(nonce)_\(index)\u{E001}",
        expansion: snippet.expansion
      )
    }
    let replacementsByTrigger = Dictionary(
      uniqueKeysWithValues: replacements.map { ($0.trigger, $0) }
    )

    let source = text as NSString
    let mutable = NSMutableString(string: text)
    let matches = expression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    )
    for match in matches.reversed() {
      let trigger = source.substring(with: match.range).lowercased()
      guard let replacement = replacementsByTrigger[trigger] else { continue }
      mutable.replaceCharacters(in: match.range, with: replacement.token)
    }
    return (String(mutable), replacements)
  }

  private func snippetTriggerCounts(
    _ snippets: [SnippetEntry],
    in text: String
  ) -> [String: Int] {
    guard !snippets.isEmpty, !text.isEmpty else { return [:] }
    var seen = Set<String>()
    let triggers = snippets.compactMap { entry -> String? in
      guard entry.isValid else { return nil }
      let trigger = entry.normalizedTrigger
      return seen.insert(trigger.lowercased()).inserted ? trigger : nil
    }.sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
    guard !triggers.isEmpty else { return [:] }
    let alternatives = triggers.map { NSRegularExpression.escapedPattern(for: $0) }
      .joined(separator: "|")
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:"# + alternatives + #")(?![\p{L}\p{N}])"#,
        options: .caseInsensitive
      )
    else { return [:] }
    let source = text as NSString
    var counts: [String: Int] = [:]
    for match in expression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    ) {
      counts[source.substring(with: match.range).lowercased(), default: 0] += 1
    }
    return counts
  }

  private func applySmartFormatting(to text: String) -> String {
    let protected = protectTechnicalTokens(in: text)
    var result = removeFillers(in: protected.text)

    let structuralCommands: [(phrase: String, replacement: String)] = [
      ("new paragraph", "\n\n"),
      ("next paragraph", "\n\n"),
      ("new line", "\n"),
      ("next line", "\n"),
    ]
    result = replaceSpokenCommands(
      structuralCommands,
      in: result,
      leadingArtifactPattern: #"[,;:]"#
    )

    let punctuationCommands: [(phrase: String, replacement: String)] = [
      ("exclamation point", "!"),
      ("exclamation mark", "!"),
      ("question mark", "?"),
      ("full stop", "."),
      ("semicolon", ";"),
      ("period", "."),
      ("comma", ","),
      ("colon", ":"),
    ]
    result = replaceSpokenCommands(
      punctuationCommands,
      in: result,
      leadingArtifactPattern: #"[,.;:!?…]"#,
      nounReadings: Self.punctuationWordsWithNounReadings
    )
    result = applyScratchThat(in: result)

    result = capitalizeSentenceStarts(
      in: cleanSpacing(in: result, preserveBoundaryNewlines: true)
    )
    let tidier = SpeechTidier()
    result = result.split(separator: "\n", omittingEmptySubsequences: false)
      .map { tidier.tidy(String($0)) }
      .joined(separator: "\n")
    for replacement in protected.replacements {
      result = result.replacingOccurrences(of: replacement.token, with: replacement.value)
    }
    return result
  }

  private func protectTechnicalTokens(
    in text: String
  ) -> (text: String, replacements: [ProtectedText]) {
    guard
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
      )
    else {
      return (text, [])
    }

    let source = text as NSString
    let matches = detector.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    )
    guard !matches.isEmpty else { return (text, []) }

    let nonce = UUID().uuidString
    let replacements = matches.enumerated().map { index, match in
      ProtectedText(
        token: "\u{E000}VANI_TECH_\(nonce)_\(index)\u{E001}",
        value: source.substring(with: match.range)
      )
    }
    let mutable = NSMutableString(string: text)
    for (match, replacement) in zip(matches, replacements).reversed() {
      mutable.replaceCharacters(in: match.range, with: replacement.token)
    }
    return (String(mutable), replacements)
  }

  private func removeFillers(in text: String) -> String {
    let pattern =
      #"(?i)(?<!["# + Self.lexicalCharacterPattern + #"])(?:um+|uh+|erm+)"#
      + #"(?!["# + Self.lexicalCharacterPattern + #"])(?:[ \t]*[,.;:!?…]+)?"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return text
    }

    let source = text as NSString
    let mutable = NSMutableString(string: text)
    let quoteMarkOffsets = (0..<source.length).filter {
      Self.doubleQuoteMarks.contains(source.character(at: $0))
    }
    let matches = expression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    )
    for match in matches.reversed() {
      // Quoted speech stays verbatim: He said "um, no".
      if quoteMarkOffsets.count(where: { $0 < match.range.location }) % 2 == 1 { continue }
      let previousCharacter = character(
        in: source,
        atUTF16Offset: match.range.location - 1
      )
      let nextCharacter = character(
        in: source,
        atUTF16Offset: NSMaxRange(match.range)
      )
      let replacement =
        if let previousCharacter, let nextCharacter,
          nextCharacter.isLetter || nextCharacter.isNumber,
          previousCharacter.isLetter || previousCharacter.isNumber
            || ",.;:!?".contains(previousCharacter)
        {
          " "
        } else {
          ""
        }
      mutable.replaceCharacters(in: match.range, with: replacement)
    }
    return String(mutable)
  }

  /// "Scratch that" deletes the sentence or clause spoken just before it. It counts as a
  /// command only when it stands alone: it starts the text, a sentence or a clause, and is
  /// followed by punctuation or the end. "I told him to delete that." and "Please scratch
  /// that item" stay literal. Nothing before the previous sentence boundary is touched.
  private func applyScratchThat(in text: String) -> String {
    let lexical = Self.lexicalCharacterPattern
    let pattern =
      #"(?i)(?<![\#(lexical)])(?:scratch|delete) that(?![\#(lexical)])[ \t]*([,.;:!?…]*)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
    var result = text
    var searchStart = 0
    while true {
      let source = result as NSString
      guard searchStart <= source.length,
        let match = expression.firstMatch(
          in: result,
          range: NSRange(location: searchStart, length: source.length - searchStart))
      else { return result }
      let before = source.substring(to: match.range.location)
      let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
      let startsUnit = trimmedBefore.last.map { ",.;:!?…\n".contains($0) } ?? true
      let endsUnit =
        match.range(at: 1).length > 0 || NSMaxRange(match.range) == source.length
      guard startsUnit, endsUnit else {
        searchStart = NSMaxRange(match.range)
        continue
      }
      // Drop the retracted text back to the previous sentence boundary or line break;
      // a command set off by a comma or semicolon retracts only that clause.
      let clauseScoped = trimmedBefore.last.map { ",;".contains($0) } ?? false
      let boundaries = clauseScoped ? ".!?…\n,;" : ".!?…\n"
      var retracted = Substring(trimmedBefore)
      while let last = retracted.last, ",.;:!?…".contains(last) { retracted.removeLast() }
      let boundary = retracted.lastIndex { boundaries.contains($0) }
      let kept = boundary.map { String(retracted[...$0]) } ?? ""
      let after = source.substring(from: NSMaxRange(match.range))
      let separator = kept.isEmpty || kept.hasSuffix("\n") || after.isEmpty ? "" : " "
      let joined = kept + separator + after.trimmingCharacters(in: .whitespaces)
      searchStart = (kept as NSString).length
      result = joined
    }
  }

  private func replaceSpokenCommands(
    _ commands: [(phrase: String, replacement: String)],
    in text: String,
    leadingArtifactPattern: String,
    nounReadings: Set<String> = []
  ) -> String {
    let orderedCommands = commands.sorted { $0.phrase.count > $1.phrase.count }
    let alternatives = orderedCommands.map {
      NSRegularExpression.escapedPattern(for: $0.phrase)
    }.joined(separator: "|")
    let pattern =
      #"(?i)(?:"# + leadingArtifactPattern
      + #"+[ \t]*)?(?<!["# + Self.lexicalCharacterPattern + #"])("# + alternatives
      + #")(?!["# + Self.lexicalCharacterPattern + #"])(?:[ \t]*[,.;:!?…]+)?"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return text
    }

    let replacements = Dictionary(
      uniqueKeysWithValues: orderedCommands.map { ($0.phrase.lowercased(), $0.replacement) }
    )
    let source = text as NSString
    let mutable = NSMutableString(string: text)
    let matches = expression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    )
    for match in matches.reversed() {
      let phrase = source.substring(with: match.range(at: 1)).lowercased()
      guard let replacement = replacements[phrase] else { continue }
      if nounReadings.contains(phrase),
        isNounUse(in: source, before: match.range(at: 1).location, after: match.range(at: 1))
      {
        continue
      }
      let matchEnd = NSMaxRange(match.range)
      let nextCharacter = character(in: source, atUTF16Offset: matchEnd)
      let replacementText: String
      if replacement.last.map({ ",.;:!?".contains($0) }) == true,
        let nextCharacter,
        nextCharacter.isLetter || nextCharacter.isNumber
      {
        replacementText = replacement + " "
      } else {
        replacementText = replacement
      }
      mutable.replaceCharacters(in: match.range, with: replacementText)
    }
    return String(mutable)
  }

  /// "The grace period ended" and "a colon of text" use the word, not the command.
  /// A determiner, possessive, number or common compound before it, or "of" after it,
  /// marks the noun reading.
  private func isNounUse(in source: NSString, before location: Int, after range: NSRange) -> Bool {
    let preceding = source.substring(to: location)
    let trimmed = preceding.reversed().drop { $0 == " " || $0 == "\t" }
    // Only a plain word counts; protected URL and snippet tokens end in private-use marks.
    let previousWord = String(
      trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "'" }.reversed()
    ).lowercased()
    if preceding.last?.isWhitespace == true, !previousWord.isEmpty,
      Self.nounContextWords.contains(previousWord)
        || previousWord.allSatisfy(\.isNumber)
    {
      return true
    }
    let following = source.substring(from: NSMaxRange(range))
    return following.range(of: #"^[ \t]+of\b"#, options: [.regularExpression, .caseInsensitive])
      != nil
  }

  private static let punctuationWordsWithNounReadings: Set<String> = ["period", "colon"]
  private static let nounContextWords: Set<String> = [
    "a", "an", "the", "this", "that", "these", "those", "each", "every", "any", "some",
    "my", "your", "our", "their", "his", "her", "its", "same", "first", "second", "third",
    "last", "next", "previous", "current", "one", "two", "three", "four", "five", "six",
    "grace", "trial", "waiting", "cooling", "probation", "probationary", "notice", "billing",
    "reporting", "holding", "rest", "time", "study", "free", "lock", "blackout", "transition",
    "sigmoid", "semi", "per",
  ]

  private func character(in text: NSString, atUTF16Offset offset: Int) -> Character? {
    guard offset >= 0, offset < text.length else { return nil }
    return text.substring(with: text.rangeOfComposedCharacterSequence(at: offset)).first
  }

  private func cleanSpacing(
    in text: String,
    preserveBoundaryNewlines: Bool = false
  ) -> String {
    let boundaryCharacters: CharacterSet =
      preserveBoundaryNewlines ? .whitespaces : .whitespacesAndNewlines

    return
      text
      .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(
        of: #"[ \t]+([,.;:!?])"#,
        with: "$1",
        options: .regularExpression
      )
      .replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: boundaryCharacters)
  }

  private func capitalizeSentenceStarts(in text: String) -> String {
    let characters = Array(text)
    var result = ""
    result.reserveCapacity(text.utf8.count)
    var atSentenceStart = true
    var pendingSentenceEnd = false

    for (index, character) in characters.enumerated() {
      if character.isNewline {
        result.append(character)
        atSentenceStart = true
        pendingSentenceEnd = false
        continue
      }

      if pendingSentenceEnd {
        if Self.sentenceTerminators.contains(character)
          || Self.closingSentenceDelimiters.contains(character)
        {
          result.append(character)
          continue
        }
        if character.isWhitespace {
          result.append(character)
          atSentenceStart = true
          pendingSentenceEnd = false
          continue
        }
        pendingSentenceEnd = false
      }

      if atSentenceStart {
        if character.isWhitespace || Self.openingSentenceDelimiters.contains(character) {
          result.append(character)
          continue
        }

        if character.isLowercase,
          !shouldPreserveLeadingCase(in: characters, from: index)
        {
          result.append(contentsOf: String(character).uppercased())
        } else {
          result.append(character)
        }
        atSentenceStart = false
      } else {
        result.append(character)
      }

      if Self.sentenceTerminators.contains(character) {
        pendingSentenceEnd = true
      }
    }
    return result
  }

  private func shouldPreserveLeadingCase(
    in characters: [Character],
    from startIndex: Int
  ) -> Bool {
    let token = String(characters[startIndex...].prefix { !$0.isWhitespace })
    let lowercaseToken = token.lowercased()
    if lowercaseToken.hasPrefix("http://")
      || lowercaseToken.hasPrefix("https://")
      || lowercaseToken.hasPrefix("www.")
      || token.contains("@")
    {
      return true
    }

    return characters[(startIndex + 1)...].prefix(while: Self.isWordCharacter).contains {
      $0.isUppercase
    }
  }

  private static let lexicalCharacterPattern = #"\p{L}\p{M}\p{N}\p{Pc}\p{Pd}'’"#
  private static let snippetBoundaryPunctuation: Set<Character> = [
    ",", ".", ";", ":", "!", "?", "…",
  ]
  private static let doubleQuoteMarks: Set<unichar> = [0x22, 0x201C, 0x201D]
  private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
  private static let openingSentenceDelimiters: Set<Character> = [
    "\"", "'", "“", "‘", "(", "[", "{",
  ]
  private static let closingSentenceDelimiters: Set<Character> = [
    "\"", "'", "”", "’", ")", "]", "}",
  ]

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
      || ["'", "’", "-", "‐", "‑", "_"].contains(character)
  }

  private struct PreparedSnippet {
    let order: Int
    let trigger: String
    let expansion: String
  }

  private struct ProtectedSnippet {
    let trigger: String
    let token: String
    let expansion: String
  }

  private struct ProtectedText {
    let token: String
    let value: String
  }
}
