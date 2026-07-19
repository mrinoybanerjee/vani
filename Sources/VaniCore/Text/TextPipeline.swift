import Foundation

public struct TextPipeline: Sendable {
  public init() {}

  public func process(_ rawText: String, dictionary: [DictionaryEntry]) -> String {
    var text =
      rawText
      .replacingOccurrences(of: "\u{00A0}", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    text = text.replacingOccurrences(
      of: #"[\t\n\r ]+"#,
      with: " ",
      options: .regularExpression
    )
    text = text.replacingOccurrences(
      of: #"\s+([,.;:!?])"#,
      with: "$1",
      options: .regularExpression
    )

    for entry in dictionary where entry.isValid {
      let escaped = NSRegularExpression.escapedPattern(
        for: entry.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      text = text.replacingOccurrences(
        of: #"(?i)(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#,
        with: entry.replacement,
        options: .regularExpression
      )
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
