import Foundation

public struct TextTarget: Sendable, Equatable {
  public let processIdentifier: Int32
  public let bundleIdentifier: String?

  public init(processIdentifier: Int32, bundleIdentifier: String? = nil) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
  }
}

public enum TextInsertionResult: Sendable, Equatable {
  case verified
  case manualPasteRequired
}

@MainActor
public protocol FocusProviding: Sendable {
  func currentTarget() -> TextTarget?
}

@MainActor
public protocol TextInserting: Sendable {
  func insert(_ text: String, into target: TextTarget?) async throws -> TextInsertionResult
  func copyForManualPaste(_ text: String) throws
}
