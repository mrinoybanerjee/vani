import AppKit
import ApplicationServices

@MainActor
public final class SystemFocusProvider: FocusProviding {
  public init() {}

  public func currentTarget() -> TextTarget? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    return TextTarget(
      processIdentifier: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      focusedElementIdentifier: focusedElementIdentifier()
    )
  }

  private func focusedElementIdentifier() -> UInt? {
    let systemWide = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedUIElementAttribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return CFHash(value)
  }
}
