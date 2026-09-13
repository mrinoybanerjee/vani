import SwiftUI
import VaniCore

struct MenuContentView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(20)
      Divider()
      content
        .padding(24)
      Divider()
      footer
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    .frame(width: 360)
    .background(VaniTheme.paper)
    .tint(VaniTheme.accent)
  }

  private var header: some View {
    HStack(spacing: 10) {
      VaniWordmark(size: 24)
      Spacer()
      Label(
        statusLabel,
        systemImage: coordinator.snapshot.phase == .ready ? "checkmark.circle" : "circle.dotted"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Spacer()
      if coordinator.snapshot.phase == .listening {
        Circle()
          .fill(.red)
          .frame(width: 8, height: 8)
          .accessibilityLabel("Recording")
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch coordinator.snapshot.phase {
    case .recoverableError:
      RecoveryView()
    case .preparing:
      PreparationView()
    case .ready where coordinator.setupIncomplete:
      SetupView()
    case .ready where coordinator.meetingOwnsSpeech:
      VStack(alignment: .leading, spacing: 12) {
        Text("In the conversation.").font(.system(size: 25, design: .serif))
        Text("Meeting audio is being captured or transcribed. Dictation returns when it finishes.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Open meeting", systemImage: "waveform") { coordinator.showMeetings() }
          .buttonStyle(.borderedProminent)
      }
    case .ready, .listening, .transcribing, .inserting:
      ReadyView()
    case .setup, .disabled:
      SetupView()
    }
  }

  private var footer: some View {
    HStack {
      Button("Meetings", systemImage: "waveform") { coordinator.showMeetings() }
        .buttonStyle(.plain).font(.caption).frame(height: 28)
      Button("Notes", systemImage: "note.text") { coordinator.showNotes() }
        .buttonStyle(.plain)
        .font(.caption)
        .frame(height: 28)
      SettingsLink {
        Label("Settings", systemImage: "gearshape")
          .font(.caption)
          .padding(.horizontal, 4)
          .frame(height: 28)
      }
      .buttonStyle(.plain)
      .help("Settings")

      Spacer()

      Button {
        coordinator.quit()
      } label: {
        Image(systemName: "power")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .help("Quit Vani")
      .accessibilityLabel("Quit Vani")
    }
  }

  private var statusLabel: String {
    if coordinator.snapshot.phase == .ready, coordinator.setupIncomplete {
      return "Setup"
    }
    return switch coordinator.snapshot.phase {
    case .setup: "Setup"
    case .preparing: "Preparing speech model"
    case .ready: "Ready"
    case .listening: "Listening"
    case .transcribing: "Transcribing"
    case .inserting: "Inserting"
    case .recoverableError: "Needs attention"
    case .disabled: "Stopped"
    }
  }
}

private struct SetupView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Make room for your voice.").font(.system(size: 23, design: .serif))
      Text("A few permissions, then everything runs on this Mac.")
        .font(.caption).foregroundStyle(.secondary)
      PermissionRow(
        title: "Microphone",
        detail: "Hear you while you dictate",
        state: coordinator.microphonePermission,
        action: coordinator.requestMicrophonePermission
      )
      PermissionRow(
        title: "Accessibility",
        detail: "Insert words where you are writing",
        state: coordinator.accessibilityPermission,
        action: coordinator.requestAccessibilityPermission
      )
      PermissionRow(
        title: "Input Monitoring",
        detail: "Respond to your dictation shortcut",
        state: coordinator.inputMonitoringPermission,
        action: coordinator.requestInputMonitoringPermission
      )
      HStack(spacing: 10) {
        Image(
          systemName: coordinator.modelInstalled
            ? "checkmark.circle.fill" : "arrow.down.circle"
        )
        .foregroundStyle(coordinator.modelInstalled ? .green : .secondary)
        .frame(width: 20)
        Text("English speech model")
          .font(.system(size: 13, weight: .medium))
        Spacer()
        if !coordinator.modelInstalled {
          Button("Download", systemImage: "arrow.down") {
            coordinator.downloadModel()
          }
          .controlSize(.small)
        }
      }
    }
  }
}

private struct PermissionRow: View {
  let title: String
  let detail: String
  let state: PermissionState
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(state.isGranted ? .green : .secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if !state.isGranted {
        Button("Allow", action: action)
          .controlSize(.small)
      }
    }
  }
}

private struct PreparationView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Preparing local speech model")
        .font(.system(size: 13, weight: .semibold))
      if let progress = coordinator.snapshot.modelProgress {
        ProgressView(value: progress)
      } else {
        ProgressView()
      }
    }
  }
}

private struct ReadyView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 18) {
        Text(phaseTitle)
          .font(.system(size: 28, weight: .regular, design: .serif))
        if coordinator.snapshot.phase == .ready {
          Text("Your voice, wherever you write.")
            .font(.system(size: 13)).foregroundStyle(.secondary)
          HStack(spacing: 10) {
            ShortcutKey(label: coordinator.settings.shortcut.label)
            Text("Hold to speak · Release to insert")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else {
          HStack(spacing: 10) {
            Image(systemName: phaseIcon).foregroundStyle(phaseColor)
            Text(
              coordinator.snapshot.phase == .listening
                ? "Release your shortcut when you’re done." : "Processing on this Mac…"
            )
            .font(.caption).foregroundStyle(.secondary)
            if coordinator.snapshot.phase != .listening { ProgressView().controlSize(.small) }
          }
        }
      }.padding(.bottom, 8)

      if coordinator.snapshot.phase == .ready,
        coordinator.snapshot.hasLastTranscript
      {
        Divider()
        Text("LAST DICTATION").font(.system(size: 10, weight: .semibold)).tracking(1.2)
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Button("Paste Last", systemImage: "arrow.down.doc") {
            coordinator.pasteLastTranscript()
          }
          .buttonStyle(.borderedProminent)
          .help("Paste last transcript (Control-Command-V)")

          Button("Copy", systemImage: "doc.on.doc") {
            coordinator.copyLastTranscript()
          }
          .help("Copy last transcript (Control-Command-C)")

          if coordinator.settings.personalizationEnabled {
            Button("Teach", systemImage: "brain.head.profile") {
              coordinator.prepareToShowTeachWindow()
              Task {
                guard let candidate = await coordinator.correctionCandidate() else { return }
                coordinator.showTeachWindow(for: candidate)
              }
            }
            .help("Correct the last transcript and teach Vani")
          }

          Spacer()
        }
        .controlSize(.small)
        Button("Save as Note", systemImage: "note.text.badge.plus") {
          coordinator.showNotes(saveLastTranscript: true)
        }
        .controlSize(.small)
      }
    }
  }

  private var phaseTitle: String {
    switch coordinator.snapshot.phase {
    case .ready: "A little less typing."
    case .listening: "Listening"
    case .transcribing: "Transcribing"
    case .inserting: "Inserting text"
    default: "Vani"
    }
  }

  private var phaseIcon: String {
    switch coordinator.snapshot.phase {
    case .listening: "waveform.circle.fill"
    case .transcribing, .inserting: "text.bubble.fill"
    default: "checkmark.circle.fill"
    }
  }

  private var phaseColor: Color {
    coordinator.snapshot.phase == .listening ? .red : VaniTheme.accent
  }
}

private struct RecoveryView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(
        coordinator.snapshot.failure?.title ?? "Action needed",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.orange)

      Text(coordinator.snapshot.failure?.message ?? "Your transcript is preserved.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let transcript = coordinator.snapshot.recoverableTranscript {
        ScrollView {
          Text(transcript)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 96)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
      }

      HStack {
        if let label = coordinator.primaryRecoveryLabel {
          Button(label, systemImage: coordinator.primaryRecoveryIcon) {
            coordinator.performPrimaryRecoveryAction()
          }
          .buttonStyle(.borderedProminent)
        }

        if coordinator.snapshot.hasRecoverableTranscript,
          coordinator.snapshot.failure?.recoveryAction != .copyTranscript
        {
          Button("Copy", systemImage: "doc.on.doc") {
            coordinator.copyRecoveredTranscript()
          }
        }

        Spacer()

        if coordinator.snapshot.failure?.recoveryAction != .startAgain {
          Button("Discard", role: .destructive) {
            coordinator.discardRecovery()
          }
        }
      }
      .controlSize(.small)
    }
  }
}
