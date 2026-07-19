import AppKit
import SwiftUI
import VaniCore

struct MenuContentView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(16)
      Divider()
      content
        .padding(16)
      Divider()
      footer
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    .frame(width: 340)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: coordinator.menuBarIconName)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.teal)
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text("Vani")
          .font(.headline)
        Text(statusLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
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
    case .ready, .listening, .transcribing, .inserting:
      ReadyView()
    case .setup, .disabled:
      SetupView()
    }
  }

  private var footer: some View {
    HStack {
      SettingsLink {
        Image(systemName: "gearshape")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .help("Settings")

      Spacer()

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .help("Quit Vani")
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
    VStack(alignment: .leading, spacing: 14) {
      PermissionRow(
        title: "Microphone",
        state: coordinator.microphonePermission,
        action: coordinator.requestMicrophonePermission
      )
      PermissionRow(
        title: "Accessibility",
        state: coordinator.accessibilityPermission,
        action: coordinator.requestAccessibilityPermission
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
  let state: PermissionState
  let action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(state.isGranted ? .green : .secondary)
        .frame(width: 20)
      Text(title)
        .font(.system(size: 13, weight: .medium))
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
    HStack(spacing: 12) {
      Image(systemName: phaseIcon)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(phaseColor)
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 3) {
        Text(phaseTitle)
          .font(.system(size: 14, weight: .semibold))
        if coordinator.snapshot.phase == .ready {
          Text(coordinator.settings.shortcut.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      if coordinator.snapshot.phase == .transcribing
        || coordinator.snapshot.phase == .inserting
      {
        ProgressView()
          .controlSize(.small)
      }
    }
  }

  private var phaseTitle: String {
    switch coordinator.snapshot.phase {
    case .ready: "Ready"
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
    coordinator.snapshot.phase == .listening ? .red : .teal
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

        if coordinator.snapshot.hasRecoverableTranscript {
          Button("Copy", systemImage: "doc.on.doc") {
            coordinator.copyRecoveredTranscript()
          }
        }

        Spacer()

        Button("Discard", role: .destructive) {
          coordinator.discardRecovery()
        }
      }
      .controlSize(.small)
    }
  }
}
