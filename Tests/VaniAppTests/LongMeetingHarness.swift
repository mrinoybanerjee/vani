import Darwin
import Foundation

@testable import VaniCore

// Test-only harness for the opt-in long-meeting runs in LongMeetingTests. Nothing here is
// linked into the app: it drives the real `MeetingStreamOutput` and `MeetingModel` with
// synthetic ScreenCaptureKit-shaped callbacks, so no microphone or screen permission is needed.

/// SplitMix64: deterministic across runs and machines.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
  mutating func uniform(_ range: ClosedRange<Double>) -> Double {
    range.lowerBound + unit() * (range.upperBound - range.lowerBound)
  }
}

/// Resident memory of this process, sampled on a background thread (mach `task_info`).
final class ResidentMemorySampler: @unchecked Sendable {
  private let lock = NSLock()
  private var peak: UInt64 = 0
  private var running = true

  static func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
  }

  init() {
    peak = Self.residentBytes()
    Thread.detachNewThread { [self] in
      while isRunning {
        record(Self.residentBytes())
        usleep(50_000)
      }
    }
  }

  private var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  private func record(_ bytes: UInt64) {
    lock.lock()
    peak = max(peak, bytes)
    lock.unlock()
  }

  /// Stops sampling and returns the peak in bytes.
  func stop() -> UInt64 {
    record(Self.residentBytes())
    lock.lock()
    defer { lock.unlock() }
    running = false
    return peak
  }
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
}

func mebibytes(_ bytes: UInt64) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }

/// Hands ScreenCaptureKit-shaped buffers to the production `MeetingStreamOutput`.
@available(macOS 15.0, *)
@MainActor
final class SyntheticMeetingCapture: MeetingAudioRecording {
  private(set) var output: MeetingStreamOutput?
  private(set) var directory: URL?
  var isCapturing: Bool { output != nil }

  func start(
    directory: URL, onChunk: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) throws {
    self.directory = directory
    output = MeetingStreamOutput(
      directory: directory, onChunk: onChunk, onFailure: onFailure,
      onStopped: { _, message in onFailure(message) })
  }

  /// The producer has finished before `stop`, as ScreenCaptureKit's queue drains before `finish`.
  func stop() throws {
    try output?.finish()
    output = nil
  }
}

/// One capture source's callback stream: fixed-size buffers, a sample-rate schedule, optional
/// timestamp jitter and delivery gaps. `signal` fills a buffer that starts at a true time.
struct CallbackStream {
  let source: MeetingAudioSource
  let frames: Int
  let rate: (TimeInterval) -> Double
  let jitter: TimeInterval
  /// Intervals during which no callbacks arrive (audio in them is lost, as with a real gap).
  let gaps: [(start: TimeInterval, end: TimeInterval)]
  let end: TimeInterval
  let signal: (inout [Float], TimeInterval, Double) -> Void
  private(set) var time: TimeInterval = 0
  private(set) var callbacks = 0

  init(
    source: MeetingAudioSource, frames: Int,
    rate: @escaping (TimeInterval) -> Double = { _ in 48_000 },
    jitter: TimeInterval = 0, gaps: [(start: TimeInterval, end: TimeInterval)] = [],
    end: TimeInterval, signal: @escaping (inout [Float], TimeInterval, Double) -> Void
  ) {
    self.source = source
    self.frames = frames
    self.rate = rate
    self.jitter = jitter
    self.gaps = gaps
    self.end = end
    self.signal = signal
  }

  var finished: Bool { time >= end }

  /// The next callback: samples, rate and presentation offset (true time plus jitter).
  mutating func next(_ random: inout SeededGenerator) -> (
    samples: [Float], rate: Double, offset: TimeInterval
  )? {
    while let gap = gaps.first(where: { time >= $0.start && time < $0.end }) { time = gap.end }
    guard time < end else { return nil }
    let rate = rate(time)
    var samples = [Float](repeating: 0, count: frames)
    signal(&samples, time, rate)
    let offset = max(0, time + (jitter > 0 ? random.uniform(-jitter...jitter) : 0))
    time += Double(frames) / rate
    callbacks += 1
    return (samples, rate, offset)
  }
}

/// Delivers both streams in presentation order on the calling thread, as ScreenCaptureKit's
/// serial queue does, and returns the number of callbacks. `periodically` runs on the same
/// thread every 100,000 callbacks.
@available(macOS 15.0, *)
func deliver(
  _ streams: inout [CallbackStream], to output: MeetingStreamOutput, seed: UInt64,
  periodically: () -> Void = {}
) throws -> Int {
  var random = SeededGenerator(seed: seed)
  var count = 0
  while let index = streams.indices.filter({ !streams[$0].finished }).min(by: {
    streams[$0].time < streams[$1].time
  }) {
    guard let buffer = streams[index].next(&random) else { continue }
    try output.append(
      buffer.samples, rate: buffer.rate, offset: buffer.offset, source: streams[index].source)
    count += 1
    if count % 100_000 == 0 { periodically() }
  }
  return count
}

/// Every chunk file in a meeting folder, decoded.
func savedChunks(in directory: URL) throws -> [MeetingAudioChunk] {
  try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == MeetingAudioChunk.fileExtension }
    .map { try PropertyListDecoder().decode(MeetingAudioChunk.self, from: Data(contentsOf: $0)) }
}

// MARK: - Word error rate

enum WordErrorRate {
  private static let numerals = [
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six",
    "7": "seven", "8": "eight", "9": "nine", "10": "ten",
  ]

  /// Same normalization as Benchmarks/wer.py: lowercase, hyphens and punctuation to spaces,
  /// apostrophes removed, single numerals spelled out.
  static func words(_ text: String) -> [String] {
    let lowered = text.lowercased().replacingOccurrences(of: "-", with: " ")
    let kept = String(
      String.UnicodeScalarView(
        lowered.unicodeScalars.compactMap {
          if $0 == "'" || $0 == "’" { return nil }
          return ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : " "
        }))
    return kept.split(separator: " ").map { numerals[String($0)] ?? String($0) }
  }

  /// Word-level edit distance and the number of reference words matched in the alignment.
  static func align(_ reference: [String], _ hypothesis: [String]) -> (errors: Int, matched: Int) {
    guard !reference.isEmpty else { return (hypothesis.count, 0) }
    var previous = [(Int, Int)](repeating: (0, 0), count: hypothesis.count + 1)
    for j in 0...hypothesis.count { previous[j] = (j, 0) }
    for i in 1...reference.count {
      var current = [(Int, Int)](repeating: (i, 0), count: hypothesis.count + 1)
      for j in stride(from: 1, through: hypothesis.count, by: 1) {
        let same = reference[i - 1] == hypothesis[j - 1]
        var best = (previous[j - 1].0 + (same ? 0 : 1), previous[j - 1].1 + (same ? 1 : 0))
        for other in [(previous[j].0 + 1, previous[j].1), (current[j - 1].0 + 1, current[j - 1].1)]
        where other.0 < best.0 || (other.0 == best.0 && other.1 > best.1) {
          best = other
        }
        current[j] = best
      }
      previous = current
    }
    return previous[hypothesis.count]
  }

  static func rate(reference: String, hypothesis: String) -> (rate: Double, errors: Int, words: Int)
  {
    let reference = words(reference)
    let errors = align(reference, words(hypothesis)).errors
    return (Double(errors) / Double(max(1, reference.count)), errors, reference.count)
  }
}
