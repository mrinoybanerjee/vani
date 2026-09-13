import SwiftUI
import VaniCore

private enum SettingsSection: String, CaseIterable, Identifiable {
  case general = "General"
  case vocabulary = "Vocabulary"
  case snippets = "Snippets"
  case history = "History"
  case diagnostics = "Diagnostics"

  var id: Self { self }

}

struct SettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var selection = SettingsSection.general
  @State private var vocabulary = VocabularyDraft()
  @State private var snippet = SnippetDraft()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Settings").font(.system(size: 28, weight: .regular, design: .serif))
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
      Picker("Settings section", selection: $selection) {
        ForEach(SettingsSection.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented).labelsHidden()
      .padding(.horizontal, 28).padding(.bottom, 12)
      if let error = coordinator.settingsError {
        HStack(spacing: 8) {
          Label(error, systemImage: "exclamationmark.circle").font(.caption)
            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button {
            coordinator.dismissSettingsError()
          } label: {
            Image(systemName: "xmark.circle")
          }
          .buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }.padding(.horizontal, 28).padding(.vertical, 8)
      }
      Group {
        switch selection {
        case .general: GeneralSettingsView()
        case .vocabulary: VocabularySettingsView(draft: $vocabulary)
        case .snippets: SnippetSettingsView(draft: $snippet)
        case .history: HistorySettingsView()
        case .diagnostics: DiagnosticsSettingsView()
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)

    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(VaniTheme.paper)
      .tint(VaniTheme.accent)
  }

}

private struct VocabularyDraft {
  enum Section: String, CaseIterable, Identifiable {
    case dictionary = "Dictionary"
    case learning = "Learning"
    var id: Self { self }
  }

  var section = Section.dictionary
  var spoken = ""
  var replacement = ""
}

private struct VocabularySettingsView: View {
  @Binding var draft: VocabularyDraft

  var body: some View {
    VStack(spacing: 0) {
      Picker("Vocabulary section", selection: $draft.section) {
        ForEach(VocabularyDraft.Section.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 20)
      .padding(.top, 16)

      switch draft.section {
      case .dictionary:
        DictionarySettingsView(spoken: $draft.spoken, replacement: $draft.replacement)
      case .learning:
        PersonalizationSettingsView()
      }
    }
  }
}

private struct PersonalizationSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @State private var confirmsReset = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(
        "Learn from corrections",
        isOn: Binding(
          get: { coordinator.settings.personalizationEnabled },
          set: { coordinator.setPersonalizationEnabled($0) }
        )
      )

      Text("Saved corrections stay on this Mac. Vani never stores correction audio.")
        .font(.caption)
        .foregroundStyle(.secondary)

      GroupBox("Experimental acoustic vocabulary") {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(
              coordinator.personalizationModelInstalled
                ? "The optional experimental local model is installed."
                : "Optional experimental local model for harder names and terminology."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let progress = coordinator.personalizationModelProgress {
              ProgressView(value: progress)
                .frame(maxWidth: 220)
            }
          }
          Spacer()
          if !coordinator.personalizationModelInstalled {
            Button("Download", systemImage: "arrow.down") {
              coordinator.downloadPersonalizationModel()
            }
            .disabled(coordinator.personalizationModelProgress != nil)
          }
        }
        .padding(4)
      }

      Divider()

      if coordinator.learnedCorrections.isEmpty {
        ContentUnavailableView(
          "Nothing Learned Yet",
          systemImage: "brain.head.profile",
          description: Text("After dictation, choose Teach Vani and save your correction.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(coordinator.learnedCorrections) { correction in
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 8) {
                Text(correction.spoken)
                Image(systemName: "arrow.right")
                  .foregroundStyle(.secondary)
                Text(correction.replacement.isEmpty ? "Remove" : correction.replacement)
                  .fontWeight(.medium)
                Spacer()
                if correction.confirmationCount > 1 {
                  Text("×\(correction.confirmationCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
              if let bundleIdentifier = correction.applicationBundleIdentifier {
                Text(bundleIdentifier)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.tertiary)
              }
            }
          }
          .onDelete { coordinator.removeLearnedCorrections(at: $0) }
        }
      }

      HStack {
        Text(
          "\(coordinator.learnedCorrections.count)/\(PersonalizationEngine.maximumCorrectionCount)"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        Spacer()
        Button("Reset Learning", role: .destructive) {
          confirmsReset = true
        }
        .disabled(coordinator.learnedCorrections.isEmpty)
      }
    }
    .padding(20)
    .confirmationDialog(
      "Delete everything Vani learned?",
      isPresented: $confirmsReset,
      titleVisibility: .visible
    ) {
      Button("Reset Learning", role: .destructive) {
        coordinator.clearLearnedCorrections()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This cannot be undone. Your manual dictionary is not affected.")
    }
  }
}

private struct GeneralSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    Form {
      Section("Dictation") {
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
        Toggle(
          "Smart Formatting",
          isOn: Binding(
            get: { coordinator.settings.smartFormattingEnabled },
            set: { coordinator.setSmartFormattingEnabled($0) }
          ))
        Toggle(
          "Recording sounds",
          isOn: Binding(
            get: { coordinator.settings.soundFeedbackEnabled },
            set: { coordinator.setSoundFeedbackEnabled($0) }
          ))
      }

      Section("On this Mac") {
        Toggle(
          "Launch Vani at login",
          isOn: Binding(
            get: { coordinator.settings.launchAtLogin },
            set: { coordinator.setLaunchAtLogin($0) }
          ))
        Toggle(
          "Save transcript history",
          isOn: Binding(
            get: { coordinator.settings.historyEnabled },
            set: { coordinator.setHistoryEnabled($0) }
          ))
      }

    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding()
  }
}

private struct DictionarySettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Binding var spoken: String
  @Binding var replacement: String

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        TextField("Spoken phrase", text: $spoken)
        TextField("Replacement", text: $replacement)
        Button {
          if coordinator.addDictionaryEntry(spoken: spoken, replacement: replacement) {
            spoken = ""
            replacement = ""
          }
        } label: {
          Image(systemName: "plus")
        }
        .disabled(
          spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .help("Add correction")
        .accessibilityLabel("Add dictionary correction")
      }

      if coordinator.settings.dictionary.isEmpty {
        ContentUnavailableView(
          "Your words, spelled correctly",
          systemImage: "character.book.closed",
          description: Text("Add a name or phrase above, then the spelling you want Vani to use.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
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
    }
    .padding(20)
  }
}

private struct SnippetDraft {
  var trigger = ""
  var expansion = ""
  var editingSnippetID: UUID?
}

private struct SnippetSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @Binding var draft: SnippetDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Voice trigger", text: $draft.trigger)

      ZStack(alignment: .topLeading) {
        if draft.expansion.isEmpty {
          Text("Expanded text")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .allowsHitTesting(false)
        }
        TextEditor(text: $draft.expansion)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(2)
          .accessibilityLabel("Expanded snippet text")
      }
      .frame(height: 72)
      .background(.background)
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(.quaternary, lineWidth: 1)
      }

      HStack {
        Text("\(draft.expansion.count)/\(SnippetEntry.maximumExpansionLength)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        if draft.editingSnippetID != nil {
          Button {
            resetDraft()
          } label: {
            Image(systemName: "xmark")
          }
          .help("Cancel editing")
          .accessibilityLabel("Cancel editing snippet")
        }
        Button(
          draft.editingSnippetID == nil ? "Add" : "Save",
          systemImage: draft.editingSnippetID == nil ? "plus" : "checkmark"
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
              .accessibilityLabel("Edit snippet: \(snippet.trigger)")
            }
            .padding(.vertical, 2)
          }
          .onDelete { offsets in
            if let editingSnippetID = draft.editingSnippetID,
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
    (draft.editingSnippetID != nil
      || coordinator.settings.snippets.count < VaniSettings.maximumSnippetCount)
      && SnippetEntry(trigger: draft.trigger, expansion: draft.expansion).isValid
  }

  private func beginEditing(_ snippet: SnippetEntry) {
    draft.editingSnippetID = snippet.id
    draft.trigger = snippet.trigger
    draft.expansion = snippet.expansion
    coordinator.dismissSettingsError()
  }

  private func commitDraft() {
    let saved: Bool
    if let editingSnippetID = draft.editingSnippetID {
      saved = coordinator.updateSnippet(
        id: editingSnippetID,
        trigger: draft.trigger,
        expansion: draft.expansion
      )
    } else {
      saved = coordinator.addSnippet(trigger: draft.trigger, expansion: draft.expansion)
    }
    if saved {
      resetDraft()
    }
  }

  private func resetDraft() {
    draft.editingSnippetID = nil
    draft.trigger = ""
    draft.expansion = ""
    coordinator.dismissSettingsError()
  }
}

private struct HistorySettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 12) {
      if coordinator.history.isEmpty {
        ContentUnavailableView(
          "No saved transcripts",
          systemImage: "clock",
          description: Text(
            coordinator.settings.historyEnabled
              ? "Your next dictation will appear here."
              : "Turn on transcript history in General to keep a local record."
          )
        )
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
        .disabled(!coordinator.hasStoredHistoryData)
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
