import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaniCore

@MainActor
final class MeetingWindowController: NSObject, NSWindowDelegate {
  let model: MeetingModel
  private(set) var window: NSWindow?
  private var closing = false
  init(model: MeetingModel) { self.model = model }

  func present() {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = "Vani Meetings"
      window.contentMinSize = NSSize(width: 780, height: 520)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentViewController = NSHostingController(rootView: MeetingView(model: model))
      window.setContentSize(NSSize(width: 1060, height: 720))
      window.center()
      self.window = window
    }
    NSApplication.shared.activate()
    window?.makeKeyAndOrderFront(nil)
    Task { await model.load() }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !closing else { return false }
    guard model.dirty || model.saving else { return true }
    closing = true
    Task {
      if await model.prepareToClose() { sender.close() }
      closing = false
    }
    return false
  }
}

struct MeetingView: View {
  @ObservedObject var model: MeetingModel
  @State private var tab = "My notes"
  @State private var confirmingCapture = false
  @State private var confirmingAudioRemoval = false

  var body: some View {
    HSplitView {
      library
      VStack(alignment: .leading, spacing: 0) {
        toolbar
        Divider()
        if model.draft != nil { detail } else { welcome }
        status
      }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .background(VaniTheme.paper)
    }
    .tint(VaniTheme.accent).background(VaniTheme.paper)
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
  }

  private var library: some View {
    VStack(alignment: .leading, spacing: 18) {
      VaniWordmark().padding(.top, 24)
      Text("MEETINGS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(
        .secondary)
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
                tab = meeting.summary.isEmpty ? "My notes" : "Summary"
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
          }
          if model.visibleMeetings.isEmpty {
            Text(
              model.search.isEmpty ? "Your conversations will appear here." : "No matching meetings"
            )
            .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
          }
        }
      }
      Label("Stored on this Mac", systemImage: "internaldrive")
        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 20)
    }.padding(.horizontal, 20).frame(minWidth: 240, idealWidth: 260, maxWidth: 300)
      .background(VaniTheme.sidebar)
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
      HStack(spacing: 18) {
        ForEach(["My notes", "Transcript", "Summary"], id: \.self) { name in
          Button {
            tab = name
          } label: {
            VStack(spacing: 8) {
              Text(name).font(.system(size: 13, weight: tab == name ? .semibold : .regular))
              Rectangle().fill(tab == name ? VaniTheme.accent : .clear).frame(height: 2)
            }
          }.buttonStyle(.plain).accessibilityAddTraits(tab == name ? .isSelected : [])
        }
        Spacer()
      }
      Group {
        switch tab {
        case "Transcript": transcript
        case "Summary": summary
        default:
          ZStack(alignment: .topLeading) {
            if model.draft?.notes.isEmpty == true {
              Text("Your thoughts, alongside the conversation…")
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
      Text("Be in the conversation.").font(.system(size: 34, design: .serif))
      Text(
        "Capture your meeting. Keep your own notes.\nLeave with a transcript, decisions and next steps."
      )
      .font(.system(size: 15)).lineSpacing(6).foregroundStyle(.secondary)
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
