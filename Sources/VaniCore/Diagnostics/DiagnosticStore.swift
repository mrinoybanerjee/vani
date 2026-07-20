import Foundation

public actor DiagnosticStore {
  public static let shared = DiagnosticStore()

  private let capacity: Int
  private var events: [DiagnosticEvent] = []

  public init(capacity: Int = 200) {
    self.capacity = max(1, capacity)
  }

  public func record(_ event: DiagnosticEvent) {
    events.append(event)
    if events.count > capacity {
      events.removeFirst(events.count - capacity)
    }
  }

  public func snapshot() -> [DiagnosticEvent] {
    events
  }

  public func clear() {
    events.removeAll(keepingCapacity: true)
  }
}
