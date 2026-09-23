import CoreAudio
import Foundation

/// Reports changes to the system default input device (for example choosing another
/// microphone in Control Center, or AirPods becoming the input). `AVAudioEngine` does not
/// always report these while its current device keeps working.
public final class DefaultInputObserver: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.mrinoy.vani.default-input")
  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private let listener: AudioObjectPropertyListenerBlock

  /// `onChange` runs on the main actor.
  public init(onChange: @escaping @MainActor @Sendable () -> Void) {
    listener = { _, _ in
      Task { @MainActor in onChange() }
    }
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
  }

  deinit {
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
  }
}
