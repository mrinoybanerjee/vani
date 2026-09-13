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
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                  model.selection == section ? VaniTheme.paper : .clear,
                  in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.transitioning)
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
        retained(SettingsView(), for: .settings)
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
  private func retained<Content: View>(_ content: Content, for section: WorkspaceModel.Section)
    -> some View
  {
    content.opacity(model.selection == section ? 1 : 0)
      .allowsHitTesting(model.selection == section && !model.transitioning)
      .disabled(model.selection != section || model.transitioning)
      .accessibilityHidden(model.selection != section)
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
