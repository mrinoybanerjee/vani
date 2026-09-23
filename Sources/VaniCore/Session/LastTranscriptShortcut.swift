import CoreGraphics

public enum LastTranscriptShortcutAction: Sendable, Equatable {
  case paste
  case copy
}

public enum LastTranscriptShortcutResolver {
  public static func action(
    keyCode: Int64,
    modifierFlagsRawValue: UInt64,
    isRepeat: Bool,
    binding: LastTranscriptBinding = .controlCommand
  ) -> LastTranscriptShortcutAction? {
    guard !isRepeat else { return nil }
    guard keyCode == 8 || keyCode == 9 else { return nil }

    let required: CGEventFlags
    switch binding {
    case .controlCommand: required = [.maskControl, .maskCommand]
    case .optionCommand: required = [.maskAlternate, .maskCommand]
    case .controlOption: required = [.maskControl, .maskAlternate]
    case .disabled: return nil
    }
    let chordModifiers: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]
    let flags = CGEventFlags(rawValue: modifierFlagsRawValue).intersection(chordModifiers)
    guard flags == required else { return nil }

    return switch keyCode {
    case 9: .paste
    case 8: .copy
    default: nil
    }
  }
}
