import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaniCore

struct NotesView: View {
  @ObservedObject var model: NotesModel
  @State private var confirmingDiscard = false
  @State private var sidebarVisible = true
  @FocusState private var searchFocused: Bool
  @FocusState private var titleFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HSplitView {
        if sidebarVisible { sidebar }
        VStack(spacing: 0) {
          toolbar
          Divider().overlay(VaniTheme.line)
          editor
          status
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        .background(VaniTheme.paper)
      }
    }
    .tint(VaniTheme.accent)
    .background(VaniTheme.paper)
    .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard) {
      Button("Discard Unsaved Changes", role: .destructive) { model.discardChanges() }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text(
        "Only the unsaved edits will be discarded. Export a copy first if you want to keep them.")
    }
    .background {
      Button("Find Notes") {
        sidebarVisible = true
        searchFocused = true
      }
      .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VaniWordmark()
        Spacer()
        Image(systemName: "lock").foregroundStyle(.secondary)
          .help("Your notes are stored on this Mac")
      }.padding(24)
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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
        .padding(10).background(VaniTheme.paper, in: RoundedRectangle(cornerRadius: 8))
        HStack(spacing: 4) {
          categoryButton("Notes", deleted: false)
          categoryButton("Recently Deleted", deleted: true)
        }

      }.padding(.horizontal, 20)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(model.visibleNotes) { note in
            Button {
              Task { await model.select(note) }
            } label: {
              VStack(alignment: .leading, spacing: 7) {
                Text(note.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(note.text.isEmpty ? "Empty note" : String(note.text.prefix(160)))
                  .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
                  .font(.system(size: 11)).foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading).padding(14)
              .background(
                model.draft?.id == note.id ? VaniTheme.paper : .clear,
                in: RoundedRectangle(cornerRadius: 10)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(model.draft?.id == note.id ? VaniTheme.line : .clear)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.busy)
            .accessibilityAddTraits(model.draft?.id == note.id ? .isSelected : [])
          }
          if model.visibleNotes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text(model.search.isEmpty ? "A fresh page awaits" : "No matching notes")
                .font(.system(size: 13, weight: .medium))
              Text(
                model.search.isEmpty
                  ? "Your notes will appear here." : "Try another word or clear your search."
              )
              .font(.caption).foregroundStyle(.secondary)
            }.padding(14)
          }
        }.padding(10)
      }.padding(.top, 12)
      HStack {
        Label("On this Mac", systemImage: "internaldrive")
        Spacer()
        Text("\(model.visibleNotes.count)")
      }.font(.caption).foregroundStyle(.secondary).padding(20)
    }
    .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
    .background(VaniTheme.sidebar)
  }

  private func categoryButton(_ title: String, deleted: Bool) -> some View {
    Button {
      Task { await model.showDeleted(deleted) }
    } label: {
      Text(title).font(
        .system(size: 12, weight: model.showingDeleted == deleted ? .semibold : .regular)
      )
      .foregroundStyle(model.showingDeleted == deleted ? Color.primary : .secondary)
      .padding(.horizontal, 9).padding(.vertical, 8)
      .background(
        model.showingDeleted == deleted ? VaniTheme.paper : .clear,
        in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).disabled(model.busy)
      .accessibilityAddTraits(model.showingDeleted == deleted ? .isSelected : [])
  }

  private var toolbar: some View {
    HStack(spacing: 14) {
      Button {
        sidebarVisible.toggle()
      } label: {
        Image(systemName: "sidebar.left")
      }
      .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
      .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
      Text("Notes").font(.system(size: 13, weight: .medium))
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
            Button("Move to Recently Deleted", role: .destructive) {
              Task { await model.setDeleted(true) }
            }
          } else {
            Button("Restore Note") { Task { await model.setDeleted(false) } }
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
      VStack(alignment: .leading, spacing: 18) {
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
            Text("Start writing, or use your dictation shortcut…")
              .font(.system(size: 15)).foregroundStyle(.secondary)
              .padding(.horizontal, 5).padding(.top, 1).allowsHitTesting(false)
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
          Button("Restore note") { Task { await model.setDeleted(false) } }.disabled(model.busy)
        }
      }
      .padding(32).frame(maxWidth: 780, maxHeight: .infinity, alignment: .topLeading)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "text.alignleft")
          .font(.system(size: 28, weight: .light)).foregroundStyle(VaniTheme.accent)
        Text("Room to think.")
          .font(.system(size: 34, weight: .regular, design: .serif))
        Text("A thought, a draft, a little clarity.\nWrite it down or let your voice do the work.")
          .font(.system(size: 15)).lineSpacing(6).foregroundStyle(.secondary)
        Button("Create a note", systemImage: "plus") { createNote() }
          .buttonStyle(.borderedProminent).controlSize(.large)
          .disabled(!model.loaded || model.busy)
        Text("Private. Local. Yours.").font(.caption).foregroundStyle(.secondary)
      }
      .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.circle")
          .foregroundStyle(.red).textSelection(.enabled).fixedSize(
            horizontal: false, vertical: true)
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
          Button("Save") { Task { await model.save() } }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.dirty || model.busy)
        }
      }
    }
    .font(.caption).controlSize(.small).padding(.horizontal, 24).padding(.vertical, 14)
  }

  private var statusLabel: String {
    if !model.loaded { return model.busy ? "Opening notes…" : "Notes unavailable" }
    if model.busy { return "Saving…" }
    if model.error != nil { return "Storage needs attention" }
    return model.dirty ? "Unsaved changes · ⌘S to save" : "Saved on this Mac"
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
    panel.nameFieldStringValue = "Vani Note.txt"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try note.exportedText.write(to: url, atomically: true, encoding: .utf8) } catch {
        model.report(error)
      }
    }
  }
}
