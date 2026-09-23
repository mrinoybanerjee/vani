import Foundation
import Testing

@testable import VaniCore

private let tidyingPipeline = TextPipeline()

private func formatted(_ text: String, snippets: [SnippetEntry] = []) -> String {
  tidyingPipeline.process(
    text,
    dictionary: [],
    snippets: snippets,
    smartFormattingEnabled: true
  )
}

@Test
func speechCleanupRemovesFillersAndRepairsTheirCommas() {
  #expect(formatted("It was, like, really good.") == "It was really good.")
  #expect(formatted("So, er, we should go.") == "So we should go.")
  #expect(formatted("It's, you know, fine.") == "It's fine.")
  #expect(formatted("I think we should, uhm, leave now.") == "I think we should leave now.")
}

@Test
func speechCleanupRepairsCommasAndSentencesAroundUmAndUh() {
  #expect(formatted("It was, um, fine.") == "It was fine.")
  #expect(formatted("Well, um, I think so.") == "Well, I think so.")
  #expect(formatted("Um, I think so.") == "I think so.")
  #expect(formatted("It's, uh, it's fine.") == "It's fine.")
  #expect(formatted("Ummm, sure.") == "Sure.")
  #expect(formatted("That's it, um.") == "That's it.")
}

@Test
func speechCleanupKeepsMeaningfulLikeAndYouKnow() {
  #expect(formatted("I like it.") == "I like it.")
  #expect(formatted("You know the answer.") == "You know the answer.")
  #expect(formatted("You know what, let's go.") == "You know what, let's go.")
}

@Test
func speechCleanupAppliesExplicitSelfCorrections() {
  #expect(formatted("Let's meet on Monday, no wait, Tuesday.") == "Let's meet on Tuesday.")
}

@Test
func speechCleanupRemovesStumbledRepetitionsAndRestarts() {
  #expect(formatted("I I think so.") == "I think so.")
  #expect(formatted("It's, it's fine.") == "It's fine.")
  #expect(formatted("We need to, we have to leave.") == "We have to leave.")
  #expect(formatted("Did you see the the dog show?") == "Did you see the dog show?")
  #expect(formatted("We don't have c we don't have cable.") == "We don't have cable.")
}

@Test
func speechCleanupKeepsCompleteClausesEmphasisAndDeliberateDoubles() {
  for sentence in [
    "We like LA Law, we like that, we're",
    "Day after day after day.",
    "He tries and tries and tries.",
    "I don't know, I don't know, I don't know.",
    "Call 555, 555, 1234.",
    "She had had enough.",
    "I gave her her book.",
    "Ah, I see.",
    "Hmm, let me think.",
    "I think the plan is good.",
  ] {
    #expect(formatted(sentence) == sentence)
  }
}

@Test
func speechCleanupNeverAddsPunctuation() {
  #expect(formatted("what time is it") == "What time is it")
  #expect(formatted("then i left") == "Then I left")
}

@Test
func speechCleanupKeepsMixedCaseNamesAtASentenceStart() {
  #expect(formatted("Er, iPhone sales grew.") == "iPhone sales grew.")
}

@Test
func smartFormattingLeavesFillersInsideQuotesVerbatim() {
  #expect(formatted(#"He said "um, no" to me."#) == #"He said "um, no" to me."#)
  #expect(formatted("He said “uh, the the plan” twice.") == "He said “uh, the the plan” twice.")
}

@Test
func speechCleanupLeavesLinksEmailsAndSnippetExpansionsUntouched() {
  #expect(
    formatted("Email hello@example.com, er, or visit https://example.com/the/the today")
      == "Email hello@example.com, or visit https://example.com/the/the today"
  )
  let signature = SnippetEntry(trigger: "team sign off", expansion: "Thanks, thanks, the team")
  #expect(
    formatted("I I sign with team sign off", snippets: [signature])
      == "I sign with Thanks, thanks, the team"
  )
  #expect(
    formatted("Sign with team sign off, no, team sign off", snippets: [signature])
      == "Sign with Thanks, thanks, the team, no, Thanks, thanks, the team"
  )
}

@Test
func speechCleanupRendersExplicitlySpokenLists() {
  #expect(
    formatted("My list: first, milk, second, eggs, third, bread.")
      == "My list:\n1. Milk\n2. Eggs\n3. Bread"
  )
  #expect(
    formatted("Number one, call Sam. Number two, send the deck.")
      == "1. Call Sam\n2. Send the deck"
  )
  #expect(formatted("Bullet point apples bullet point pears") == "- Apples\n- Pears")
  #expect(formatted("We need milk, eggs, and bread.") == "We need milk, eggs, and bread.")
}

@Test
func speechCleanupTidiesEachLineAndKeepsParagraphBreaks() {
  #expect(
    formatted("I I think new line we we agree new paragraph done")
      == "I think\nWe agree\n\nDone"
  )
}

@Test
func speechCleanupRunsOnlyWithSmartFormatting() {
  let input = "I I think, er, so"
  #expect(tidyingPipeline.process(input, dictionary: []) == input)
}
