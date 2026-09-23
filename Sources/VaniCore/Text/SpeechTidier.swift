import Foundation

/// Removes disfluencies from one line of Smart Formatting output: fillers, padding
/// "you know" and "like", explicit self-corrections ("Monday, no wait, Tuesday"), restarts
/// and stumbled repetitions. Explicitly spoken lists become numbered or bulleted lines.
///
/// The rules are deterministic and local and only delete words: apart from list markers
/// and casing they add nothing, and never punctuation. They keep interjections
/// ("ah", "hmm"), emphasis (a phrase said three or more times, "tries and tries"), numbers,
/// quoted text and protected link and snippet tokens.
struct SpeechTidier: Sendable {
  func tidy(_ line: String) -> String {
    var words = Self.words(in: line)
    words = removeFillers(from: words)
    words = removeSelfCorrections(from: words)
    words = removeFragmentRestarts(from: words)
    words = removeRepetitions(from: words)
    words = removeFunctionWordRestarts(from: words)
    let text = words.map(\.text).joined(separator: " ")
      .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #",([.?!])"#, with: "$1", options: .regularExpression)
    return formatList(text) ?? finish(text)
  }

  /// Splits on whitespace. A word inside or touching double quotes, or holding a protected
  /// link or snippet token, is never deleted.
  private static func words(in line: String) -> [Word] {
    var insideQuotes = false
    return line.split(whereSeparator: \.isWhitespace).map { piece in
      let quoteMarks = piece.filter { "\"“”".contains($0) }.count
      let isProtected = piece.unicodeScalars.contains { $0 == "\u{E000}" || $0 == "\u{E001}" }
      let word = Word(
        text: String(piece),
        isQuoted: insideQuotes || quoteMarks > 0 || isProtected,
        isProtected: isProtected
      )
      if quoteMarks % 2 == 1 { insideQuotes.toggle() }
      return word
    }
  }

  private func removeFillers(from input: [Word]) -> [Word] {
    var words = input
    var index = 0
    while index < words.count {
      let word = words[index]
      guard !word.isQuoted else {
        index += 1
        continue
      }
      if Self.isFiller(word.norm) {
        words = delete(index..<index + 1, from: words)
        continue
      }
      let afterComma = index == 0 || words[index - 1].text.hasSuffix(",")
      if word.norm == "like", index > 0, afterComma, word.text.hasSuffix(",") {
        words = delete(index..<index + 1, from: words)
        continue
      }
      // Padding "you know," but not "you know what" or "you know the answer".
      if word.norm == "you", index + 1 < words.count, words[index + 1].norm == "know",
        index + 2 >= words.count || words[index + 2].norm != "what",
        afterComma || words[index - 1].trailContains(".?!"),
        words[index + 1].trail.first.map({ ",.?!".contains($0) }) == true
      {
        words = delete(index..<index + 2, from: words)
        continue
      }
      index += 1
    }
    return words
  }

  /// "Monday, no wait, Tuesday": an editing cue after a comma, followed by a repair that
  /// restates the start of the retracted phrase or replaces a word of the same kind.
  private func removeSelfCorrections(from input: [Word]) -> [Word] {
    var words = input
    var index = 1
    while index < words.count {
      guard !words[index].isQuoted, words[index - 1].text.hasSuffix(","),
        let cue = Self.editingCues.first(where: { cue in
          words[index...].prefix(cue.count).map(\.norm) == cue
        })
      else {
        index += 1
        continue
      }
      let repairIndex = index + cue.count
      guard repairIndex < words.count,
        cue.count > 1 || words[repairIndex - 1].text.hasSuffix(",")
      else {
        index += 1
        continue
      }
      let repair = words[repairIndex]
      var clauseStart = index - 1
      while clauseStart > 0, index - clauseStart < 6,
        !words[clauseStart - 1].trailContains(".?!,;:")
      {
        clauseStart -= 1
      }
      var start = (clauseStart..<index).first { candidate in
        words[candidate].norm == repair.norm
          && (!Self.functionEnd.contains(repair.norm) || index - candidate <= 2)
      }
      if start == nil, let repairKind = kind(of: repair, sentenceInitial: false),
        var match = (clauseStart..<index).reversed().first(where: {
          kind(at: $0, in: words) == repairKind
        })
      {
        // "Fifth Avenue, no, Sixth Avenue" retracts the whole same-kind run.
        while match - 1 >= clauseStart, kind(at: match - 1, in: words) == repairKind {
          match -= 1
        }
        if match > 0, words[match - 1].norm == repair.norm { match -= 1 }
        start = match
      }
      guard let start, !words[start..<repairIndex].contains(where: \.isProtected) else {
        index += 1
        continue
      }
      words = delete(start..<repairIndex, from: words)
      index = start + 1
    }
    return words
  }

  /// "We don't have c we don't have cable": up to four words, a short non-word fragment,
  /// then the same words again.
  private func removeFragmentRestarts(from input: [Word]) -> [Word] {
    var words = input
    var index = 0
    while index < words.count {
      guard isFragment(words[index]),
        let length = [4, 3, 2, 1].first(where: { length in
          guard index - length >= 0, index + length < words.count else { return false }
          let before = words[(index - length)..<index]
          return before.map(\.norm) == words[(index + 1)...(index + length)].map(\.norm)
            && !before.contains { $0.trailContains(".?!") || $0.isProtected }
        })
      else {
        index += 1
        continue
      }
      words = delete((index - length)..<(index + 1), from: words)
      index -= length
    }
    return words
  }

  private func isFragment(_ word: Word) -> Bool {
    let scalars = word.norm.unicodeScalars
    return (1...3).contains(scalars.count) && scalars.allSatisfy(Self.isLetter)
      && !Self.shortWords.contains(word.norm) && word.text == word.text.lowercased()
      && !word.isQuoted
  }

  /// Deletes the first copy of a stumbled repetition and starts over until none is left.
  private func removeRepetitions(from input: [Word]) -> [Word] {
    var words = input
    while let repetition = firstStumbledRepetition(in: words) {
      words = delete(repetition, from: words)
    }
    return words
  }

  private func firstStumbledRepetition(in words: [Word]) -> Range<Int>? {
    for length in [4, 3, 2, 1] where words.count >= 2 * length {
      for start in 0...(words.count - 2 * length)
      where isStumbledRepetition(at: start, length: length, in: words) {
        return start..<start + length
      }
    }
    return nil
  }

  private func isStumbledRepetition(at start: Int, length: Int, in words: [Word]) -> Bool {
    let first = words[start..<start + length]
    let second = words[start + length..<start + 2 * length]
    let norms = first.map(\.norm)
    guard !first.contains(where: \.isQuoted), !second.contains(where: \.isQuoted),
      norms == second.map(\.norm)
    else { return false }
    let end = start + 2 * length
    // A phrase said three or more times is emphasis ("day after day after day").
    if length >= 2,
      (end < words.count && words[end].norm == norms[0])
        || (start > 0 && words[start - 1].norm == norms[length - 1])
    {
      return false
    }
    // Repeated numbers are data ("555, 555, 1234", "five, five, nine").
    if norms.allSatisfy(Self.isNumeric) { return false }
    if length == 1 {
      // In "you you know" the second "you" starts the filler "you know".
      if norms[0] == "you", start + 2 < words.count, words[start + 2].norm == "know" {
        return false
      }
      if Self.deliberateDoubles.contains(norms[0]) { return false }
      if !first[start].text.hasSuffix(","), !Self.stumbleProneWords.contains(norms[0]) {
        return false
      }
    }
    // "tries and tries and tries" is emphasis; "and then, and then" is a stumble.
    if length == 2, norms.contains(where: Self.conjunctions.contains) {
      let other = Self.conjunctions.contains(norms[0]) ? norms[1] : norms[0]
      if !Self.functionEnd.contains(other), !["then", "so", "now", "just"].contains(other) {
        return false
      }
    }
    return !first[start + length - 1].trailContains(".?!")
  }

  /// "We need to, we have to" and "can you, could you": a short clause ending in a comma
  /// and a function word, restarted with the same (or a modal) first word.
  private func removeFunctionWordRestarts(from input: [Word]) -> [Word] {
    var words = input
    var index = 0
    while index < words.count {
      let word = words[index]
      guard word.text.hasSuffix(","), Self.functionEnd.contains(word.norm),
        index + 1 < words.count
      else {
        index += 1
        continue
      }
      var start = index
      while start > 0, index - start < 4, !words[start - 1].trailContains(".?!,;:") {
        start -= 1
      }
      let first = words[start].norm
      let next = words[index + 1].norm
      var restarts =
        (Self.modals.contains(first) && Self.modals.contains(next))
        || first.prefix { $0 != "'" } == next.prefix { $0 != "'" }
      if Self.clauseFinal.contains(word.norm), index - start + 1 > 2 { restarts = false }
      guard restarts, !words[start...index].contains(where: \.isQuoted),
        start == 0 || words[start - 1].trailContains(".?!,")
      else {
        index += 1
        continue
      }
      words = delete(start..<index + 1, from: words)
      index = start
    }
    return words
  }

  /// Deletes `range`, moves sentence-final punctuation back to the word before it and
  /// drops the comma a removed filler leaves behind ("It was, like, really" becomes "It was
  /// really").
  private func delete(_ range: Range<Int>, from input: [Word]) -> [Word] {
    let lastTrail = input[range.upperBound - 1].trail
    var words = input
    words.removeSubrange(range)
    let start = range.lowerBound
    if start > 0 {
      let previous = words[start - 1]
      if lastTrail.contains(where: { ".?!".contains($0) }), !previous.trailContains(".?!") {
        var text = previous.text
        while let last = text.last, ",;:".contains(last) { text.removeLast() }
        let mark = lastTrail.trimmingCharacters(in: CharacterSet(charactersIn: ",;: "))
        words[start - 1].text = text + mark.suffix(1)
      } else if lastTrail.contains(","), previous.text.hasSuffix(","), start < words.count {
        let next = words[start]
        // Keep it when a repetition or an editing cue follows ("It's, uh, it's").
        let keepsComma =
          next.norm == previous.norm || Self.commaKeepingWords.contains(next.norm)
        if !keepsComma,
          next.core.unicodeScalars.first?.properties.isLowercase == true
            || Self.functionEnd.contains(previous.norm)
        {
          words[start - 1].text.removeLast()
        }
      }
    }
    if start == 0, !words.isEmpty {
      let text = words[0].text
      let letter = text.unicodeScalars.firstIndex { !"\"“(".unicodeScalars.contains($0) }
      if let letter, Self.isASCIILowercase(text.unicodeScalars[letter]),
        !Self.hasInnerCapital(text.unicodeScalars[letter...].dropFirst())
      {
        words[0].text.replaceSubrange(letter...letter, with: text[letter...letter].uppercased())
      }
    }
    return words
  }

  private func kind(at index: Int, in words: [Word]) -> WordKind? {
    kind(of: words[index], sentenceInitial: index == 0 || words[index - 1].trailContains(".?!"))
  }

  private func kind(of word: Word, sentenceInitial: Bool) -> WordKind? {
    let norm = word.norm
    if Self.isNumeral(norm) || Self.cardinalWords.contains(norm) { return .number }
    if let index = Self.closedClasses.firstIndex(where: { $0.contains(norm) }) {
      return .closedClass(index)
    }
    if word.core.unicodeScalars.first?.properties.isUppercase == true, norm != "i",
      !sentenceInitial
    {
      return .name
    }
    return nil
  }

  /// Explicit cues only: ordinals, "number one", "one, two, three" and "bullet (point)".
  private func formatList(_ text: String) -> String? {
    let source = text as NSString
    let bullets =
      Self.bulletCue?.matches(
        in: text,
        range: NSRange(location: 0, length: source.length)
      ) ?? []
    if bullets.count >= 2 {
      var parts: [String] = []
      var cursor = 0
      for bullet in bullets {
        parts.append(
          source.substring(with: NSRange(location: cursor, length: bullet.range.location - cursor))
        )
        cursor = NSMaxRange(bullet.range)
      }
      parts.append(source.substring(from: cursor))
      return renderList(
        leadIn: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
        items: parts.dropFirst(),
        bulleted: true
      )
    }
    for cues in Self.numberedCues {
      var matches: [NSRange] = []
      for cue in cues {
        let cursor = matches.last.map(NSMaxRange) ?? 0
        guard
          let match = cue.firstMatch(
            in: text,
            options: [.withTransparentBounds, .withoutAnchoringBounds],
            range: NSRange(location: cursor, length: source.length - cursor)
          )
        else { break }
        matches.append(match.range)
      }
      guard matches.count >= 2 else { continue }
      let items = matches.indices.map { index in
        let end = index + 1 < matches.count ? matches[index + 1].location : source.length
        let start = NSMaxRange(matches[index])
        return source.substring(with: NSRange(location: start, length: end - start))
      }
      return renderList(
        leadIn: source.substring(to: matches[0].location)
          .trimmingCharacters(in: .whitespacesAndNewlines),
        items: items,
        bulleted: false
      )
    }
    return nil
  }

  private func renderList(
    leadIn: String,
    items rawItems: some Collection<String>,
    bulleted: Bool
  ) -> String? {
    let items = rawItems.map { item in
      Self.trimmingTrailingWhitespace(
        item.trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(
            of: #"^(?:and\s+)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
          )
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: #"[.,;:]+$"#, with: "", options: .regularExpression)
      )
    }
    guard !items.isEmpty, !items.contains(where: \.isEmpty),
      !items.contains(where: { $0.split(whereSeparator: \.isWhitespace).count > 14 })
    else { return nil }
    var lines: [String] = []
    if !leadIn.isEmpty {
      lines.append(
        leadIn.replacingOccurrences(of: #"[.,;:]+$"#, with: "", options: .regularExpression)
          + ":"
      )
    }
    for (index, item) in items.enumerated() {
      let marker = bulleted ? "- " : "\(index + 1). "
      let scalars = item.unicodeScalars
      let capitalized =
        Self.hasInnerCapital(scalars.dropFirst())
        ? item : String(scalars.prefix(1)).uppercased() + String(scalars.dropFirst())
      lines.append(marker + capitalized)
    }
    return lines.joined(separator: "\n")
  }

  /// Capitalizes a standalone "i" and the first letter of each sentence.
  private func finish(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var result = ""
    for (index, scalar) in scalars.enumerated() {
      let previous = index > 0 ? scalars[index - 1] : nil
      let next = index + 1 < scalars.count ? scalars[index + 1] : nil
      let standaloneI =
        scalar == "i"
        && !(previous.map { Self.isWordScalar($0) || $0 == "'" || $0 == "’" } ?? false)
        && !(next.map(Self.isWordScalar) ?? false)
      let startsSentence =
        Self.isASCIILowercase(scalar) && Self.followsSentenceBoundary(index, in: scalars)
        && !Self.hasInnerCapital(scalars[(index + 1)...])
      if standaloneI || startsSentence {
        result += String(scalar).uppercased()
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private static func followsSentenceBoundary(_ index: Int, in scalars: [Unicode.Scalar]) -> Bool {
    guard index > 0 else { return true }
    var cursor = index - 1
    guard scalars[cursor].properties.isWhitespace else { return false }
    while cursor > 0, scalars[cursor].properties.isWhitespace { cursor -= 1 }
    return ".?!".unicodeScalars.contains(scalars[cursor])
  }

  /// "iPhone" and "eBay" keep their leading lowercase letter at a sentence start.
  private static func hasInnerCapital(_ rest: some Sequence<Unicode.Scalar>) -> Bool {
    rest.prefix { isWordScalar($0) || "'’-‐‑".unicodeScalars.contains($0) }
      .contains { $0.properties.isUppercase }
  }

  private static func trimmingTrailingWhitespace(_ text: String) -> String {
    var result = Substring(text)
    while result.last?.isWhitespace == true { result.removeLast() }
    return String(result)
  }

  private static func isASCIILowercase(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar)
  }

  private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      true
    default:
      false
    }
  }

  private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    isLetter(scalar) || scalar.properties.numericType != nil || scalar == "_"
  }

  /// "42", "$5", "3:30", "1,000" or "50%".
  private static func isNumeral(_ norm: String) -> Bool {
    var scalars = Substring(norm).unicodeScalars
    if scalars.first == "$" { scalars.removeFirst() }
    guard let first = scalars.first, first.properties.generalCategory == .decimalNumber else {
      return false
    }
    return scalars.dropFirst().allSatisfy {
      isWordScalar($0) || ":.,%$-".unicodeScalars.contains($0)
    }
  }

  private static func isNumeric(_ norm: String) -> Bool {
    numericWords.contains(norm)
      || norm.unicodeScalars.contains {
        $0.properties.numericType == .decimal || $0.properties.numericType == .digit
      }
  }

  private struct Word {
    var text: String {
      didSet { norm = Self.norm(of: text) }
    }
    let isQuoted: Bool
    let isProtected: Bool
    private(set) var norm: String

    init(text: String, isQuoted: Bool, isProtected: Bool) {
      self.text = text
      self.isQuoted = isQuoted
      self.isProtected = isProtected
      norm = Self.norm(of: text)
    }

    var core: Substring { Self.core(of: text) }

    private static func core(of text: String) -> Substring {
      var core = text.drop { "\"“”'‘([".contains($0) }
      while let last = core.last, "\"“”’)].,;:!?…".contains(last) { core.removeLast() }
      return core
    }

    private static func norm(of text: String) -> String {
      core(of: text).lowercased().replacingOccurrences(of: "’", with: "'")
    }

    var trail: Substring {
      let start =
        text.lastIndex { !".,;:!?…\"”’)".contains($0) }.map(text.index(after:))
        ?? text.startIndex
      return text[start...]
    }

    func trailContains(_ marks: String) -> Bool {
      trail.contains { marks.contains($0) }
    }
  }

  private enum WordKind: Equatable {
    case number
    case closedClass(Int)
    case name
  }

  // "ah", "hmm" and "mm" are interjections that carry tone ("Ah, I see"), not fillers.
  private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm"]

  /// Also covers drawn-out fillers ("ummm", "uhhh", "ermmm").
  private static func isFiller(_ norm: String) -> Bool {
    fillers.contains(norm)
      || norm.range(of: #"^(?:u+m+|u+h+|u+h+m+|e+r+m+)$"#, options: .regularExpression) != nil
  }

  // Words that can end a complete clause ("we like that,", "I can,"). A restart ending in
  // one is only a stumble when it is at most two words ("can you, could you").
  private static let clauseFinal: Set<String> = [
    "i", "you", "we", "they", "he", "she", "it", "that", "is", "are", "was", "were", "be",
    "do", "does", "did", "have", "has", "can", "could", "will", "would", "should", "about",
    "in", "on",
  ]

  // Function words speakers essentially never double on purpose. A doubled one is a
  // stumble even without a comma; the recognizer rarely writes a comma inside a stumble.
  private static let stumbleProneWords: Set<String> = [
    "i", "i'm", "i've", "i'll", "i'd", "you", "you're", "you've", "he", "he's", "she", "she's",
    "it", "it's", "we", "we're", "we've", "they", "they're", "they've", "there's",
    "the", "a", "an", "my", "our", "your", "their", "both", "to",
    "can", "could", "will", "would", "should", "might", "must",
    "don't", "didn't", "doesn't", "isn't", "wasn't", "can't", "won't", "wouldn't", "couldn't",
  ]

  // Words people double on purpose ("very very", "had had", "bye bye").
  private static let deliberateDoubles: Set<String> = [
    "very", "really", "so", "bye", "ha", "yeah", "yes", "no", "had", "that", "too", "much",
    "many", "far", "long", "knock", "well",
  ]

  // Words that cannot end a finished thought, so a comma after one marks a restart.
  private static let functionEnd: Set<String> = [
    "a", "an", "the", "to", "of", "in", "on", "at", "for", "and", "or", "but",
    "i", "you", "we", "they", "he", "she", "it", "my", "our", "your", "their",
    "is", "are", "was", "were", "be", "do", "does", "did", "have", "has", "can",
    "could", "will", "would", "should", "if", "that", "with", "about",
  ]

  private static let modals: Set<String> = [
    "can", "could", "will", "would", "should", "shall", "may", "might",
  ]

  private static let conjunctions: Set<String> = ["and", "or"]

  // A comma before a repetition or an editing cue still separates it from the stumble.
  private static let commaKeepingWords: Set<String> = [
    "like", "you", "no", "wait", "sorry", "actually", "i", "or",
  ]

  // Longest first, so "no wait" wins over "no". A single-word cue needs a comma after it.
  private static let editingCues: [[String]] = [
    ["no", "wait"], ["sorry", "i", "mean"], ["i", "mean"], ["i", "meant"], ["or", "rather"],
    ["actually", "no"], ["no"], ["wait"], ["sorry"], ["actually"],
  ]

  // A repair replaces a word of the same kind: "Monday, no, Tuesday", "left, sorry, right".
  private static let closedClasses: [Set<String>] = [
    [
      "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today",
      "tomorrow", "yesterday", "tonight",
    ],
    [
      "january", "february", "march", "april", "may", "june", "july", "august", "september",
      "october", "november", "december",
    ],
    ["left", "right", "up", "down", "north", "south", "east", "west"],
    ["what", "when", "where", "who", "whom", "whose", "why", "how", "which"],
  ]

  private static let cardinalWords: Set<String> = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
    "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
  ]

  // Spoken digits and amounts; repeating them is data, not a stumble.
  private static let numericWords: Set<String> = cardinalWords.union([
    "oh", "hundred", "thousand", "million", "billion", "point",
  ])

  // Real one- to three-letter words; anything else that short is a cut-off fragment.
  private static let shortWords = Set(
    """
    a i o am an as at be by do go he if in is it me my no of oh ok on or so to up us
    we ad ah aw ax ay bi eh em ex ha hi ho id lo ma mm mu nu ow pa pi uh um yo ya ye
    ace act add age ago aid aim air all and any ape arc are ark arm art ash ask ate awe axe bad
    bag ban bar bat bay bed bee beg bet bid big bin bit boa bob bog boo bow box boy bra bud bug
    bun bus but buy bye cab cam can cap car cat cod cog con cop cot cow coy cry cub cue cup cut
    dab dad dam day den dew did die dig dim din dip doc doe dog don dot dry dub due dug dye ear
    eat ebb egg ego elf elk elm end era eve eye fad fan far fat fax fed fee few fig fin fir fit
    fix fly foe fog for fox fry fun fur gag gal gap gas gay gel gem get gig gin god got gum gun
    gut guy gym had ham has hat hay hen her hey hid him hip his hit hog hop hot how hub hue hug
    hum hut ice icy ill imp ink inn ion its ivy jab jam jar jaw jay jet jig job jog joy jug keg
    key kid kin kit lab lad lag lap law lay led leg let lid lie lip lit log lot low mad man map
    mat maw may men met mix mob mom mop mud mug mum nag nap net new nil nod nor not now nun nut
    oak oar oat odd off oft oil old one opt orb ore our out owe owl own pad pal pan par pat paw
    pay pea peg pen pep per pet pew pie pig pin pit ply pod pop pot pro pry pub pun pup put rag
    ram ran rap rat raw ray red rib rid rig rim rip rob rod rot row rub rug rum run rut rye sad
    sag sap sat saw say sea see set sew she shy sin sip sir sit six ski sky sly sob sod son sow
    soy spa spy sub sue sum sun tab tag tan tap tar tax tea ten the thy tie tin tip toe ton too
    top tow toy try tub tug two urn use van vat vet via vow wad wag war was wax way web wed wet
    who why wig win wit woe wok won woo wow yak yam yap yes yet you zap zip zoo
    """.split(whereSeparator: \.isWhitespace).map(String.init)
  )

  private static let bulletCue = try? NSRegularExpression(
    pattern: #"(?i)(?:^|(?<=[.,:;!?])\s+|\s+)bullet(?:\s+point)?\b[,:]?\s*"#
  )

  // Each list needs its cues in order: "first ... second", "number one ... number two" or
  // "one, ... two,". A cue starts the text, follows punctuation, or comes before "and".
  private static let numberedCues: [[NSRegularExpression]] = {
    let boundary = #"(?:^|(?<=[.,:;!?])\s+|\s+(?=and\s))"#
    let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth"]
    let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight"]
    return [
      ordinals.map { #"(?:and\s+)?"# + $0 + #"\b,?"# },
      numbers.map { #"(?:and\s+)?number\s+"# + $0 + #"\b,?"# },
      numbers.map { #"(?:and\s+)?"# + $0 + #"\b,"# },
    ].map { patterns in
      patterns.compactMap {
        try? NSRegularExpression(pattern: boundary + $0, options: .caseInsensitive)
      }
    }
  }()
}
