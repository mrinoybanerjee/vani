import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaniCore

@MainActor
final class NotesModel: ObservableObject {
  @Published private(set) var notes: [VaniNote] = []
  @Published var draft: VaniNote?
  @Published var search = ""
  @Published var showingDeleted = false
  @Published private(set) var busy = false
  @Published private(set) var loaded = false
  @Published private(set) var error: String?
  private let store: NoteStore
  private var loadingTask: Task<Void, Never>?

  init(store: NoteStore = NoteStore()) { self.store = store }

  var visibleNotes: [VaniNote] {
    notes.filter {
      ($0.deletedAt != nil) == showingDeleted
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
          || $0.text.localizedCaseInsensitiveContains(search))
    }.sorted { $0.updatedAt > $1.updatedAt }
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

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
  let model: NotesModel
  private(set) var window: NSWindow?
  private var closing = false

  init(model: NotesModel = NotesModel()) { self.model = model }

  func present(load: Bool = true) {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = "Vani Notes"
      window.contentMinSize = NSSize(width: 640, height: 400)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentViewController = NSHostingController(rootView: NotesView(model: model))
      window.center()
      self.window = window
    }
    NSApplication.shared.activate()
    window?.makeKeyAndOrderFront(nil)
    if load { Task { await model.load() } }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !closing else { return false }
    guard model.dirty || model.busy else { return true }
    closing = true
    Task {
      if await model.save() { sender.close() }
      closing = false
    }
    return false
  }
}

private struct NotesView: View {
  @ObservedObject var model: NotesModel
  @State private var confirmingDiscard = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Notes").font(.title2.weight(.semibold))
        Text("On this Mac").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("New Note", systemImage: "square.and.pencil") {
          Task { await model.create() }
        }.disabled(!model.loaded || model.busy)
      }.padding(20)
      Divider()
      HSplitView {
        VStack(spacing: 12) {
          TextField("Search notes", text: $model.search)
            .textFieldStyle(.roundedBorder).accessibilityLabel("Search notes")
          Picker("Show", selection: $model.showingDeleted) {
            Text("Notes").tag(false)
            Text("Recently Deleted").tag(true)
          }.labelsHidden()
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(model.visibleNotes) { note in
                Button {
                  Task { await model.select(note) }
                } label: {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(note.displayTitle).fontWeight(.medium).lineLimit(2)
                    Text(note.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(
                      model.draft?.id == note.id ? Color.accentColor.opacity(0.12) : .clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(model.busy)
              }
              if model.visibleNotes.isEmpty {
                Text(model.search.isEmpty ? "No notes here" : "No matching notes")
                  .foregroundStyle(.secondary).padding(.top, 24)
              }
            }
          }
        }.padding(16).frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
        editor.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack {
        if let error = model.error {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          if model.dirty {
            Button("Discard Changes…") { confirmingDiscard = true }
              .disabled(model.busy)
          }
          if !model.loaded {
            Button("Retry") { Task { await model.load() } }
            Button("Restore Previous Copy") { Task { await model.restoreBackup() } }
          }
        } else {
          Text(model.busy ? "Saving…" : model.dirty ? "Unsaved changes" : "Saved locally")
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }.font(.caption).padding(12)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard) {
      Button("Discard Unsaved Changes", role: .destructive) { model.discardChanges() }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text(
        "Only the unsaved edits will be discarded. Export a copy first if you want to keep them.")
    }
  }

  @ViewBuilder private var editor: some View {
    if let note = model.draft {
      VStack(alignment: .leading, spacing: 16) {
        TextField(
          "Title",
          text: Binding(
            get: { model.draft?.title ?? "" },
            set: { model.draft?.title = $0 })
        )
        .font(.title2.weight(.semibold)).textFieldStyle(.plain)
        .accessibilityLabel("Note title")
        .disabled(model.busy || note.deletedAt != nil)
        TextEditor(
          text: Binding(
            get: { model.draft?.text ?? "" },
            set: { model.draft?.text = $0 })
        )
        .font(.body).scrollContentBackground(.hidden).accessibilityLabel("Note text")
        .disabled(model.busy || note.deletedAt != nil)
        HStack {
          if note.deletedAt == nil {
            Button("Save") { Task { await model.save() } }
              .keyboardShortcut("s", modifiers: .command)
              .disabled(!model.dirty || model.busy)
            Button {
              Task { await model.setDeleted(true) }
            } label: {
              Image(systemName: "trash")
            }
            .help("Move to Recently Deleted")
            .accessibilityLabel("Move to Recently Deleted")
            .disabled(model.busy)
          } else {
            Button("Restore Note") { Task { await model.setDeleted(false) } }
              .disabled(model.busy)
          }
          Spacer()
          Button("Export…") { export(note) }.disabled(model.busy)
        }.controlSize(.small)
      }.padding(24)
    } else {
      VStack(spacing: 12) {
        Image(systemName: "note.text").font(.system(size: 32)).foregroundStyle(.secondary)
        Text("A little space for your thoughts").font(.headline)
        Text("Create a note or save your last dictation from the Vani menu.")
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func export(_ note: VaniNote) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "Vani Note.txt"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try note.exportedText.write(to: url, atomically: true, encoding: .utf8) } catch {
        model.report(error)
      }
    }
  }
}
