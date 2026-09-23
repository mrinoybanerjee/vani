import AVFoundation
import CoreML
import FluidAudio
import Foundation

// Usage: AsrBench <manifest.tsv> <output.tsv>
// manifest rows: id \t path1|path2|... (concatenated with 0.3 s silence)
func load16k(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let format = file.processingFormat
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
  try file.read(into: buffer)
  let channel = buffer.floatChannelData!.pointee
  let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  precondition(format.sampleRate == 16_000, "expected 16 kHz")
  return samples
}

let args = CommandLine.arguments
let manifest = try String(contentsOfFile: args[1], encoding: .utf8)
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuAndNeuralEngine
let mode = ProcessInfo.processInfo.environment["ASR_MODEL"] ?? "v2"
var manager: AsrManager?
var unified: UnifiedAsrManager?
var layers = 2
if mode == "v2" {
  let directory = AsrModels.defaultCacheDirectory(for: .v2)
  let models = try await AsrModels.load(from: directory, configuration: configuration, version: .v2)
  manager = AsrManager(config: .default, models: models)
  layers = await manager!.decoderLayerCount
} else {
  let precision: UnifiedEncoderPrecision = mode == "unified-fp16" ? .fp16 : .int8
  let u = UnifiedAsrManager(configuration: configuration, encoderPrecision: precision)
  try await u.loadModels(to: URL(fileURLWithPath: CommandLine.arguments[3]), configuration: configuration)
  unified = u
}
var out = ""
var audioSeconds = 0.0
var processing = 0.0
for line in manifest.split(separator: "\n") {
  let parts = line.split(separator: "\t", maxSplits: 1)
  let id = String(parts[0])
  var samples: [Float] = []
  for path in parts[1].split(separator: "|") {
    if !samples.isEmpty { samples += [Float](repeating: 0, count: 4_800) }
    samples += try load16k(URL(fileURLWithPath: String(path)))
  }
  let start = Date()
  let text: String
  if let manager {
    var state = try TdtDecoderState(decoderLayers: layers)
    text = try await manager.transcribe(samples, decoderState: &state).text
  } else {
    text = try await unified!.transcribe(samples)
    try await unified!.reset()
  }
  processing += Date().timeIntervalSince(start)
  audioSeconds += Double(samples.count) / 16_000
  out += "\(id)\t\(text.replacingOccurrences(of: "\n", with: " "))\n"
}
try out.write(toFile: args[2], atomically: true, encoding: .utf8)
print("audio_seconds=\(audioSeconds) processing_seconds=\(processing) rtfx=\(audioSeconds / processing)")
