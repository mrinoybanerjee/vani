import Foundation

public struct TextTarget: Sendable, Equatable {
  public let processIdentifier: Int32
  public let bundleIdentifier: String?
  public let focusedElementIdentifier: UInt?

  public init(
    processIdentifier: Int32,
    bundleIdentifier: String? = nil,
    focusedElementIdentifier: UInt? = nil
  ) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.focusedElementIdentifier = focusedElementIdentifier
  }
}

public enum TextInsertionResult: Sendable, Equatable {
  case verified
  case verifiedClipboardPreserved
  case unverifiedClipboardPreserved
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
