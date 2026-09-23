import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaniCore

struct NotesView: View {
  @ObservedObject var model: NotesModel
  @State private var confirmingDiscard = false
  @FocusState private var titleFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().overlay(VaniTheme.line)
      editor
      status
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tint(VaniTheme.accent)
    .background(VaniTheme.paper)
    .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard) {
      Button("Discard Unsaved Changes", role: .destructive) { model.discardChanges() }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text(
        "Only the unsaved edits will be discarded. Export a copy first if you want to keep them.")
    }
    // Storage messages describe the failure, never the note's text.
    .onChange(of: model.error) { _, error in
      if let error { VoiceOverAnnouncer.announce("Notes: \(error)") }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 16) {
      Text("Notes").font(.system(size: 13, weight: .medium))
        .accessibilityAddTraits(.isHeader)
      Spacer()
      if let note = model.draft {
        Button {
          export(note)
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .help("Export note as text").accessibilityLabel("Export note as text")
        .disabled(model.busy)
        Menu {
          if note.deletedAt == nil {
            Button("Move to Recently Deleted", role: .destructive) { setDeleted(true) }
          } else {
            Button("Restore Note") { setDeleted(false) }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
        .accessibilityLabel("Note actions")
      }
      Button {
        createNote()
      } label: {
        Label("New note", systemImage: "square.and.pencil")
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(!model.loaded || model.busy)
    }
    .buttonStyle(.borderless)
    .font(.system(size: 14)).padding(.horizontal, 24).frame(height: 60)
  }

  @ViewBuilder private var editor: some View {
    if let note = model.draft {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
          Text(note.updatedAt, format: .dateTime.month(.wide).day().year())
          if note.deletedAt != nil { Text("· Recently Deleted") }
        }.font(.caption).foregroundStyle(.secondary)
        TextField(
          "Untitled note",
          text: Binding(
            get: { model.draft?.title ?? "" }, set: { model.draft?.title = $0 })
        )
        .font(.system(size: 28, weight: .medium, design: .serif))
        .textFieldStyle(.plain).focused($titleFocused).accessibilityLabel("Note title")
        .disabled(model.busy || note.deletedAt != nil)
        ZStack(alignment: .topLeading) {
          if note.text.isEmpty {
            Text("Start writing, or hold your dictation key…")
              .font(.system(size: 15)).foregroundStyle(.secondary)
              .padding(.horizontal, 5).padding(.top, 1).allowsHitTesting(false)
              .accessibilityHidden(true)
          }
          TextEditor(
            text: Binding(
              get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 })
          )
          .font(.system(size: 15)).lineSpacing(6)
          .scrollContentBackground(.hidden).accessibilityLabel("Note text")
          .disabled(model.busy || note.deletedAt != nil)
        }
        if note.deletedAt != nil {
          Button("Restore note") { setDeleted(false) }.disabled(model.busy)
        }
      }
      .padding(32).frame(maxWidth: 780, maxHeight: .infinity, alignment: .topLeading)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "text.alignleft")
          .font(.system(size: 28, weight: .light)).foregroundStyle(VaniTheme.accent)
          .accessibilityHidden(true)
        Text(model.notes.isEmpty ? "No notes yet" : "Select or create a note")
          .font(.system(size: 34, weight: .regular, design: .serif))
          .accessibilityAddTraits(.isHeader)
        Button("Create a note", systemImage: "plus") { createNote() }
          .buttonStyle(.borderedProminent).controlSize(.large)
          .disabled(!model.loaded || model.busy)
      }
      .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error = model.error {
        Label {
          Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            .accessibilityHidden(true)
        }
        HStack {
          if model.dirty {
            Button("Discard Changes…") { confirmingDiscard = true }.disabled(model.busy)
          }
          if !model.loaded {
            Button("Retry") { Task { await model.load() } }
            Button("Restore Previous Copy") { Task { await model.restoreBackup() } }
          }
        }
      }
      HStack {
        Label(statusLabel, systemImage: model.dirty ? "circle.dotted" : "checkmark.circle")
          .foregroundStyle(.secondary)
        Spacer()
        if model.draft?.deletedAt == nil, model.draft != nil {
          Button("Save") {
            Task { if await model.save() { VoiceOverAnnouncer.announce("Note saved") } }
          }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!model.dirty || model.busy)
        }
      }
    }
    .font(.caption).controlSize(.small).padding(.horizontal, 24).padding(.vertical, 12)
  }

  private var statusLabel: String {
    if !model.loaded { return model.busy ? "Opening notes…" : "Notes unavailable" }
    if model.busy { return "Saving…" }
    if model.error != nil { return "Storage needs attention" }
    return model.dirty ? "Unsaved changes · ⌘S to save" : "Saved on this Mac"
  }

  /// The selected note leaves the list either way, so VoiceOver hears where it went.
  private func setDeleted(_ deleted: Bool) {
    Task {
      guard model.draft != nil else { return }
      await model.setDeleted(deleted)
      guard model.draft == nil else { return }
      VoiceOverAnnouncer.announce(deleted ? "Note moved to Recently Deleted" : "Note restored")
    }
  }

  private func createNote() {
    Task {
      let previous = model.draft?.id
      await model.create()
      if model.draft?.id != previous { titleFocused = true }
    }
  }

  private func export(_ note: VaniNote) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = NotesModel.exportFileName(for: note)
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try note.exportedText.write(to: url, atomically: true, encoding: .utf8) } catch {
        model.report(error)
      }
    }
  }
}

struct NotesLibraryView: View {
  @ObservedObject var model: NotesModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            .accessibilityHidden(true)
          TextField("Search notes", text: $model.search)
            .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search notes")
          if !model.search.isEmpty {
            Button {
              model.search = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).accessibilityLabel("Clear search")
          }
        }
        .padding(8).background(VaniTheme.paper, in: RoundedRectangle(cornerRadius: 8))
        HStack(spacing: 4) {
          categoryButton("Notes", spoken: "All Notes", deleted: false)
          categoryButton("Recently Deleted", spoken: "Recently Deleted Notes", deleted: true)
        }

      }.padding(.horizontal, 20).padding(.top, 20)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          let selectedID = model.draft?.id
          ForEach(model.visibleNotes) { note in
            NoteRow(note: note, selected: selectedID == note.id) {
              Task { await model.select(note) }
            }
            .disabled(model.busy)
          }
          if model.visibleNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text(model.search.isEmpty ? "No notes yet" : "No matching notes")
                .font(.system(size: 13, weight: .medium))
              Text(
                model.search.isEmpty
                  ? "Your notes will appear here." : "Try another word or clear your search."
              )
              .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
          }
        }.padding(8)
      }.padding(.top, 12)
      HStack {
        Label("On this Mac", systemImage: "internaldrive")
        Spacer()
        Text("\(model.visibleNotes.count)")
          .accessibilityLabel(
            "\(model.visibleNotes.count) \(model.visibleNotes.count == 1 ? "note" : "notes")")
      }.font(.caption).foregroundStyle(.secondary).padding(20)
    }
    .background(VaniTheme.sidebar)
    .background {
      Button("Find Notes") { searchFocused = true }
        .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true)
    }
  }

  /// `spoken` keeps the visible word first while distinguishing this filter from the sidebar's
  /// Notes section for VoiceOver and Voice Control.
  private func categoryButton(_ title: String, spoken: String, deleted: Bool) -> some View {
    Button {
      Task { await model.showDeleted(deleted) }
    } label: {
      Text(title).font(
        .system(size: 12, weight: model.showingDeleted == deleted ? .semibold : .regular)
      )
      .foregroundStyle(model.showingDeleted == deleted ? Color.primary : .secondary)
      .padding(.horizontal, 8).padding(.vertical, 8)
      .selectionHighlight(model.showingDeleted == deleted, cornerRadius: 6)
    }.buttonStyle(.plain).disabled(model.busy)
      .accessibilityLabel(spoken)
      .accessibilityAddTraits(model.showingDeleted == deleted ? .isSelected : [])
  }
}

/// A library row. Selection uses native-style fill, a leading accent bar and a semibold
/// title, so it is not conveyed by colour alone; VoiceOver receives the selected trait.
private struct NoteRow: View {
  let note: VaniNote
  let selected: Bool
  let select: () -> Void

  private var preview: String { note.text.isEmpty ? "Empty note" : String(note.text.prefix(160)) }

  /// The preview without a first line that only repeats the title, which VoiceOver already read.
  private var spokenPreview: String {
    var text = Substring(note.text)
    if text.hasPrefix(note.displayTitle) { text = text.dropFirst(note.displayTitle.count) }
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? "Empty note" : String(body.prefix(80))
  }

  var body: some View {
    Button(action: select) {
      HStack(spacing: 0) {
        Capsule()
          .fill(selected ? VaniTheme.accent : .clear)
          .frame(width: 3)
          .padding(.vertical, 8)
        VStack(alignment: .leading, spacing: 4) {
          Text(note.displayTitle)
            .font(.system(size: 14, weight: selected ? .semibold : .medium)).lineLimit(2)
          Text(preview)
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
          Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.leading, 8).padding(.trailing, 12)
      }
      .selectionHighlight(selected, cornerRadius: 10)
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(selected ? VaniTheme.line : .clear)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The title names the row; the date and the start of the text follow as its value.
    .accessibilityLabel(note.displayTitle)
    .accessibilityValue(
      "\(note.updatedAt.formatted(.dateTime.month(.wide).day())), \(spokenPreview)"
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
