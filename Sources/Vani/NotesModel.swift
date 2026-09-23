import Foundation
import VaniCore

@MainActor
final class NotesModel: ObservableObject {
  @Published private(set) var notes: [VaniNote] = [] {
    didSet { refreshVisibleNotes() }
  }
  @Published var draft: VaniNote?
  @Published var search = "" {
    didSet { if search != oldValue { refreshVisibleNotes() } }
  }
  @Published var showingDeleted = false {
    didSet { if showingDeleted != oldValue { refreshVisibleNotes() } }
  }
  /// The filtered, newest-first library. Cached so editing the draft does not re-sort every
  /// render; recomputed only when notes, search or the category change.
  private(set) var visibleNotes: [VaniNote] = []
  @Published private(set) var busy = false
  @Published private(set) var loaded = false
  @Published private(set) var error: String?
  private let store: NoteStore
  private var loadingTask: Task<Void, Never>?

  init(store: NoteStore = NoteStore()) { self.store = store }

  private func refreshVisibleNotes() {
    visibleNotes = notes.filter {
      ($0.deletedAt != nil) == showingDeleted
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
          || $0.text.localizedCaseInsensitiveContains(search))
    }.sorted { $0.updatedAt > $1.updatedAt }
  }

  /// A safe plain-text file name derived from the note title.
  static func exportFileName(for note: VaniNote) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
      .union(.newlines)
    let cleaned = note.title.unicodeScalars
      .map { forbidden.contains($0) ? " " : String($0) }
      .joined()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    let base = cleaned.isEmpty ? "Vani Note" : String(cleaned.prefix(80))
    return "\(base).txt"
  }

  var dirty: Bool {
    guard let draft else { return false }
    return notes.first(where: { $0.id == draft.id }) != draft
  }

  func load() async {
    guard !loaded else { return }
    if let loadingTask {
      await loadingTask.value
      return
    }
    guard !busy else { return }
    busy = true
    let task = Task {
      defer {
        busy = false
        loadingTask = nil
      }
      do {
        notes = try await store.load()
        loaded = true
        error = nil
      } catch { self.error = error.localizedDescription }
    }
    loadingTask = task
    await task.value
  }

  @discardableResult
  func save() async -> Bool {
    guard !busy else { return false }
    guard dirty, var saved = draft else { return true }
    guard loaded else { return false }
    busy = true
    defer { busy = false }
    saved.updatedAt = Date()
    do {
      notes = try await store.save(saved)
      draft = saved
      error = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func select(_ note: VaniNote?) async {
    guard await save() else { return }
    draft = note.flatMap { selection in notes.first { $0.id == selection.id } }
  }

  func showDeleted(_ deleted: Bool) async {
    guard await save() else { return }
    showingDeleted = deleted
    if let draft, (draft.deletedAt != nil) != deleted { self.draft = nil }
  }

  func create(text: String = "") async {
    if !loaded { await load() }
    guard loaded else { return }
    guard !busy else {
      error = "Notes is saving. Try Save as Note again in a moment."
      return
    }
    guard await save() else { return }
    showingDeleted = false
    search = ""
    draft = VaniNote(title: String(text.split(separator: "\n").first?.prefix(80) ?? ""), text: text)
    // Persist a new note immediately, so an empty draft also survives reopening.
    await save()
  }

  func setDeleted(_ deleted: Bool) async {
    guard !busy, draft != nil else { return }
    let previous = draft
    draft?.deletedAt = deleted ? Date() : nil
    if await save() { draft = nil } else { draft = previous }
  }

  func restoreBackup() async {
    guard !busy, !loaded else { return }
    busy = true
    defer { busy = false }
    do {
      notes = try await store.restoreBackup()
      loaded = true
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func report(_ failure: Error) { error = failure.localizedDescription }

  func discardChanges() {
    guard !busy else { return }
    draft = notes.first { $0.id == draft?.id }
  }
}
