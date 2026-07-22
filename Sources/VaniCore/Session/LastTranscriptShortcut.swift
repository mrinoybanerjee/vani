import CoreGraphics
import Foundation

public enum LastTranscriptShortcutAction: Sendable, Equatable {
  case paste
  case copy
}

public enum LastTranscriptShortcutResolver {
  public static func action(
    keyCode: Int64,
    modifierFlagsRawValue: UInt64,
    isRepeat: Bool
  ) -> LastTranscriptShortcutAction? {
    guard !isRepeat else { return nil }
    guard keyCode == 8 || keyCode == 9 else { return nil }

    let flags = CGEventFlags(rawValue: modifierFlagsRawValue)
    guard flags.contains(.maskCommand), flags.contains(.maskControl) else {
      return nil
    }
    guard !flags.contains(.maskShift), !flags.contains(.maskAlternate) else {
      return nil
    }

    return switch keyCode {
    case 9: .paste
    case 8: .copy
    default: nil
    }
  }
}
