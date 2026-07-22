import AppKit

@MainActor
public final class SystemFocusProvider: FocusProviding {
  public init() {}

  public func currentTarget() -> TextTarget? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    let focusedElement = AccessibilityFocusResolver.focusedElement(
      for: application.processIdentifier
    )
    return TextTarget(
      processIdentifier: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      isSecureTextField: focusedElement.map(AccessibilityFocusResolver.isSecureTextField) ?? false
    )
  }
}
