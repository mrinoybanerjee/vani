import OSLog

public enum VaniLog {
  private static let subsystem = "com.mrinoy.vani"

  private static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
  private static let capture = Logger(subsystem: subsystem, category: "capture")
  private static let model = Logger(subsystem: subsystem, category: "model")
  private static let insertion = Logger(subsystem: subsystem, category: "insertion")

  public static func phase(_ phase: SessionPhase) {
    lifecycle.info("phase=\(phase.rawValue, privacy: .public)")
  }

  public static func event(category: DiagnosticCategory, code: String) {
    let logger = logger(for: category)
    logger.info("event=\(code, privacy: .public)")
  }

  public static func failure(_ failure: VaniFailure, phase: SessionPhase) {
    let logger = logger(for: category(for: failure))
    logger.error(
      "failure=\(failure.code, privacy: .public) phase=\(phase.rawValue, privacy: .public)"
    )
  }

  private static func logger(for category: DiagnosticCategory) -> Logger {
    switch category {
    case .capture: capture
    case .model, .transcription: model
    case .insertion, .recovery: insertion
    case .lifecycle, .permission, .storage: lifecycle
    }
  }

  private static func category(for failure: VaniFailure) -> DiagnosticCategory {
    switch failure {
    case .microphonePermissionDenied, .accessibilityPermissionDenied: .permission
    case .audioDeviceUnavailable, .audioCaptureFailed, .recordingTooShort,
      .recordingTooLong, .noSpeechDetected:
      .capture
    case .modelUnavailable, .modelDownloadFailed, .modelLoadFailed: .model
    case .transcriptionFailed, .emptyTranscript: .transcription
    case .focusChanged, .insertionFailed, .insertionUnverified, .clipboardChanged:
      .insertion
    case .historyCorrupt: .storage
    case .unsupportedHardware, .operationCancelled, .internalInvariant: .lifecycle
    }
  }
}
