import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import VaniCore

/// Real-hardware checks. They switch the system default input between two microphones
/// (restoring the original afterwards), so they run only with VANI_RUN_HARDWARE_TESTS=1 on
/// a Mac with two inputs, where the test process has Microphone (and, for meetings,
/// Screen & System Audio Recording) access. They never request permission.
enum HardwareFixture {
  static var enabled: Bool {
    ProcessInfo.processInfo.environment["VANI_RUN_HARDWARE_TESTS"] == "1"
  }

  static func inputDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
    return devices.filter { device in
      var streams = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
      var streamSize: UInt32 = 0
      AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize)
      return streamSize > 0
    }
  }

  @discardableResult
  static func setDefaultInput(_ device: AudioDeviceID) -> Bool {
    var device = device
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
      UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr
  }
}

@Test(.enabled(if: HardwareFixture.enabled, "Switches real microphones"))
func dictationContinuesAcrossARealMicrophoneSwitch() async throws {
  try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
  let original = try #require(AVAudioEngineCapture.defaultInputDeviceID())
  let other = try #require(HardwareFixture.inputDevices().first { $0 != original })
  defer { HardwareFixture.setDefaultInput(original) }

  let capture = AVAudioEngineCapture()
  try await capture.start()
  try await Task.sleep(for: .seconds(2))
  #expect(HardwareFixture.setDefaultInput(other))
  try await Task.sleep(for: .milliseconds(300))
  #expect(await capture.continueOnCurrentInput())
  try await Task.sleep(for: .seconds(2))
  #expect(HardwareFixture.setDefaultInput(original))
  try await Task.sleep(for: .milliseconds(300))
  #expect(await capture.continueOnCurrentInput())
  try await Task.sleep(for: .seconds(2))
  let audio = try await capture.stop()

  print("VANI_HW_DICTATION_SECONDS=\(audio.duration)")
  // Six seconds recorded across two switches; each switch may cost a few hundred ms.
  #expect(audio.duration > 4.5)
  #expect(audio.duration < 7.0)
}

@Test(.enabled(if: HardwareFixture.enabled, "Captures real meeting audio and switches microphones"))
func meetingCaptureHearsMacAudioAndSurvivesAMicrophoneSwitch() async throws {
  guard #available(macOS 15.0, *) else { return }
  try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
  try #require(CGPreflightScreenCaptureAccess())
  let original = try #require(AVAudioEngineCapture.defaultInputDeviceID())
  let other = try #require(HardwareFixture.inputDevices().first { $0 != original })
  defer { HardwareFixture.setDefaultInput(original) }
  let fixture = try #require(
    Bundle.module.url(
      forResource: "librispeech-1272-128104-0000", withExtension: "wav",
      subdirectory: "Fixtures"))
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let failures = FailureLog()
  let capture = await MeetingAudioCapture()
  try await capture.start(
    directory: directory, onChunk: {}, onFailure: { failures.append($0) })
  // Real Mac audio: play the speech fixture through the speakers, switching mics midway.
  let player = Process()
  player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
  player.arguments = [fixture.path]
  try player.run()
  try await Task.sleep(for: .seconds(3))
  #expect(HardwareFixture.setDefaultInput(other))
  player.waitUntilExit()
  try await Task.sleep(for: .seconds(3))
  #expect(await capture.isCapturing)
  try await capture.stop()

  #expect(failures.messages.isEmpty)
  let chunks = try FileManager.default.contentsOfDirectory(
    at: directory, includingPropertiesForKeys: nil
  ).filter { $0.pathExtension == "vani-audio" }
  let decoded = try chunks.map {
    try PropertyListDecoder().decode(MeetingAudioChunk.self, from: Data(contentsOf: $0))
  }
  #expect(decoded.contains { $0.source == .system })
  #expect(decoded.contains { $0.source == .microphone })

  let recognizer = FluidAudioSpeechRecognizer()
  try await recognizer.prepare { _ in }
  var heard = ""
  for chunk in decoded.filter({ $0.source == .system }).sorted(by: { $0.offset < $1.offset }) {
    heard += try await recognizer.transcribe(chunk.audio()).text + " "
  }
  print("VANI_HW_MEETING_SYSTEM_TEXT=\(heard)")
  #expect(heard.lowercased().contains("quilter"))
}

final class FailureLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  func append(_ message: String) { lock.withLock { stored.append(message) } }
  var messages: [String] { lock.withLock { stored } }
}
