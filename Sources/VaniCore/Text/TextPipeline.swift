import Foundation

public struct TextPipeline: Sendable {
  public init() {}

  public func process(
    _ rawText: String,
    dictionary: [DictionaryEntry],
    snippets: [SnippetEntry] = [],
    smartFormattingEnabled: Bool = false
  ) -> String {
    var text = cleanSpacing(in: normalizeInlineWhitespace(rawText))
    text = applyDictionary(dictionary, to: text)

    let protected = protectSnippets(snippets, in: text)
    text = protected.text

    if smartFormattingEnabled {
      text = applySmartFormatting(to: text)
    }

    for replacement in protected.replacements {
      text = restoreSnippet(replacement, in: text)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        for: entry.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private func applySmartFormatting(to text: String) -> String {
    let protected = protectTechnicalTokens(in: text)
    var result = removeFillers(in: protected.text)

    let structuralCommands: [(phrase: String, replacement: String)] = [
      ("new paragraph", "\n\n"),
      ("new line", "\n"),
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
      leadingArtifactPattern: #"[,.;:!?…]"#
    )

    result = capitalizeSentenceStarts(in: cleanSpacing(in: result))
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
    let matches = expression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    )
    for match in matches.reversed() {
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

  private func replaceSpokenCommands(
    _ commands: [(phrase: String, replacement: String)],
    in text: String,
    leadingArtifactPattern: String
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

  private func character(in text: NSString, atUTF16Offset offset: Int) -> Character? {
    guard offset >= 0, offset < text.length else { return nil }
    return text.substring(with: text.rangeOfComposedCharacterSequence(at: offset)).first
  }

  private func cleanSpacing(in text: String) -> String {
    text
      .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(
        of: #"[ \t]+([,.;:!?])"#,
        with: "$1",
        options: .regularExpression
      )
      .replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
