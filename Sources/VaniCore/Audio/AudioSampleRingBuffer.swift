import AVFoundation
import Darwin
import Foundation
import os

final class AudioSampleRingBuffer: Sendable {
  struct Snapshot: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let overflowed: Bool
  }

  private struct State: Sendable {
    var storage: [Float] = []
    var count = 0
    var sampleRate: Double = 0
    var overflowed = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func reset(capacity: Int, sampleRate: Double) {
    state.withLock { state in
      state.storage = Array(repeating: 0, count: max(1, capacity))
      state.count = 0
      state.sampleRate = sampleRate
      state.overflowed = false
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard let channel = buffer.floatChannelData?.pointee else { return }
    let incomingCount = Int(buffer.frameLength)
    guard incomingCount > 0 else { return }
    let channelAddress = UInt(bitPattern: channel)

    state.withLock { state in
      let writableCount = min(incomingCount, state.storage.count - state.count)
      guard writableCount > 0 else {
        state.overflowed = true
        return
      }

      state.storage.withUnsafeMutableBytes { destination in
        guard
          let destinationAddress = destination.baseAddress?.advanced(
            by: state.count * MemoryLayout<Float>.stride
          ), let sourceAddress = UnsafeRawPointer(bitPattern: channelAddress)
        else {
          return
        }
        memcpy(
          destinationAddress,
          sourceAddress,
          writableCount * MemoryLayout<Float>.stride
        )
      }
      state.count += writableCount
      if writableCount < incomingCount {
        state.overflowed = true
      }
    }
  }

  func snapshot() -> Snapshot {
    state.withLock { state in
      Snapshot(
        samples: Array(state.storage.prefix(state.count)),
        sampleRate: state.sampleRate,
        overflowed: state.overflowed
      )
    }
  }
}
