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
      }
      .task(id: model.draft?.notes) {
        do {
          try await Task.sleep(for: .milliseconds(600))
          while model.saving { try await Task.sleep(for: .milliseconds(10)) }
          if !Task.isCancelled { await model.save() }
        } catch {}
      }
      .task(id: model.draft?.title) {
        do {
          try await Task.sleep(for: .milliseconds(600))
          while model.saving { try await Task.sleep(for: .milliseconds(10)) }
          if !Task.isCancelled { await model.save() }
        } catch {}
      }
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
          "Vani records your microphone and other Mac audio. Let participants know before starting. Use headphones to reduce echo. Audio, transcription and summaries stay on this Mac."
        )
      }
      .confirmationDialog(
        "Remove this meeting’s saved audio?", isPresented: $confirmingAudioRemoval,
        titleVisibility: .visible
      ) {
        Button("Remove audio", role: .destructive) { Task { await model.clearAudio() } }
        Button("Keep audio", role: .cancel) {}
      } message: {
        Text("Your notes, transcript and summary will remain. Audio removal cannot be undone.")
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

  private var toolbar: some View {
    HStack {
      Text(model.phase == .recording ? "Meeting in progress" : "Meetings")
        .font(.system(size: 13, weight: .medium))
      Spacer()
      if let meeting = model.draft {
        Button {
          export(meeting)
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.borderless).help("Export meeting").accessibilityLabel("Export meeting")
        Menu {
          Button("Recover transcript") { Task { await model.recoverTranscript() } }
          Button("Remove saved audio…", role: .destructive) { confirmingAudioRemoval = true }
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
          .disabled(!model.loaded || model.busy || model.saving)
      }
    }.padding(.horizontal, 24).frame(height: 60)
  }

  private var detail: some View {
    VStack(alignment: .leading, spacing: 20) {
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
                .foregroundStyle(.secondary).padding(.horizontal, 5).allowsHitTesting(false)
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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(
          (model.draft?.transcript ?? []).filter { !$0.text.isEmpty }.sorted {
            $0.offset < $1.offset
          }
        ) { segment in
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "\(segment.source.label) · \(Int(segment.offset) / 60):\(String(format: "%02d", Int(segment.offset) % 60))"
            )
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(segment.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        if model.draft?.transcript.allSatisfy({ $0.text.isEmpty }) == true {
          Text(
            model.phase == .recording
              ? "Listening. Transcript updates arrive about every 20 seconds."
              : "No speech transcribed yet."
          )
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 14) {
      if model.phase == .summarizing {
        HStack {
          ProgressView().controlSize(.small)
          Text("Summarizing on this Mac…")
          Spacer()
          Button("Cancel") { model.cancelSummary() }
        }.font(.subheadline)
      } else if model.phase == .recording || model.phase == .stopping
        || model.phase == .transcribing || model.phase == .finishing
      {
        Text("Your summary will be generated after capture and transcription finish.")
          .foregroundStyle(.secondary)
      } else {
        Button(
          model.draft?.summary.isEmpty == true ? "Generate summary" : "Regenerate summary",
          systemImage: "sparkles"
        ) {
          Task { await model.generateSummary() }
        }.disabled(model.transcriptionFailed || model.draft?.transcript.isEmpty == true)
      }
      Text(
        "AI-generated from the transcript. Review the quoted sources before relying on decisions or action items."
      )
      .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        Text(model.draft?.summary ?? "").font(.system(size: 15)).lineSpacing(6)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 20) {
      Image(systemName: "waveform").font(.system(size: 30, weight: .light)).foregroundStyle(
        VaniTheme.accent)
      Text("Meetings").font(.system(size: 34, design: .serif))
      Button("Start a meeting", systemImage: "mic") { confirmingCapture = true }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.loaded || model.busy)
      Text("Microphone + Mac audio · Everything stays local")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }.font(.caption).controlSize(.small).padding(.horizontal, 24).padding(.vertical, 14)
  }

  private var statusText: String {
    switch model.phase {
    case .preparing: "Preparing local meeting capture…"
    case .recording: "Recording · Dictation paused · Up to 2 hours"
    case .stopping, .finishing: "Finishing audio capture…"
    case .transcribing: "Finishing local transcription…"
    case .summarizing: "Generating a local summary…"
    case .idle: model.saving ? "Saving…" : model.dirty ? "Unsaved changes" : "Saved on this Mac"
    }
  }

  private func export(_ meeting: MeetingRecord) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "Vani Meeting.txt"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try meeting.exportedText.write(to: url, atomically: true, encoding: .utf8) } catch {
        NSAlert(error: error).runModal()
      }
    }
  }
}

struct MeetingLibraryView: View {
  @ObservedObject var model: MeetingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search meetings", text: $model.search).textFieldStyle(.plain).accessibilityLabel(
          "Search meetings")
      }.padding(10).background(VaniTheme.paper, in: RoundedRectangle(cornerRadius: 8))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
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
                if meeting.endedAt == nil && model.phase == .idle {
                  Label("Interrupted · recover", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(
                  model.draft?.id == meeting.id ? VaniTheme.paper : .clear,
                  in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).disabled(model.busy || model.saving)
              .accessibilityAddTraits(model.draft?.id == meeting.id ? .isSelected : [])
          }
          if model.visibleMeetings.isEmpty {
            Text(
              model.search.isEmpty ? "No meetings yet" : "No matching meetings"
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

}
