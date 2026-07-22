import Foundation

public enum RecoveryAction: String, Codable, Sendable, Equatable {
  case openMicrophoneSettings
  case openAccessibilitySettings
  case openInputMonitoringSettings
  case retryPreparation
  case retryTranscription
  case retryInsertion
  case copyTranscript
  case startAgain
  case none
}

public enum VaniFailure: String, Error, Codable, CaseIterable, Sendable, Equatable {
  case unsupportedHardware
  case microphonePermissionDenied
  case accessibilityPermissionDenied
  case inputMonitoringPermissionDenied
  case audioDeviceUnavailable
  case audioCaptureFailed
  case recordingTooShort
  case recordingTooLong
  case noSpeechDetected
  case modelUnavailable
  case modelDownloadFailed
  case modelIntegrityFailed
  case modelLoadFailed
  case transcriptionFailed
  case emptyTranscript
  case focusChanged
  case secureTextField
  case insertionFailed
  case insertionUnverified
  case clipboardChanged
  case historyCorrupt
  case operationCancelled
  case internalInvariant

  public var code: String { rawValue }

  public var title: String {
    switch self {
    case .unsupportedHardware: "Apple Silicon required"
    case .microphonePermissionDenied: "Microphone access needed"
    case .accessibilityPermissionDenied: "Accessibility access needed"
    case .inputMonitoringPermissionDenied: "Input Monitoring access needed"
    case .audioDeviceUnavailable: "Microphone unavailable"
    case .audioCaptureFailed: "Could not record"
    case .recordingTooShort: "Keep holding a little longer"
    case .recordingTooLong: "Recording limit reached"
    case .noSpeechDetected: "No speech recorded"
    case .modelUnavailable: "Speech model unavailable"
    case .modelDownloadFailed: "Model download failed"
    case .modelIntegrityFailed: "Speech model failed verification"
    case .modelLoadFailed: "Speech model could not load"
    case .transcriptionFailed: "Transcription failed"
    case .emptyTranscript: "No words recognized"
    case .focusChanged: "Text target changed"
    case .secureTextField: "Secure field blocked"
    case .insertionFailed: "Could not insert text"
    case .insertionUnverified: "Text is ready to paste"
    case .clipboardChanged: "Clipboard changed"
    case .historyCorrupt: "History was reset"
    case .operationCancelled: "Operation cancelled"
    case .internalInvariant: "Vani needs to reset"
    }
  }

  public var message: String {
    switch self {
    case .unsupportedHardware:
      "Vani currently supports Apple Silicon Macs."
    case .microphonePermissionDenied:
      "Allow Vani to use the microphone in System Settings."
    case .accessibilityPermissionDenied:
      "Your transcript is preserved. Allow Accessibility access or paste it manually."
    case .inputMonitoringPermissionDenied:
      "Allow Input Monitoring so Vani can detect the hold-to-talk shortcut."
    case .audioDeviceUnavailable:
      "Connect or select a microphone, then try again."
    case .audioCaptureFailed:
      "The microphone stopped unexpectedly. Try another recording."
    case .recordingTooShort:
      "The recording ended before speech could be captured."
    case .recordingTooLong:
      "Vani stopped at the two-minute safety limit."
    case .noSpeechDetected:
      "Vani heard silence or audio below the speech threshold."
    case .modelUnavailable:
      "Download the local English speech model before dictating."
    case .modelDownloadFailed:
      "Check your connection and retry the one-time model download."
    case .modelIntegrityFailed:
      "Vani rejected an unexpected model file. Download a verified copy and retry."
    case .modelLoadFailed:
      "The local model may be incomplete. Retry preparation to repair it."
    case .transcriptionFailed:
      "The recording remains in memory so transcription can be retried."
    case .emptyTranscript:
      "The model returned no text. Try speaking closer to the microphone."
    case .focusChanged:
      "Vani did not type because the focused application changed."
    case .secureTextField:
      "Vani does not record or insert into password and other secure text fields."
    case .insertionFailed:
      "The transcript remains available for retry or manual paste."
    case .insertionUnverified:
      "Vani could not verify insertion, so the transcript remains on the clipboard."
    case .clipboardChanged:
      "Vani did not overwrite newer clipboard content. The transcript remains recoverable."
    case .historyCorrupt:
      "Unreadable history was quarantined. Dictation can continue safely."
    case .operationCancelled:
      "Nothing was inserted."
    case .internalInvariant:
      "The session entered an unexpected state and was safely stopped."
    }
  }

  public var recoveryAction: RecoveryAction {
    switch self {
    case .microphonePermissionDenied: .openMicrophoneSettings
    case .accessibilityPermissionDenied: .openAccessibilitySettings
    case .inputMonitoringPermissionDenied: .openInputMonitoringSettings
    case .modelUnavailable, .modelDownloadFailed, .modelIntegrityFailed, .modelLoadFailed:
      .retryPreparation
    case .transcriptionFailed: .retryTranscription
    case .insertionFailed: .retryInsertion
    case .focusChanged, .insertionUnverified, .clipboardChanged: .copyTranscript
    case .audioDeviceUnavailable, .audioCaptureFailed, .recordingTooShort,
      .recordingTooLong, .noSpeechDetected, .emptyTranscript, .internalInvariant:
      .startAgain
    case .secureTextField: .startAgain
    case .unsupportedHardware, .historyCorrupt, .operationCancelled: .none
    }
  }

  public var dismissesAutomatically: Bool {
    self == .recordingTooShort || self == .noSpeechDetected
  }
}

extension VaniFailure: LocalizedError {
  public var errorDescription: String? { title }
  public var recoverySuggestion: String? { message }
}
