import AppKit
import SwiftUI
import VaniCore

/// What the menu shows. Derived from coordinator state so every branch can be tested.
enum MenuContentState: Equatable {
  case recovery
  case preparing
  case setup
  case meeting
  case shortcutInactive
  case ready
  case dictating

  static func resolve(
    phase: SessionPhase,
    setupIncomplete: Bool,
    meetingOwnsSpeech: Bool,
    shortcutActive: Bool
  ) -> MenuContentState {
    switch phase {
    case .recoverableError: .recovery
    case .preparing: .preparing
    case .setup, .disabled: .setup
    case .ready where setupIncomplete: .setup
    case .ready where meetingOwnsSpeech: .meeting
    case .ready where !shortcutActive: .shortcutInactive
    case .ready: .ready
    case .listening, .transcribing, .inserting: .dictating
    }
  }
}

struct MenuContentView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  private var state: MenuContentState {
    .resolve(
      phase: coordinator.snapshot.phase,
      setupIncomplete: coordinator.setupIncomplete,
      meetingOwnsSpeech: coordinator.meetingOwnsSpeech,
      shortcutActive: coordinator.shortcutActive)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(20)
      Divider()
      if let error = coordinator.settingsError {
        MenuErrorBanner(message: error, dismiss: coordinator.dismissSettingsError)
          .padding(.horizontal, 24).padding(.top, 16)
      }
      content
        .padding(24)
      Divider()
      footer
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .frame(width: 360)
    .background(VaniTheme.paper)
    .tint(VaniTheme.accent)
  }

  private var header: some View {
    HStack(spacing: 8) {
      VaniWordmark(size: 24)
      Spacer()
      Label(statusLabel, systemImage: statusIcon)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .recovery:
      RecoveryView()
    case .preparing:
      PreparationView()
    case .setup:
      SetupView()
    case .meeting:
      VStack(alignment: .leading, spacing: 12) {
        Text("Meeting in progress").font(.system(size: 24, design: .serif))
        Text("Dictation returns when the meeting finishes transcribing.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Open Meeting", systemImage: "waveform") { coordinator.showMeetings() }
          .buttonStyle(.borderedProminent)
      }
    case .shortcutInactive:
      ShortcutInactiveView(quit: coordinator.quit)
    case .ready, .dictating:
      ReadyView()
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("Meetings", systemImage: "waveform") { coordinator.showMeetings() }
      Button("Notes", systemImage: "note.text") { coordinator.showNotes() }
      Button("Settings", systemImage: "gearshape") { coordinator.showSettings() }
        .help("Settings (Command-Comma)")
      Spacer()
      Button {
        coordinator.quit()
      } label: {
        Image(systemName: "power")
          .frame(width: 24, height: 24)
      }
      .help("Quit Vani")
      .accessibilityLabel("Quit Vani")
    }
    .buttonStyle(.plain)
    .font(.caption)
    .frame(height: 28)
  }

  private var statusIcon: String {
    switch state {
    case .ready: "checkmark.circle"
    case .dictating: coordinator.snapshot.phase == .listening ? "record.circle" : "ellipsis.circle"
    case .recovery, .shortcutInactive: "exclamationmark.circle"
    case .preparing, .setup, .meeting: "circle.dotted"
    }
  }

  private var statusLabel: String {
    switch state {
    case .meeting: return "Meeting in progress"
    case .setup: return coordinator.snapshot.phase == .disabled ? "Stopped" : "Setup"
    case .shortcutInactive: return "Shortcut inactive"
    case .recovery: return "Needs attention"
    case .preparing: return "Preparing speech model"
    case .ready: return "Ready"
    case .dictating:
      return coordinator.snapshot.phase == .listening ? "Listening" : "Transcribing…"
    }
  }
}

private struct MenuErrorBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text(message)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Dismiss", action: dismiss)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel("Dismiss error")
    }
    .padding(8)
    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Error: \(message)")
  }
}

// MARK: - Setup

/// One numbered first-run step. Pure data so the ordering and wording are testable.
struct SetupStepModel: Identifiable, Equatable {
  enum Action: Equatable {
    case microphone
    case accessibility
    case inputMonitoring
    case downloadModel
    case keyboardSettings
  }

  let number: Int
  let title: String
  let detail: String
  let status: String
  let isComplete: Bool
  let actionTitle: String?
  let action: Action

  var id: Int { number }

  var accessibilityLabel: String { "Step \(number), \(title), \(status)" }

  static func steps(
    microphone: PermissionState,
    accessibility: PermissionState,
    inputMonitoring: PermissionState,
    modelInstalled: Bool,
    shortcut: HoldShortcut,
    globeKey: GlobeKeyAction
  ) -> [SetupStepModel] {
    var steps: [SetupStepModel] = []
    func permission(
      _ title: String, _ detail: String, _ state: PermissionState, _ action: Action
    ) {
      steps.append(
        SetupStepModel(
          number: steps.count + 1, title: title, detail: detail, status: state.statusText,
          isComplete: state.isGranted, actionTitle: state.isGranted ? nil : "Allow",
          action: action))
    }
    permission("Microphone", "Hears you only while you hold the key", microphone, .microphone)
    permission("Accessibility", "Types into the app you are using", accessibility, .accessibility)
    permission(
      "Input Monitoring", "Detects your hold-to-talk key", inputMonitoring, .inputMonitoring)
    steps.append(
      SetupStepModel(
        number: steps.count + 1, title: "Speech model",
        detail: "One-time 443 MiB download · stays on this Mac",
        status: modelInstalled ? "Installed" : "Not downloaded", isComplete: modelInstalled,
        actionTitle: modelInstalled ? nil : "Download", action: .downloadModel))
    if shortcut == .function {
      let status: String =
        switch globeKey {
        case .doNothing: "Set to Do Nothing"
        case .unknown: "Check this setting"
        case .changeInputSource: "Now: Change Input Source"
        case .showEmojiAndSymbols: "Now: Show Emoji & Symbols"
        case .startDictation: "Now: Start Dictation"
        }
      steps.append(
        SetupStepModel(
          number: steps.count + 1, title: "Keyboard",
          detail: "Set “Press 🌐 key to” → Do Nothing", status: status,
          isComplete: globeKey == .doNothing,
          actionTitle: globeKey == .doNothing ? nil : "Open", action: .keyboardSettings))
    }
    return steps
  }
}

private struct SetupView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    let shortcut = coordinator.settings.shortcut
    SetupStepsView(
      steps: SetupStepModel.steps(
        microphone: coordinator.microphonePermission,
        accessibility: coordinator.accessibilityPermission,
        inputMonitoring: coordinator.inputMonitoringPermission,
        modelInstalled: coordinator.modelInstalled,
        shortcut: shortcut,
        globeKey: shortcut == .function ? GlobeKeyAction.current() : .unknown),
      shortcut: shortcut,
      perform: perform)
  }

  private func perform(_ action: SetupStepModel.Action) {
    switch action {
    case .microphone: coordinator.requestMicrophonePermission()
    case .accessibility: coordinator.requestAccessibilityPermission()
    case .inputMonitoring: coordinator.requestInputMonitoringPermission()
    case .downloadModel: coordinator.downloadModel()
    case .keyboardSettings: GlobeKeyAction.openKeyboardSettings()
    }
  }
}

struct SetupStepsView: View {
  let steps: [SetupStepModel]
  let shortcut: HoldShortcut
  let perform: (SetupStepModel.Action) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Set up Vani").font(.system(size: 24, design: .serif))
      VStack(alignment: .leading, spacing: 12) {
        ForEach(steps) { step in
          SetupStepRow(step: step, perform: perform)
        }
      }
      HStack(spacing: 8) {
        Text("Then hold")
        ShortcutKey(shortcut: shortcut)
        Text("to speak.")
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Then hold the \(shortcut.displayName) key to speak.")
    }
  }
}

private struct SetupStepRow: View {
  let step: SetupStepModel
  let perform: (SetupStepModel.Action) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        ZStack {
          Circle()
            .strokeBorder(step.isComplete ? VaniTheme.accent : Color.secondary.opacity(0.5))
            .background(Circle().fill(step.isComplete ? VaniTheme.accent : .clear))
          if step.isComplete {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(VaniTheme.paper)
          } else {
            Text("\(step.number)")
              .font(.system(size: 11, weight: .semibold).monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 20, height: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(step.title).font(.system(size: 13, weight: .medium))
          Text(step.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(step.status)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(step.isComplete ? VaniTheme.accent : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(step.accessibilityLabel)
      .accessibilityHint(step.detail)

      if let actionTitle = step.actionTitle {
        Button(actionTitle) { perform(step.action) }
          .controlSize(.small)
          .accessibilityLabel(
            step.action == .keyboardSettings
              ? "Open Keyboard Settings" : "\(actionTitle) \(step.title)")
      }
    }
  }
}

// MARK: - Shortcut recovery

/// Relaunches the bundled app after this process exits. The normal terminate path saves drafts.
enum AppRelauncher {
  static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

  /// `/bin/sh` arguments that wait up to 30 s for this process to exit, then reopen the bundle.
  /// If quitting is cancelled (for example, a note could not be saved), nothing reopens.
  static func shellArguments(bundlePath: String, processIdentifier: Int32) -> [String] {
    let script =
      "i=0; while kill -0 \(processIdentifier) 2>/dev/null; do i=$((i+1)); "
      + "[ $i -gt 300 ] && exit 0; sleep 0.1; done; exec /usr/bin/open -n \"$0\""
    return ["-c", script, bundlePath]
  }

  /// Schedules the reopen, then quits. Returns false without quitting if scheduling failed.
  @MainActor
  static func relaunch(quit: () -> Void) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = shellArguments(
      bundlePath: Bundle.main.bundleURL.path,
      processIdentifier: ProcessInfo.processInfo.processIdentifier)
    do {
      try process.run()
    } catch {
      return false
    }
    quit()
    return true
  }
}

struct ShortcutInactiveView: View {
  let quit: () -> Void
  var canRelaunch = AppRelauncher.canRelaunch
  @State private var relaunchFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text("Shortcut not active")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
      }
      .font(.system(size: 14, weight: .semibold))
      Text("macOS applies Input Monitoring after Vani restarts.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if canRelaunch {
        Button("Quit and Reopen", systemImage: "arrow.clockwise") {
          relaunchFailed = !AppRelauncher.relaunch(quit: quit)
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button("Quit Vani", systemImage: "power", action: quit)
          .buttonStyle(.borderedProminent)
      }
      if relaunchFailed || !canRelaunch {
        Text("Open Vani again after it quits.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Progress, ready and recovery

private struct PreparationView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Preparing local speech model")
        .font(.system(size: 13, weight: .semibold))
      if let progress = coordinator.snapshot.modelProgress {
        ProgressView(value: progress)
          .accessibilityValue("\(Int(progress * 100)) percent")
      } else {
        ProgressView()
      }
      Text("The model stays on this Mac.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct ReadyView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 16) {
        if coordinator.snapshot.phase == .ready {
          let shortcut = coordinator.settings.shortcut
          ReadyShortcutRow(
            shortcut: shortcut,
            globeKey: shortcut == .function ? GlobeKeyAction.current() : .unknown,
            handsFreeEnabled: coordinator.settings.handsFreeEnabled)
        } else {
          Text(phaseTitle)
            .font(.system(size: 28, weight: .regular, design: .serif))
          HStack(spacing: 8) {
            Image(systemName: phaseIcon).foregroundStyle(VaniTheme.accent)
              .accessibilityHidden(true)
            Text(listeningHint)
              .font(.system(size: 12)).foregroundStyle(.secondary)
            if coordinator.snapshot.phase != .listening { ProgressView().controlSize(.small) }
          }
          if coordinator.snapshot.phase == .listening {
            HStack(spacing: 8) {
              Button("Stop and Insert", systemImage: "stop.circle") {
                coordinator.stopDictationFromMenu()
              }
              .buttonStyle(.borderedProminent)
              Button("Cancel", systemImage: "xmark") {
                coordinator.cancelDictationFromMenu()
              }
            }
            .controlSize(.small)
          }
        }
      }.padding(.bottom, 8)

      if coordinator.snapshot.phase == .ready,
        coordinator.snapshot.hasLastTranscript
      {
        Divider()
        Text("Last dictation").font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        HStack(spacing: 8) {
          Button("Paste Last", systemImage: "arrow.down.doc") {
            coordinator.pasteLastTranscript()
          }
          .buttonStyle(.borderedProminent)
          .help(lastTranscriptHelp("Paste", key: "V"))

          Button("Copy", systemImage: "doc.on.doc") {
            coordinator.copyLastTranscript()
          }
          .help(lastTranscriptHelp("Copy", key: "C"))

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

  private func lastTranscriptHelp(_ verb: String, key: String) -> String {
    guard let symbols = coordinator.settings.lastTranscriptBinding.symbols else {
      return "\(verb) last transcript"
    }
    return "\(verb) last transcript (\(symbols)\(key))"
  }

  private var listeningHint: String {
    guard coordinator.snapshot.phase == .listening else { return "On this Mac" }
    let key = coordinator.settings.shortcut.displayName
    return coordinator.handsFreeLocked
      ? "Hands-free. Press \(key) again when you’re done."
      : "Release \(key) when you’re done."
  }

  private var phaseTitle: String {
    switch coordinator.snapshot.phase {
    case .listening: "Listening"
    case .transcribing, .inserting: "Transcribing…"
    default: "Vani"
    }
  }

  private var phaseIcon: String {
    switch coordinator.snapshot.phase {
    case .listening: "record.circle"
    case .transcribing, .inserting: "text.bubble"
    default: "checkmark.circle"
    }
  }
}

/// The ready instruction: the physical key to hold, plus a Globe-key hint only when macOS
/// reports that the key also triggers a system action.
struct ReadyShortcutRow: View {
  let shortcut: HoldShortcut
  let globeKey: GlobeKeyAction
  var handsFreeEnabled = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        ShortcutKey(shortcut: shortcut)
        VStack(alignment: .leading, spacing: 4) {
          Text("Hold to speak · Release to insert")
          if handsFreeEnabled { Text("Double-tap for hands-free · Esc cancels") }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Ready. Hold \(shortcut.displayName) to speak, release to insert."
          + (handsFreeEnabled ? " Double-tap for hands-free. Escape cancels." : ""))
      if shortcut == .function, globeKey != .doNothing, globeKey != .unknown {
        VStack(alignment: .leading, spacing: 8) {
          Text("macOS also reacts to 🌐. Set “Press 🌐 key to” → Do Nothing.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Open Keyboard Settings") { GlobeKeyAction.openKeyboardSettings() }
            .controlSize(.small)
        }
      }
    }
  }
}

private struct RecoveryView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(coordinator.snapshot.failure?.title ?? "Action needed")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
      }
      .font(.system(size: 14, weight: .semibold))

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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Preserved transcript")
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
