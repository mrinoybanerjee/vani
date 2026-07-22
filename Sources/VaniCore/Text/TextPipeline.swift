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
      text = text.replacingOccurrences(of: replacement.token, with: replacement.expansion)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var result = text.replacingOccurrences(
      of: #"(?i)(?<![\p{L}\p{N}])(?:um+|uh+|erm+)(?![\p{L}\p{N}])(?:[ \t]*,)?"#,
      with: "",
      options: .regularExpression
    )

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
      leadingArtifactPattern: #"[,.;:!?]"#
    )

    return capitalizeSentenceStarts(in: cleanSpacing(in: result))
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
      + #"+[ \t]*)?(?<![\p{L}\p{N}])("# + alternatives
      + #")(?![\p{L}\p{N}])(?:[ \t]*[,.;:!?]+)?"#
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
      mutable.replaceCharacters(in: match.range, with: replacement)
    }
    return String(mutable)
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
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?m)(^|[.!?][ \t]+|\n+)([a-z])"#
      )
    else { return text }

    let source = text as NSString
    let mutable = NSMutableString(string: text)
    let matches = expression.matches(
      in: text,
      range: NSRange(location: 0, length: source.length)
    )
    for match in matches.reversed() {
      let range = match.range(at: 2)
      mutable.replaceCharacters(in: range, with: source.substring(with: range).uppercased())
    }
    return String(mutable)
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
}
