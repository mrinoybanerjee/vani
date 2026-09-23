import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaniCore

struct MeetingView: View {
  @ObservedObject var model: MeetingModel
  @State private var tab = "My notes"
  @State private var confirmingCapture = false
  @State private var confirmingAudioRemoval = false
  @State private var confirmingDiscard = false
  @State private var confirmingDelete = false
  @State private var copied = false
  @State private var followingTranscript = true
  @State private var userScrollingTranscript = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      toolbar
      Divider()
      if model.draft != nil { detail } else { welcome }
      status
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .tint(VaniTheme.accent).background(VaniTheme.paper)
      .onChange(of: model.draft?.id) {
        tab = model.draft?.summary.isEmpty == false ? "Summary" : "My notes"
        followingTranscript = true
      }
      .task(id: model.draft?.notes) { await autosave() }
      .task(id: model.draft?.title) { await autosave() }
      .confirmationDialog(
        "Start a meeting recording?", isPresented: $confirmingCapture, titleVisibility: .visible
      ) {
        Button("Start recording") {
          Task {
            await model.start()
            tab = "My notes"
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Vani records your microphone and other Mac audio. Let participants know before starting. macOS may ask you to allow Screen & System Audio Recording; Vani captures audio only, never your screen. Use headphones to reduce echo. Audio, transcription and summaries stay on this Mac."
        )
      }
      .confirmationDialog(
        "Remove this meeting’s saved audio?", isPresented: $confirmingAudioRemoval,
        titleVisibility: .visible
      ) {
        if model.failedSegmentCount > 0 {
          Button("Remove All Audio", role: .destructive) {
            Task { await model.clearAudio(includingFailed: true) }
          }
        } else {
          Button("Remove audio", role: .destructive) { Task { await model.clearAudio() } }
        }
        Button("Keep audio", role: .cancel) {}
      } message: {
        Text(
          model.failedSegmentCount > 0
            ? "\(model.failedSegmentCount) part(s) couldn’t be transcribed, and their audio is the only copy of that speech. Keep the audio to retry with Recover transcript. Removal cannot be undone."
            : "Your notes, transcript and summary will remain. Audio removal cannot be undone."
        )
      }
      .confirmationDialog(
        "Move this meeting to Recently Deleted?", isPresented: $confirmingDelete,
        titleVisibility: .visible
      ) {
        Button("Move to Recently Deleted", role: .destructive) {
          Task { await model.setDeleted(true) }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "You can restore it from Recently Deleted. Its notes, transcript, summary and saved audio are kept."
        )
      }
      .confirmationDialog("Discard unsaved meeting changes?", isPresented: $confirmingDiscard) {
        Button("Discard Unsaved Changes", role: .destructive) { model.discardChanges() }
        Button("Keep Editing", role: .cancel) {}
      } message: {
        Text(
          "Export a copy first to keep your unsaved edits. Saved meeting data and captured audio will remain."
        )
      }
  }

  private func autosave() async {
    do {
      try await Task.sleep(for: .milliseconds(600))
      // save() waits for any write already in flight, then saves the latest draft.
      await model.save()
    } catch {}
  }

  private var recordingOrFinishing: Bool {
    model.phase == .recording || model.phase == .stopping || model.phase == .transcribing
      || model.phase == .finishing
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Text(model.phase == .recording ? "Meeting in progress" : "Meetings")
        .font(.system(size: 13, weight: .medium))
      Spacer()
      if let meeting = model.draft {
        if copied {
          Text("Copied").font(.caption).foregroundStyle(.secondary)
        }
        Button {
          copyMarkdown(meeting)
        } label: {
          Image(systemName: "doc.on.clipboard")
        }
        .buttonStyle(.borderless).help("Copy as Markdown").accessibilityLabel("Copy as Markdown")
        Button {
          export(meeting)
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.borderless).help("Export meeting").accessibilityLabel("Export meeting")
        Menu {
          Button("Recover transcript") { Task { await model.recoverTranscript() } }
          Button("Remove saved audio…", role: .destructive) { confirmingAudioRemoval = true }
          Divider()
          if meeting.deletedAt == nil {
            Button("Move to Recently Deleted…", role: .destructive) { confirmingDelete = true }
              .disabled(model.summarizingSelection)
          } else {
            Button("Restore meeting") { Task { await model.setDeleted(false) } }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(model.busy || model.saving)
        .accessibilityLabel("Meeting actions")
      }
      if model.phase == .recording || model.phase == .finishing {
        Button(
          model.phase == .finishing ? "Finish saving" : "Stop meeting",
          systemImage: "stop.circle.fill"
        ) {
          Task {
            await model.stop()
            tab = "Summary"
          }
        }
        .tint(.red).buttonStyle(.borderedProminent)
      } else {
        Button("New meeting", systemImage: "plus") { confirmingCapture = true }
          .disabled(!model.loaded || model.busy || model.saving || !model.captureSupported)
          .help(model.captureSupported ? "Start a meeting recording" : unsupportedMessage)
      }
    }.padding(.horizontal, 24).frame(height: 60)
  }

  private var detail: some View {
    VStack(alignment: .leading, spacing: 20) {
      if model.draft?.deletedAt != nil {
        HStack(spacing: 12) {
          Label("This meeting is in Recently Deleted.", systemImage: "trash")
            .foregroundStyle(.secondary)
          Button("Restore meeting") { Task { await model.setDeleted(false) } }
            .disabled(model.busy || model.saving)
        }.font(.callout)
      }
      TextField(
        "Meeting title",
        text: Binding(get: { model.draft?.title ?? "" }, set: { model.draft?.title = $0 })
      )
      .textFieldStyle(.plain).font(.system(size: 28, weight: .medium, design: .serif))
      .accessibilityLabel("Meeting title")
      Picker("Meeting section", selection: $tab) {
        ForEach(["My notes", "Transcript", "Summary"], id: \.self) { name in
          Text(name).tag(name)
        }
      }.pickerStyle(.segmented).labelsHidden()
      Group {
        switch tab {
        case "Transcript": transcript
        case "Summary": summary
        default:
          ZStack(alignment: .topLeading) {
            if model.draft?.notes.isEmpty == true {
              Text("Add notes…")
                .foregroundStyle(.secondary).padding(.horizontal, 4).allowsHitTesting(false)
            }
            TextEditor(
              text: Binding(get: { model.draft?.notes ?? "" }, set: { model.draft?.notes = $0 })
            )
            .scrollContentBackground(.hidden).font(.system(size: 15)).lineSpacing(6)
            .accessibilityLabel("Meeting notes")
          }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }.padding(32)
  }

  private var transcript: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.echoCount > 0 {
        Toggle(isOn: $model.showingEchoes) {
          Text(
            "Show \(model.echoCount) microphone echo \(model.echoCount == 1 ? "line" : "lines") of Mac audio"
          )
        }
        .toggleStyle(.checkbox).font(.caption)
        .help("Without headphones, the microphone also hears other participants.")
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(model.visibleTranscript) { segment in
              segmentView(segment).id(segment.id)
            }
            if model.visibleTranscript.isEmpty {
              Text(
                model.phase == .recording
                  ? "Listening. Transcript updates arrive about every 20 seconds."
                  : "No speech transcribed yet."
              )
              .foregroundStyle(.secondary)
            }
          }
        }
        .modifier(
          FollowsLatest(following: $followingTranscript, scrolling: $userScrollingTranscript)
        )
        .onChange(of: model.visibleTranscript.last?.id) {
          // Never move the transcript while the user is scrolling or reading earlier lines.
          guard model.phase == .recording, followingTranscript, !userScrollingTranscript,
            let last = model.visibleTranscript.last?.id
          else { return }
          proxy.scrollTo(last, anchor: .bottom)
        }
      }
    }
  }

  private func segmentView(_ segment: MeetingTranscriptSegment) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(
        "\(segment.source.label) · \(meetingTimestamp(segment.offset))\(segment.isEcho ? " · Echo of Mac audio" : "")"
      )
      .font(.caption.weight(.medium)).foregroundStyle(.secondary)
      if segment.isFailed {
        Label(
          segment.duration > 0
            ? "Couldn’t transcribe \(segment.timeRange)" : "Couldn’t read this saved audio",
          systemImage: "exclamationmark.triangle"
        )
        .font(.system(size: 15)).foregroundStyle(.secondary)
        .help(failedSegmentHint)
      } else {
        Text(segment.text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
          .foregroundStyle(segment.isEcho ? .secondary : .primary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityHint(segment.isFailed ? failedSegmentHint : "")
  }

  private let failedSegmentHint = "The audio is kept. Use Recover transcript to try again."

  /// Why Generate summary is unavailable, so a disabled button is never unexplained.
  private var summaryUnavailableReason: String? {
    if model.transcriptionFailed {
      return "Recover the transcript first: some saved audio hasn’t been transcribed yet."
    }
    if model.summarizingID != nil { return "Another meeting is being summarized." }
    if model.draft?.transcript.contains(where: \.isSpeech) != true {
      return "There is no transcribed speech to summarize yet."
    }
    return nil
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.summarizingSelection {
        HStack {
          ProgressView().controlSize(.small)
          Text("Summarizing on this Mac…")
          Spacer()
          Button("Cancel") { model.cancelSummary() }
        }.font(.subheadline)
      } else if recordingOrFinishing {
        Text("Your summary will be generated after capture and transcription finish.")
          .foregroundStyle(.secondary)
      } else {
        HStack(spacing: 12) {
          Button(
            model.draft?.summary.isEmpty == true ? "Generate summary" : "Regenerate summary",
            systemImage: "sparkles"
          ) {
            Task { await model.generateSummary() }
          }.disabled(summaryUnavailableReason != nil || model.saving)
          if let reason = summaryUnavailableReason {
            Text(reason).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if let hint = ollamaHint {
        Label(hint, systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      Text(
        "AI-generated on this Mac from the transcript, guided by your notes. Review the quoted sources before relying on decisions or action items."
      )
      .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        Text(model.draft?.summary ?? "").font(.system(size: 15)).lineSpacing(6)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.task { await model.refreshSummaryAvailability() }
  }

  private var ollamaHint: String? {
    switch model.summaryAvailability {
    case .modelMissing: "Summaries need Ollama with qwen3:4b — run `ollama pull qwen3:4b`"
    case .unreachable: "Summaries need Ollama with qwen3:4b — start Ollama, then try again"
    case .ready, nil: nil
    }
  }

  private let unsupportedMessage =
    "Meeting recording requires macOS 15 or later. Dictation and quick notes still work."

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 20) {
      Image(systemName: "waveform").font(.system(size: 30, weight: .light)).foregroundStyle(
        VaniTheme.accent
      ).accessibilityHidden(true)
      Text("Meetings").font(.system(size: 34, design: .serif))
      Button("Start a meeting", systemImage: "mic") { confirmingCapture = true }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(!model.loaded || model.busy || !model.captureSupported)
      Text(
        model.captureSupported
          ? "Microphone + Mac audio · Everything stays local" : unsupportedMessage
      )
      .font(.caption).foregroundStyle(.secondary)
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if model.dirty && !model.busy {
          Button("Discard Changes…") { confirmingDiscard = true }.disabled(model.saving)
        }
        if !model.loaded { Button("Retry opening meetings") { Task { await model.load() } } }
        if model.transcriptionFailed && !model.busy {
          Button("Recover transcript") { Task { await model.recoverTranscript() } }
        }
      }
      HStack {
        Label(
          statusText, systemImage: model.phase == .recording ? "record.circle" : "internaldrive"
        )
        .foregroundStyle(model.phase == .recording ? .red : .secondary)
        Spacer()
        if model.draft != nil {
          Button("Save notes") { Task { await model.save() } }
            .keyboardShortcut("s", modifiers: .command).disabled(!model.dirty || model.saving)
        }
      }
    }.font(.caption).controlSize(.small).padding(.horizontal, 24).padding(.vertical, 12)
  }

  private var statusText: String {
    switch model.phase {
    case .preparing: "Preparing local meeting capture…"
    case .recording: "Recording · Dictation paused · Up to 2 hours"
    case .stopping, .finishing: "Finishing audio capture…"
    case .transcribing: "Finishing local transcription…"
    case .summarizing: "Generating a local summary…"
    case .idle:
      model.saving
        ? "Saving…"
        : model.dirty
          ? "Unsaved changes"
          : model.summarizingID != nil ? "Generating a local summary…" : "Saved on this Mac"
    }
  }

  private func copyMarkdown(_ meeting: MeetingRecord) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(meeting.markdownText, forType: .string)
    copied = true
    AccessibilityNotification.Announcement("Copied meeting as Markdown").post()
    Task {
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }

  private func export(_ meeting: MeetingRecord) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = meeting.exportFileName + ".txt"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try meeting.exportedText.write(to: url, atomically: true, encoding: .utf8) } catch {
        NSAlert(error: error).runModal()
      }
    }
  }
}

/// Keeps the live transcript pinned to the newest segment until the user scrolls away from the
/// bottom, and reports active scrolling so new segments never pull the view while the user reads.
/// Meeting capture needs macOS 15, which provides scroll geometry and phases.
private struct FollowsLatest: ViewModifier {
  @Binding var following: Bool
  @Binding var scrolling: Bool

  private struct Position: Equatable {
    let contentHeight: Double
    let atBottom: Bool
  }

  @available(macOS 15.0, *)
  private static func atBottom(_ geometry: ScrollGeometry) -> Bool {
    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
  }

  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.onScrollGeometryChange(for: Position.self) { geometry in
        Position(contentHeight: geometry.contentSize.height, atBottom: Self.atBottom(geometry))
      } action: { old, new in
        // Growth from a new segment is not a user scroll; only movement changes following.
        if old.contentHeight == new.contentHeight { following = new.atBottom }
      }
      .onScrollPhaseChange { _, phase, context in
        switch phase {
        case .idle:
          scrolling = false
          following = Self.atBottom(context.geometry)
        case .animating:
          break
        default:
          scrolling = true
          following = false
        }
      }
    } else {
      content
    }
  }
}

struct MeetingLibraryView: View {
  @ObservedObject var model: MeetingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField("Search meetings", text: $model.search).textFieldStyle(.plain).accessibilityLabel(
          "Search meetings")
        if !model.search.isEmpty {
          Button {
            model.search = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
        }
      }.padding(12).background(VaniTheme.paper, in: RoundedRectangle(cornerRadius: 8))
      HStack(spacing: 4) {
        categoryButton("Meetings", deleted: false)
        categoryButton("Recently Deleted", deleted: true)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(model.visibleMeetings) { meeting in
            Button {
              Task {
                await model.select(meeting)
              }
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                Text(meeting.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                  .font(.caption).foregroundStyle(.secondary)
                if model.summarizingID == meeting.id {
                  Label("Summarizing…", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
                } else if meeting.endedAt == nil && model.phase == .idle {
                  Label("Interrupted · recover", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(
                  model.draft?.id == meeting.id ? VaniTheme.paper : .clear,
                  in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(model.busy || model.saving)
              .accessibilityAddTraits(model.draft?.id == meeting.id ? .isSelected : [])
          }
          if model.visibleMeetings.isEmpty {
            Text(
              !model.search.isEmpty
                ? "No matching meetings"
                : model.showingDeleted ? "No recently deleted meetings" : "No meetings yet"
            )
            .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
          }
        }
      }
      Label("Stored on this Mac", systemImage: "internaldrive")
        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
    }.padding(.horizontal, 20).padding(.top, 20)
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
      .padding(.horizontal, 8).padding(.vertical, 8)
      .background(
        model.showingDeleted == deleted ? VaniTheme.paper : .clear,
        in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).disabled(model.busy || model.saving)
      .accessibilityAddTraits(model.showingDeleted == deleted ? .isSelected : [])
  }
}
