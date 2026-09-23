import SwiftUI
import VaniCore

enum SettingsSection: String, CaseIterable, Identifiable {
  case general = "General"
  case vocabulary = "Vocabulary"
  case snippets = "Snippets"
  case history = "History"
  case diagnostics = "Diagnostics"

  var id: Self { self }

}

struct SettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  /// False while the workspace shows another section. Drafts and the section picker stay alive
  /// here, but the selected pane and its lists are not built, so hidden Settings does little
  /// work when the coordinator publishes dictation state.
  var active = true
  @State private var selection: SettingsSection
  @State private var vocabulary = VocabularyDraft()
  @State private var snippet = SnippetDraft()

  init(active: Bool = true, section: SettingsSection = .general) {
    self.active = active
    _selection = State(initialValue: section)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Settings").font(.system(size: 28, weight: .regular, design: .serif))
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
      Picker("Settings section", selection: $selection) {
        ForEach(SettingsSection.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented).labelsHidden()
      .padding(.horizontal, 24).padding(.bottom, 12)
      if let error = coordinator.settingsError {
        HStack(spacing: 8) {
          Label {
            Text(error).fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
              .accessibilityHidden(true)
          }
          .font(.system(size: 12))
          Spacer()
          Button("Dismiss") {
            coordinator.dismissSettingsError()
          }
          .buttonStyle(.borderless).controlSize(.small).accessibilityLabel("Dismiss error")
        }.padding(.horizontal, 24).padding(.vertical, 8)
      }
      Group {
        if active {
          switch selection {
          case .general: GeneralSettingsView()
          case .vocabulary: VocabularySettingsView(draft: $vocabulary)
          case .snippets: SnippetSettingsView(draft: $snippet)
          case .history: HistorySettingsView()
          case .diagnostics: DiagnosticsSettingsView()
          }
        } else {
          Color.clear
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)

    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(VaniTheme.paper)
      .tint(VaniTheme.accent)
      .onChange(of: coordinator.settingsError) { _, error in
        // The menu shows the same banner; only visible Settings speaks it.
        if active, let error { VoiceOverAnnouncer.announce("Settings: \(error)") }
      }
  }

}

/// Visible, keyboard-reachable delete control for list rows. Swipe-to-delete alone is not
/// discoverable on the Mac and is unavailable to many keyboard and VoiceOver users.
private struct DeleteRowButton: View {
  let label: String
  let action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      Image(systemName: "trash")
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.borderless)
    .help("Delete")
    .accessibilityLabel(label)
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

  var body: some View {
    LearningSettingsContent(
      corrections: coordinator.learnedCorrections,
      enabled: Binding(
        get: { coordinator.settings.personalizationEnabled },
        set: { coordinator.setPersonalizationEnabled($0) }
      ),
      modelInstalled: coordinator.personalizationModelInstalled,
      modelProgress: coordinator.personalizationModelProgress,
      download: coordinator.downloadPersonalizationModel,
      remove: remove,
      removeOffsets: coordinator.removeLearnedCorrections(at:),
      reset: coordinator.clearLearnedCorrections)
  }

  private func remove(_ id: UUID) {
    guard let index = coordinator.learnedCorrections.firstIndex(where: { $0.id == id }) else {
      return
    }
    coordinator.removeLearnedCorrections(at: IndexSet(integer: index))
  }
}

/// The Learning pane, driven by values so every state can be rendered and audited.
struct LearningSettingsContent: View {
  let corrections: [LearnedCorrection]
  @Binding var enabled: Bool
  let modelInstalled: Bool
  let modelProgress: Double?
  let download: () -> Void
  let remove: (UUID) -> Void
  let removeOffsets: (IndexSet) -> Void
  let reset: () -> Void
  @State private var confirmsReset = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Learn from corrections", isOn: $enabled)

      Text("Corrections stay on this Mac. Vani never stores correction audio.")
        .font(.caption)
        .foregroundStyle(.secondary)

      GroupBox("Experimental acoustic vocabulary") {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              modelInstalled
                ? "Installed on this Mac."
                : "Optional local model for hard names and terms."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let progress = modelProgress {
              ProgressView(value: progress)
                .frame(maxWidth: 220)
                .accessibilityLabel("Downloading acoustic vocabulary model")
                .accessibilityValue("\(Int(progress * 100)) percent")
            }
          }
          Spacer()
          if !modelInstalled {
            Button("Download", systemImage: "arrow.down", action: download)
              .disabled(modelProgress != nil)
              .accessibilityLabel("Download acoustic vocabulary model")
          }
        }
        .padding(4)
      }
      .announcesProgressMilestones(modelProgress, subject: "Acoustic vocabulary download")

      Divider()

      if corrections.isEmpty {
        ContentUnavailableView(
          "Nothing Learned Yet",
          systemImage: "brain.head.profile",
          description: Text("After dictation, choose Teach and save your correction.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(corrections) { correction in
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                  Text(correction.spoken)
                  Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("becomes")
                  Text(correction.replacement.isEmpty ? "Remove" : correction.replacement)
                    .fontWeight(.medium)
                  Spacer()
                  if correction.confirmationCount > 1 {
                    Text("×\(correction.confirmationCount)")
                      .font(.caption.monospacedDigit())
                      .foregroundStyle(.secondary)
                      .accessibilityLabel("confirmed \(correction.confirmationCount) times")
                  }
                }
                if let bundleIdentifier = correction.applicationBundleIdentifier {
                  Text(bundleIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
              }
              .accessibilityElement(children: .combine)
              DeleteRowButton(label: "Delete learned correction \(correction.spoken)") {
                remove(correction.id)
              }
            }
            .contextMenu {
              Button("Delete Correction", role: .destructive) { remove(correction.id) }
            }
          }
          .onDelete(perform: removeOffsets)
        }
      }

      HStack {
        Text(
          "\(corrections.count)/\(PersonalizationEngine.maximumCorrectionCount)"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          "\(corrections.count) of \(PersonalizationEngine.maximumCorrectionCount) corrections"
        )
        Spacer()
        Button("Reset Learning…", role: .destructive) {
          confirmsReset = true
        }
        .disabled(corrections.isEmpty)
      }
    }
    .padding(20)
    .confirmationDialog(
      "Delete everything Vani learned?",
      isPresented: $confirmsReset,
      titleVisibility: .visible
    ) {
      Button("Reset Learning", role: .destructive) {
        reset()
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
            Text(shortcut.displayName).tag(shortcut)
          }
        }
        .pickerStyle(.segmented)
        Toggle(
          isOn: Binding(
            get: { coordinator.settings.handsFreeEnabled },
            set: { coordinator.setHandsFreeEnabled($0) }
          )
        ) {
          Text("Double-tap for hands-free")
          Text("Double-tap the hold key to keep recording; press it again to insert.")
        }
        Toggle(
          isOn: Binding(
            get: { coordinator.settings.escapeCancelsEnabled },
            set: { coordinator.setEscapeCancelsEnabled($0) }
          )
        ) {
          Text("Escape cancels recording")
          Text("Discards the recording without inserting text.")
        }
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
        Picker(
          "Last transcript shortcut",
          selection: Binding(
            get: { coordinator.settings.lastTranscriptBinding },
            set: { coordinator.setLastTranscriptBinding($0) }
          )
        ) {
          ForEach(LastTranscriptBinding.allCases) { binding in
            Text(binding.symbols.map { "\($0)V paste · \($0)C copy" } ?? "Off").tag(binding)
          }
        }
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
        // Return in either field adds the entry, as the Add button does.
        TextField("Spoken phrase", text: $spoken).onSubmit(add)
          .accessibilityLabel("Spoken phrase")
        TextField("Replacement", text: $replacement).onSubmit(add)
          .accessibilityLabel("Replacement")
        Button(action: add) {
          Image(systemName: "plus")
        }
        .disabled(!canAdd)
        .help("Add correction")
        .accessibilityLabel("Add dictionary correction")
      }

      if coordinator.settings.dictionary.isEmpty {
        ContentUnavailableView(
          "Your words, spelled correctly",
          systemImage: "character.book.closed",
          description: Text("Add a name or phrase, then the spelling Vani should use.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(coordinator.settings.dictionary) { entry in
            HStack(spacing: 8) {
              HStack(spacing: 8) {
                Text(entry.spoken)
                Spacer()
                Image(systemName: "arrow.right")
                  .foregroundStyle(.secondary)
                  .accessibilityLabel("becomes")
                Text(entry.replacement)
              }
              .accessibilityElement(children: .combine)
              DeleteRowButton(label: "Delete dictionary entry \(entry.spoken)") {
                remove(entry.id)
              }
            }
            .contextMenu {
              Button("Delete Correction", role: .destructive) { remove(entry.id) }
            }
          }
          .onDelete { coordinator.removeDictionaryEntries(at: $0) }
        }
      }
    }
    .padding(20)
  }

  private var canAdd: Bool {
    !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func add() {
    guard canAdd else { return }
    if coordinator.addDictionaryEntry(spoken: spoken, replacement: replacement) {
      spoken = ""
      replacement = ""
    }
  }

  private func remove(_ id: UUID) {
    guard let index = coordinator.settings.dictionary.firstIndex(where: { $0.id == id }) else {
      return
    }
    coordinator.removeDictionaryEntries(at: IndexSet(integer: index))
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
        .accessibilityLabel("Voice trigger")

      ZStack(alignment: .topLeading) {
        if draft.expansion.isEmpty {
          Text("Expanded text")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        TextEditor(text: $draft.expansion)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(2)
          .accessibilityLabel("Expanded snippet text")
      }
      .frame(height: 72)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(.quaternary, lineWidth: 1)
      }

      HStack {
        Text("\(draft.expansion.count)/\(SnippetEntry.maximumExpansionLength)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel(
            "\(draft.expansion.count) of \(SnippetEntry.maximumExpansionLength) characters")
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
        .accessibilityLabel(draft.editingSnippetID == nil ? "Add snippet" : "Save snippet")
      }

      Divider()

      if coordinator.settings.snippets.isEmpty {
        ContentUnavailableView(
          "No Snippets", systemImage: "text.badge.plus",
          description: Text("Say a trigger phrase to insert its expanded text.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(coordinator.settings.snippets) { snippet in
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 4) {
                Text(snippet.trigger)
                  .font(.system(size: 13, weight: .medium))
                Text(snippet.expansion)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                  .textSelection(.enabled)
              }
              .accessibilityElement(children: .combine)
              .accessibilityAddTraits(.isStaticText)
              Spacer()
              Button {
                beginEditing(snippet)
              } label: {
                Image(systemName: "pencil")
                  .frame(width: 24, height: 24)
              }
              .buttonStyle(.borderless)
              .help("Edit snippet")
              .accessibilityLabel("Edit snippet \(snippet.trigger)")
              DeleteRowButton(label: "Delete snippet \(snippet.trigger)") {
                remove([snippet.id])
              }
            }
            .padding(.vertical, 4)
            .contextMenu {
              Button("Edit Snippet") { beginEditing(snippet) }
              Button("Delete Snippet", role: .destructive) { remove([snippet.id]) }
            }
          }
          .onDelete { offsets in
            remove(offsets.map { coordinator.settings.snippets[$0].id })
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

  private func remove(_ ids: [UUID]) {
    let offsets = IndexSet(
      coordinator.settings.snippets.indices.filter {
        ids.contains(coordinator.settings.snippets[$0].id)
      })
    guard !offsets.isEmpty else { return }
    if let editingSnippetID = draft.editingSnippetID, ids.contains(editingSnippetID) {
      resetDraft()
    }
    coordinator.removeSnippets(at: offsets)
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
    HistorySettingsContent(
      entries: coordinator.history, historyEnabled: coordinator.settings.historyEnabled,
      canClear: coordinator.hasStoredHistoryData, clear: coordinator.clearHistory)
  }
}

/// The History pane, driven by values so every state can be rendered and audited.
struct HistorySettingsContent: View {
  let entries: [TranscriptHistoryEntry]
  let historyEnabled: Bool
  let canClear: Bool
  let clear: () -> Void
  @State private var confirmsClear = false

  var body: some View {
    VStack(spacing: 12) {
      if entries.isEmpty {
        ContentUnavailableView(
          "No Saved Transcripts",
          systemImage: "clock",
          description: Text(
            historyEnabled
              ? "Your next dictation will appear here."
              : "Turn on transcript history in General to keep a local record."
          )
        )
      } else {
        List(entries) { entry in
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
              .lineLimit(2)
              .textSelection(.enabled)
            Text(entry.createdAt, style: .date)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isStaticText)
        }
      }
      HStack {
        Spacer()
        Button("Clear History…", role: .destructive) {
          confirmsClear = true
        }
        .disabled(!canClear)
      }
    }
    .padding(20)
    .confirmationDialog(
      "Clear transcript history?", isPresented: $confirmsClear, titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive, action: clear)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Saved transcripts are deleted from this Mac. This cannot be undone.")
    }
  }
}

private struct DiagnosticsSettingsView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    DiagnosticsSettingsContent(
      events: coordinator.diagnostics, refresh: coordinator.refreshDiagnostics,
      clear: coordinator.clearDiagnostics)
  }
}

/// The Diagnostics pane, driven by values so every state can be rendered and audited.
struct DiagnosticsSettingsContent: View {
  let events: [DiagnosticEvent]
  let refresh: () -> Void
  let clear: () -> Void
  @State private var confirmsClear = false

  var body: some View {
    VStack(spacing: 12) {
      if events.isEmpty {
        ContentUnavailableView(
          "No Diagnostics",
          systemImage: "stethoscope",
          description: Text(
            "Event codes and timings appear here. They never include audio or what you said.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(events) { event in
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
          .accessibilityElement(children: .combine)
        }
      }
      HStack {
        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
          .accessibilityLabel("Refresh diagnostics")
        Spacer()
        Button("Clear Diagnostics…", role: .destructive) {
          confirmsClear = true
        }
        .disabled(events.isEmpty)
      }
    }
    .padding(20)
    .task { refresh() }
    .confirmationDialog(
      "Clear diagnostics?", isPresented: $confirmsClear, titleVisibility: .visible
    ) {
      Button("Clear Diagnostics", role: .destructive, action: clear)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The recent event list is emptied. This cannot be undone.")
    }
  }
}
