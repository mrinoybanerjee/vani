import AppKit

@MainActor
public final class SystemFocusProvider: FocusProviding {
  public init() {}

  public func currentTarget() -> TextTarget? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    return TextTarget(
      processIdentifier: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier
    )
  }
}
