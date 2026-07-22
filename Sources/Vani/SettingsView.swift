import SwiftUI
import VaniCore

struct SettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 0) {
      if let error = coordinator.settingsError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(error)
            .font(.caption)
          Spacer()
          Button {
            coordinator.dismissSettingsError()
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        Divider()
      }

      TabView {
        GeneralSettingsView()
          .tabItem { Label("General", systemImage: "slider.horizontal.3") }
        DictionarySettingsView()
          .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        SnippetSettingsView()
          .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
        HistorySettingsView()
          .tabItem { Label("History", systemImage: "clock") }
        DiagnosticsSettingsView()
          .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
      }
    }
    .frame(width: 560, height: 450)
  }
}

private struct GeneralSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    Form {
      Section("Shortcut") {
        Picker(
          "Hold key",
          selection: Binding(
            get: { coordinator.settings.shortcut },
            set: { coordinator.setShortcut($0) }
          )
        ) {
          ForEach(HoldShortcut.allCases) { shortcut in
            Text(shortcut.label).tag(shortcut)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Startup") {
        Toggle(
          "Launch Vani at login",
          isOn: Binding(
            get: { coordinator.settings.launchAtLogin },
            set: { coordinator.setLaunchAtLogin($0) }
          ))
      }

      Section("Storage") {
        Toggle(
          "Save transcript history",
          isOn: Binding(
            get: { coordinator.settings.historyEnabled },
            set: { coordinator.setHistoryEnabled($0) }
          ))
      }

      Section("Writing") {
        Toggle(
          "Smart Formatting",
          isOn: Binding(
            get: { coordinator.settings.smartFormattingEnabled },
            set: { coordinator.setSmartFormattingEnabled($0) }
          ))
      }

    }
    .formStyle(.grouped)
    .padding()
  }
}

private struct DictionarySettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var spoken = ""
  @State private var replacement = ""

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        TextField("Spoken phrase", text: $spoken)
        TextField("Replacement", text: $replacement)
        Button {
          coordinator.addDictionaryEntry(spoken: spoken, replacement: replacement)
          spoken = ""
          replacement = ""
        } label: {
          Image(systemName: "plus")
        }
        .disabled(
          spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .help("Add correction")
      }

      List {
        ForEach(coordinator.settings.dictionary) { entry in
          HStack {
            Text(entry.spoken)
            Spacer()
            Image(systemName: "arrow.right")
              .foregroundStyle(.secondary)
            Text(entry.replacement)
          }
        }
        .onDelete { coordinator.removeDictionaryEntries(at: $0) }
      }
    }
    .padding(20)
  }
}

private struct SnippetSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var trigger = ""
  @State private var expansion = ""
  @State private var editingSnippetID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Voice trigger", text: $trigger)

      ZStack(alignment: .topLeading) {
        if expansion.isEmpty {
          Text("Expanded text")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .allowsHitTesting(false)
        }
        TextEditor(text: $expansion)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(2)
      }
      .frame(height: 72)
      .background(.background)
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(.quaternary, lineWidth: 1)
      }

      HStack {
        Text("\(expansion.count)/\(SnippetEntry.maximumExpansionLength)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        if editingSnippetID != nil {
          Button {
            resetDraft()
          } label: {
            Image(systemName: "xmark")
          }
          .help("Cancel editing")
        }
        Button(
          editingSnippetID == nil ? "Add" : "Save",
          systemImage: editingSnippetID == nil ? "plus" : "checkmark"
        ) {
          commitDraft()
        }
        .disabled(!draftIsValid)
      }

      Divider()

      if coordinator.settings.snippets.isEmpty {
        ContentUnavailableView("No Snippets", systemImage: "text.badge.plus")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(coordinator.settings.snippets) { snippet in
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(snippet.trigger)
                  .font(.system(size: 13, weight: .medium))
                Text(snippet.expansion)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                  .textSelection(.enabled)
              }
              Spacer()
              Button {
                beginEditing(snippet)
              } label: {
                Image(systemName: "pencil")
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.borderless)
              .help("Edit snippet")
            }
            .padding(.vertical, 2)
          }
          .onDelete { offsets in
            if let editingSnippetID,
              offsets.contains(where: {
                coordinator.settings.snippets[$0].id == editingSnippetID
              })
            {
              resetDraft()
            }
            coordinator.removeSnippets(at: offsets)
          }
        }
      }
    }
    .padding(20)
  }

  private var draftIsValid: Bool {
    (editingSnippetID != nil
      || coordinator.settings.snippets.count < VaniSettings.maximumSnippetCount)
      && SnippetEntry(trigger: trigger, expansion: expansion).isValid
  }

  private func beginEditing(_ snippet: SnippetEntry) {
    editingSnippetID = snippet.id
    trigger = snippet.trigger
    expansion = snippet.expansion
    coordinator.dismissSettingsError()
  }

  private func commitDraft() {
    let saved: Bool
    if let editingSnippetID {
      saved = coordinator.updateSnippet(
        id: editingSnippetID,
        trigger: trigger,
        expansion: expansion
      )
    } else {
      saved = coordinator.addSnippet(trigger: trigger, expansion: expansion)
    }
    if saved {
      resetDraft()
    }
  }

  private func resetDraft() {
    editingSnippetID = nil
    trigger = ""
    expansion = ""
    coordinator.dismissSettingsError()
  }
}

private struct HistorySettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 12) {
      if coordinator.history.isEmpty {
        ContentUnavailableView("No History", systemImage: "clock")
      } else {
        List(coordinator.history) { entry in
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
              .lineLimit(2)
              .textSelection(.enabled)
            Text(entry.createdAt, style: .date)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      HStack {
        Spacer()
        Button("Clear", role: .destructive) {
          coordinator.clearHistory()
        }
        .disabled(coordinator.history.isEmpty)
      }
    }
    .padding(20)
  }
}

private struct DiagnosticsSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 12) {
      List(coordinator.diagnostics) { event in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(event.code)
              .font(.system(size: 12, weight: .medium, design: .monospaced))
            Text(event.category.rawValue)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if let duration = event.durationMilliseconds {
            Text("\(duration) ms")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
      HStack {
        Button("Refresh", systemImage: "arrow.clockwise") {
          coordinator.refreshDiagnostics()
        }
        Spacer()
        Button("Clear", role: .destructive) {
          coordinator.clearDiagnostics()
        }
      }
    }
    .padding(20)
    .task { coordinator.refreshDiagnostics() }
  }
}
