import AVFoundation
import ApplicationServices

enum PermissionState: String, Equatable {
  case unknown
  case denied
  case granted

  var isGranted: Bool { self == .granted }

  static var microphone: PermissionState {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .granted
    case .denied, .restricted: .denied
    case .notDetermined: .unknown
    @unknown default: .unknown
    }
  }

  static var accessibility: PermissionState {
    AXIsProcessTrusted() ? .granted : .denied
  }

  static var inputMonitoring: PermissionState {
    CGPreflightListenEventAccess() ? .granted : .denied
  }
}
