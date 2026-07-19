import Foundation
import Testing

@testable import VaniCore

@Test
func benchmarkResultsHaveAVersionedRoundTripSchema() throws {
  let result = BenchmarkResult(
    recordedAt: Date(timeIntervalSince1970: 1_000),
    commit: "abc123",
    hardware: "Apple M4",
    operatingSystem: "macOS",
    configuration: "release",
    model: "parakeet-tdt-0.6b-v2",
    metrics: ["cycles": 500, "duration_ms": 125]
  )

  let data = try JSONEncoder().encode(result)
  let decoded = try JSONDecoder().decode(BenchmarkResult.self, from: data)

  #expect(decoded == result)
  #expect(decoded.schemaVersion == 1)
}
