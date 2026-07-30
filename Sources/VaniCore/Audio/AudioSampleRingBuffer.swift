import AVFoundation
import Darwin
import os

final class AudioSampleRingBuffer: Sendable {
  struct Snapshot: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let overflowed: Bool
  }

  // Samples are mutated only while `state` is locked; drained pages are immutable.
  private final class Page: @unchecked Sendable {
    var samples: [Float]

    init(capacity: Int) {
      samples = Array(repeating: 0, count: capacity)
    }
  }

  private struct State: Sendable {
    var chunks: [Page] = []
    var count = 0
    var reservedCapacity = 0
    var maximumCapacity = 0
    var chunkCapacity = 0
    var sampleRate: Double = 0
    var overflowed = false
    var generation: UInt64 = 0
  }

  private struct FrozenState: Sendable {
    let chunks: [Page]
    let count: Int
    let sampleRate: Double
    let overflowed: Bool
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  @discardableResult
  func reset(
    capacity: Int,
    maximumCapacity: Int? = nil,
    chunkCapacity: Int? = nil,
    sampleRate: Double
  ) -> UInt64 {
    let maximumCapacity = max(1, maximumCapacity ?? capacity)
    let chunkCapacity = min(maximumCapacity, max(1, chunkCapacity ?? capacity))
    let requestedCapacity = min(maximumCapacity, max(1, capacity))
    let roundedCapacity = min(
      maximumCapacity,
      ((requestedCapacity + chunkCapacity - 1) / chunkCapacity) * chunkCapacity
    )
    var chunks: [Page] = []
    var remainingCapacity = roundedCapacity
    while remainingCapacity > 0 {
      let size = min(chunkCapacity, remainingCapacity)
      chunks.append(Page(capacity: size))
      remainingCapacity -= size
    }
    let preparedChunks = chunks

    return state.withLock { state in
      state.generation &+= 1
      state.chunks = preparedChunks
      state.count = 0
      state.reservedCapacity = roundedCapacity
      state.maximumCapacity = maximumCapacity
      state.chunkCapacity = chunkCapacity
      state.sampleRate = sampleRate
      state.overflowed = false
      return state.generation
    }
  }

  @discardableResult
  func reserveNextChunk(generation: UInt64) -> Bool {
    let reservation = state.withLock { state -> (reservedCapacity: Int, size: Int)? in
      guard
        state.generation == generation,
        state.reservedCapacity < state.maximumCapacity
      else {
        return nil
      }
      return (
        state.reservedCapacity,
        min(state.chunkCapacity, state.maximumCapacity - state.reservedCapacity)
      )
    }
    guard let reservation else { return false }

    let chunk = Page(capacity: reservation.size)
    return state.withLock { state in
      guard
        state.generation == generation,
        state.reservedCapacity == reservation.reservedCapacity
      else {
        return false
      }
      state.chunks.append(chunk)
      state.reservedCapacity += chunk.samples.count
      return true
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard let channel = buffer.floatChannelData?.pointee else { return }
    let incomingCount = Int(buffer.frameLength)
    guard incomingCount > 0 else { return }
    let channelAddress = UInt(bitPattern: channel)

    state.withLock { state in
      let writableCount = min(incomingCount, state.reservedCapacity - state.count)
      guard writableCount > 0 else {
        state.overflowed = true
        return
      }

      var copiedCount = 0
      while copiedCount < writableCount {
        let chunkIndex = state.count / state.chunkCapacity
        let chunkOffset = state.count % state.chunkCapacity
        guard chunkIndex < state.chunks.count else { break }

        let copyCount = min(
          writableCount - copiedCount,
          state.chunks[chunkIndex].samples.count - chunkOffset
        )
        guard copyCount > 0 else { break }
        let sourceOffset = copiedCount * MemoryLayout<Float>.stride
        let destinationOffset = chunkOffset * MemoryLayout<Float>.stride

        state.chunks[chunkIndex].samples.withUnsafeMutableBytes { destination in
          guard
            let destinationAddress = destination.baseAddress?.advanced(
              by: destinationOffset
            ),
            let sourceAddress = UnsafeRawPointer(bitPattern: channelAddress)?.advanced(
              by: sourceOffset
            )
          else {
            return
          }
          memcpy(
            destinationAddress,
            sourceAddress,
            copyCount * MemoryLayout<Float>.stride
          )
        }
        state.count += copyCount
        copiedCount += copyCount
      }

      if copiedCount < incomingCount {
        state.overflowed = true
      }
    }
  }

  func snapshot() -> Snapshot {
    state.withLock { state in
      Self.flatten(
        FrozenState(
          chunks: state.chunks,
          count: state.count,
          sampleRate: state.sampleRate,
          overflowed: state.overflowed
        )
      )
    }
  }

  func drain() -> Snapshot {
    let frozen = state.withLock { state in
      let frozen = FrozenState(
        chunks: state.chunks,
        count: state.count,
        sampleRate: state.sampleRate,
        overflowed: state.overflowed
      )
      state.generation &+= 1
      state.chunks = []
      state.count = 0
      state.reservedCapacity = 0
      state.maximumCapacity = 0
      state.chunkCapacity = 0
      state.sampleRate = 0
      state.overflowed = false
      return frozen
    }
    return Self.flatten(frozen)
  }

  func clear() {
    state.withLock { state in
      state.generation &+= 1
      state.chunks = []
      state.count = 0
      state.reservedCapacity = 0
      state.maximumCapacity = 0
      state.chunkCapacity = 0
      state.sampleRate = 0
      state.overflowed = false
    }
  }

  private static func flatten(_ frozen: FrozenState) -> Snapshot {
    var samples = Array(repeating: Float.zero, count: frozen.count)
    samples.withUnsafeMutableBytes { destination in
      guard let destinationBaseAddress = destination.baseAddress else { return }
      var copiedCount = 0
      for chunk in frozen.chunks {
        let copyCount = min(chunk.samples.count, frozen.count - copiedCount)
        guard copyCount > 0 else { break }
        chunk.samples.withUnsafeBytes { source in
          guard let sourceAddress = source.baseAddress else { return }
          memcpy(
            destinationBaseAddress.advanced(
              by: copiedCount * MemoryLayout<Float>.stride
            ),
            sourceAddress,
            copyCount * MemoryLayout<Float>.stride
          )
        }
        copiedCount += copyCount
      }
    }
    return Snapshot(
      samples: samples,
      sampleRate: frozen.sampleRate,
      overflowed: frozen.overflowed
    )
  }
}
