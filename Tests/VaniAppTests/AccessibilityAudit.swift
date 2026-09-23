import AppKit
import Testing

/// One exposed accessibility element, captured as VoiceOver would query it.
struct AccessibilityNode {
  let role: String
  let subrole: String?
  let roleDescription: String?
  let label: String?
  let title: String?
  /// Text of a linked title element (AXTitleUIElement), which VoiceOver speaks as the name.
  let titleElement: String?
  let value: String?
  let placeholder: String?
  let help: String?
  let identifier: String?
  let selected: Bool
  let enabled: Bool
  let isElement: Bool
  let frame: NSRect
  let depth: Int
  let children: [AccessibilityNode]

  /// What VoiceOver speaks as the element's name.
  var name: String? {
    for candidate in [label, title, titleElement, placeholder] {
      if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return candidate
      }
    }
    return nil
  }

  var flattened: [AccessibilityNode] { [self] + children.flatMap(\.flattened) }
}

/// What a surface must expose beyond the generic rules.
struct AuditExpectations {
  /// Text that must be exposed as a heading.
  var headings: [String] = []
  /// Names that must not be reachable, such as controls of a hidden workspace section.
  var absent: [String] = []
  /// Elements that must report selected (or on) state.
  var selected: [String] = []
  /// Elements that must be present and report unselected state.
  var unselected: [String] = []
  /// Names that must be exposed.
  var named: [String] = []
  /// Values that must be exposed by the named element, such as progress.
  var values: [String: String] = [:]
}

/// Walks and checks the NSAccessibility hierarchy of a native window.
@MainActor
enum AccessibilityAudit {
  static let interactiveRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
    "AXTextArea", "AXSlider", "AXDisclosureTriangle", "AXLink", "AXComboBox", "AXIncrementor",
    "AXSearchField",
  ]
  private static let windowChrome: Set<String> = [
    "AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton",
  ]

  /// Every element VoiceOver can reach, without the window's title-bar buttons.
  static func content(of root: AccessibilityNode) -> [AccessibilityNode] {
    func walk(_ node: AccessibilityNode) -> [AccessibilityNode] {
      if let subrole = node.subrole, windowChrome.contains(subrole) { return [] }
      // Unlabelled role-less nodes are AppKit plumbing (reparenting proxies) VoiceOver skips.
      if node.role == "AXUnknown", spoken(node) == nil { return [] }
      return [node] + node.children.flatMap(walk)
    }
    return walk(root)
  }

  static func isHeading(_ node: AccessibilityNode) -> Bool {
    node.role == "AXHeading" || node.subrole == "AXHeading"
      || node.roleDescription == "heading"
  }

  /// What VoiceOver speaks for a node, including static text values.
  static func spoken(_ node: AccessibilityNode) -> String? {
    node.name ?? node.value
  }

  static func findings(in root: AccessibilityNode, _ expect: AuditExpectations) -> [String] {
    let nodes = content(of: root)
    var findings: [String] = []
    var interactiveNames: [String: Int] = [:]
    for node in nodes {
      let describe = "\(node.role) \(spoken(node).map { "\"\($0)\"" } ?? "(unnamed)")"
      if interactiveRoles.contains(node.role) {
        if let name = node.name {
          interactiveNames[name, default: 0] += 1
        } else {
          findings.append("interactive element has no spoken name: \(describe)")
        }
      }
      switch node.role {
      case "AXTextField", "AXTextArea":
        // A placeholder disappears once the field has text, leaving the field unnamed.
        if [node.label, node.title, node.titleElement].allSatisfy({ $0?.isEmpty ?? true }) {
          findings.append("text field is named only by its placeholder: \(describe)")
        }
      case "AXUnknown":
        findings.append(
          "labelled element has no role (add a trait such as static text): \(describe)")
      case "AXImage":
        findings.append("image exposed to VoiceOver (hide if decorative): \(describe)")
      case "AXCheckBox", "AXRadioButton":
        if node.value != "0" && node.value != "1" {
          findings.append("toggle does not expose on/off value: \(describe)")
        }
      case "AXStaticText":
        if spoken(node)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
          findings.append("empty text element")
        }
      default: break
      }
    }
    for (name, count) in interactiveNames where count > 1 {
      findings.append("\(count) controls share the name \"\(name)\"; disambiguate them")
    }
    for heading in expect.headings
    where !nodes.contains(where: { isHeading($0) && spoken($0) == heading }) {
      findings.append("missing heading \"\(heading)\"")
    }
    for name in expect.absent
    where nodes.contains(where: { spoken($0) == name || $0.placeholder == name }) {
      findings.append("hidden content is reachable: \"\(name)\"")
    }
    func isOn(_ node: AccessibilityNode) -> Bool {
      node.selected || (node.role == "AXRadioButton" && node.value == "1")
    }
    for name in expect.selected where !nodes.contains(where: { $0.name == name && isOn($0) }) {
      findings.append("\"\(name)\" does not expose selected state")
    }
    for name in expect.unselected
    where !nodes.contains(where: { $0.name == name && !isOn($0) }) {
      findings.append("\"\(name)\" is missing or wrongly reports selected state")
    }
    for name in expect.named where !nodes.contains(where: { spoken($0) == name }) {
      findings.append("nothing is exposed with the name \"\(name)\"")
    }
    for (name, value) in expect.values
    where !nodes.contains(where: { $0.name == name && $0.value == value }) {
      findings.append("\"\(name)\" does not expose the value \"\(value)\"")
    }
    return findings
  }

  /// SwiftUI builds its accessibility tree only for an assistive client. Assistive clients ask
  /// the application for this attribute; setting it here affects only the test process.
  static func enableAccessibilityTree() {
    _ = NSApplication.shared.perform(
      NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
      with: "AXEnhancedUserInterface")
  }

  static func tree(of window: NSWindow) -> AccessibilityNode {
    var visited = Set<ObjectIdentifier>()
    return node(window, depth: 0, visited: &visited)
      ?? AccessibilityNode(
        role: "AXWindow", subrole: nil, roleDescription: nil, label: nil, title: window.title,
        titleElement: nil,
        value: nil, placeholder: nil, help: nil, identifier: nil, selected: false, enabled: true,
        isElement: true, frame: .zero, depth: 0, children: [])
  }

  private static func string(_ value: Any?) -> String? {
    switch value {
    case let string as String: string
    case let attributed as NSAttributedString: attributed.string
    case let number as NSNumber: number.stringValue
    case .some(let other): String(describing: other)
    case nil: nil
    }
  }

  /// SwiftUI's accessibility nodes answer the NSAccessibility selectors without declaring the
  /// Swift protocol conformance, so the audit sends the selectors directly, as AppKit does.
  /// Elements such as table rows adopt only the attribute-based API; the audit falls back to it.
  private static let attributes: [String: String] = [
    "accessibilityRole": "AXRole", "accessibilitySubrole": "AXSubrole",
    "accessibilityRoleDescription": "AXRoleDescription", "accessibilityLabel": "AXDescription",
    "accessibilityTitle": "AXTitle", "accessibilityValue": "AXValue",
    "accessibilityPlaceholderValue": "AXPlaceholderValue", "accessibilityHelp": "AXHelp",
    "accessibilityIdentifier": "AXIdentifier", "accessibilityChildren": "AXChildren",
    "accessibilityTitleUIElement": "AXTitleUIElement", "isAccessibilitySelected": "AXSelected",
    "isAccessibilityEnabled": "AXEnabled",
  ]

  private static func object(_ element: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    if element.responds(to: selector) {
      return element.perform(selector)?.takeUnretainedValue()
    }
    let legacy = NSSelectorFromString("accessibilityAttributeValue:")
    guard let attribute = attributes[name], element.responds(to: legacy) else { return nil }
    return element.perform(legacy, with: attribute)?.takeUnretainedValue()
  }

  private static func flag(_ element: NSObject, _ name: String) -> Bool? {
    let selector = NSSelectorFromString(name)
    guard element.responds(to: selector),
      let method = class_getInstanceMethod(type(of: element), selector)
    else { return (object(element, name) as? NSNumber)?.boolValue }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(method_getImplementation(method), to: Getter.self)(element, selector)
  }

  /// VoiceOver names a control from a separate label element when one is linked.
  private static func titleElementText(_ element: NSObject) -> String? {
    guard let title = object(element, "accessibilityTitleUIElement") as? NSObject else {
      return nil
    }
    return string(object(title, "accessibilityValue"))
      ?? string(object(title, "accessibilityLabel"))
  }

  private static func rect(_ element: NSObject) -> NSRect {
    let selector = NSSelectorFromString("accessibilityFrame")
    guard element.responds(to: selector),
      let method = class_getInstanceMethod(type(of: element), selector)
    else { return .zero }
    typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
    return unsafeBitCast(method_getImplementation(method), to: Getter.self)(element, selector)
  }

  private static func node(_ object: Any, depth: Int, visited: inout Set<ObjectIdentifier>)
    -> AccessibilityNode?
  {
    guard let element = object as? NSObject, depth < 60 else { return nil }
    guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
    let rawChildren = Self.object(element, "accessibilityChildren") as? [Any] ?? []
    let children = rawChildren.compactMap { node($0, depth: depth + 1, visited: &visited) }
    return AccessibilityNode(
      role: string(Self.object(element, "accessibilityRole")) ?? "AXUnknown",
      subrole: string(Self.object(element, "accessibilitySubrole")),
      roleDescription: string(Self.object(element, "accessibilityRoleDescription")),
      label: string(Self.object(element, "accessibilityLabel")),
      title: string(Self.object(element, "accessibilityTitle")),
      titleElement: titleElementText(element),
      value: string(Self.object(element, "accessibilityValue")),
      placeholder: string(Self.object(element, "accessibilityPlaceholderValue")),
      help: string(Self.object(element, "accessibilityHelp")),
      identifier: string(Self.object(element, "accessibilityIdentifier")),
      selected: flag(element, "isAccessibilitySelected") ?? false,
      enabled: flag(element, "isAccessibilityEnabled") ?? true,
      isElement: flag(element, "isAccessibilityElement") ?? true,
      frame: rect(element),
      depth: depth,
      children: children)
  }

  /// A readable outline of what VoiceOver would announce for each element.
  static func report(_ root: AccessibilityNode, surface: String) -> String {
    var lines = ["# \(surface)", ""]
    for node in root.flattened {
      var parts = [String(repeating: "  ", count: node.depth) + node.role]
      if let subrole = node.subrole { parts.append("(\(subrole))") }
      if let label = node.label, !label.isEmpty { parts.append("label=\"\(label)\"") }
      if let title = node.title, !title.isEmpty { parts.append("title=\"\(title)\"") }
      if let text = node.titleElement { parts.append("titleElement=\"\(text)\"") }
      if let value = node.value, !value.isEmpty { parts.append("value=\"\(value)\"") }
      if let placeholder = node.placeholder, !placeholder.isEmpty {
        parts.append("placeholder=\"\(placeholder)\"")
      }
      if let help = node.help, !help.isEmpty { parts.append("help=\"\(help)\"") }
      if let description = node.roleDescription { parts.append("[\(description)]") }
      if node.selected { parts.append("{selected}") }
      if !node.enabled { parts.append("{disabled}") }
      if !node.isElement { parts.append("{ignored}") }
      lines.append(parts.joined(separator: " "))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Writes the report when VANI_A11Y_REPORT_DIR is set.
  static func writeReport(_ root: AccessibilityNode, surface: String) throws {
    guard let path = ProcessInfo.processInfo.environment["VANI_A11Y_REPORT_DIR"] else { return }
    let folder = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = surface.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    try report(root, surface: surface).write(
      to: folder.appendingPathComponent(String(name) + ".txt"), atomically: true, encoding: .utf8)
  }
}
