import AppKit
import SwiftUI

struct WorkspaceView: View {
  @ObservedObject var model: WorkspaceModel

  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 0) {
        VaniWordmark(size: 25).padding(24)
        VStack(spacing: 4) {
          ForEach(WorkspaceModel.Section.allCases) { section in
            Button {
              select(section)
            } label: {
              Label(section.rawValue, systemImage: section.icon)
                .font(.system(size: 13, weight: model.selection == section ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .selectionHighlight(model.selection == section, cornerRadius: 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.transitioning)
            // Command-1, -2 and -3 move between sidebar sections, as in other Mac sidebars.
            .keyboardShortcut(section.keyEquivalent, modifiers: .command)
            .help("\(section.rawValue) (Command-\(section.keyEquivalent.character))")
            .accessibilityIdentifier("workspace-\(section.rawValue.lowercased())")
            .accessibilityAddTraits(model.selection == section ? .isSelected : [])
          }
        }.padding(.horizontal, 12).padding(.bottom, 20)
        Divider().padding(.horizontal, 20)
        Group {
          switch model.selection {
          case .meetings: MeetingLibraryView(model: model.meetings)
          case .notes: NotesLibraryView(model: model.notes)
          case .settings: Spacer(minLength: 20)
          }
        }.disabled(model.transitioning)
        WorkspaceMeetingStatus(model: model.meetings) {
          select(.meetings)
        }
      }
      .frame(minWidth: 240, idealWidth: 260, maxWidth: 320, maxHeight: .infinity)
      .background(VaniTheme.sidebar)

      ZStack {
        retained(MeetingView(model: model.meetings), for: .meetings)
        retained(NotesView(model: model.notes), for: .notes)
        retained(SettingsView(active: model.selection == .settings), for: .settings)
      }
      .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
      .background(VaniTheme.paper)
    }
    .tint(VaniTheme.accent)
    .background(VaniTheme.paper)
  }

  private func select(_ section: WorkspaceModel.Section) {
    NSApplication.shared.keyWindow?.makeFirstResponder(nil)
    Task { await model.select(section) }
  }

  // Keep editor, tab and settings drafts alive, while only the visible page receives input.
  // Zero opacity removes hidden pages from the accessibility tree (the audit tests pin this).
  // `accessibilityHidden(false)` is deliberately not applied to the visible page: it would
  // override the decorative images hidden inside it and expose raw symbol names to VoiceOver.
  private func retained<Content: View>(_ content: Content, for section: WorkspaceModel.Section)
    -> some View
  {
    content.opacity(model.selection == section ? 1 : 0)
      .allowsHitTesting(model.selection == section && !model.transitioning)
      .disabled(model.selection != section || model.transitioning)
  }
}

extension WorkspaceModel.Section {
  /// Sidebar order: Command-1 Meetings, Command-2 Notes, Command-3 Settings.
  var keyEquivalent: KeyEquivalent {
    switch self {
    case .meetings: "1"
    case .notes: "2"
    case .settings: "3"
    }
  }
}

private struct WorkspaceMeetingStatus: View {
  @ObservedObject var model: MeetingModel
  let openMeeting: () -> Void

  var body: some View {
    if model.busy || model.error != nil {
      Button(action: openMeeting) {
        Label(label, systemImage: model.phase == .recording ? "record.circle" : "waveform")
          .font(.caption.weight(.medium))
          .foregroundStyle(model.phase == .recording ? .red : .secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
      }.buttonStyle(.plain).help("Open current meeting")
        .accessibilityLabel(label)
        .accessibilityHint("Opens the current meeting")
    }
  }

  private var label: String {
    switch model.phase {
    case .recording: "Meeting recording"
    case .preparing: "Preparing meeting…"
    case .stopping, .finishing, .transcribing: "Finishing meeting…"
    case .summarizing: "Summarizing meeting…"
    case .idle: "Meeting needs attention"
    }
  }
}
