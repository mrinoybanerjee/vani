import SwiftUI
import VaniCore

struct VaniStatusMark: View {
  let phase: SessionPhase
  var size: CGFloat = 18

  var body: some View {
    ZStack {
      VaniBubbleOutline()
        .stroke(
          style: StrokeStyle(
            lineWidth: max(1.2, size * 0.075),
            lineCap: .round,
            lineJoin: .round
          )
        )

      HStack(alignment: .center, spacing: max(0.7, size * 0.04)) {
        ForEach(0..<barHeights.count, id: \.self) { index in
          Capsule()
            .frame(
              width: max(1, size * 0.065),
              height: size * barHeights[index]
            )
        }
      }
      .frame(width: size * 0.5, height: size * 0.42)
      .offset(y: -size * 0.08)
    }
    .frame(width: size, height: size)
    .opacity(phase == .disabled ? 0.45 : 1)
  }

  private var barHeights: [CGFloat] {
    switch phase {
    case .listening:
      [0.2, 0.38, 0.28, 0.42, 0.24]
    case .preparing, .transcribing, .inserting:
      [0.18, 0.24, 0.3, 0.38, 0.42]
    case .recoverableError:
      [0.4, 0.26, 0.18, 0.26, 0.18]
    case .setup, .ready, .disabled:
      [0.18, 0.3, 0.42, 0.3, 0.18]
    }
  }
}

private struct VaniBubbleOutline: Shape {
  func path(in rect: CGRect) -> Path {
    let inset = rect.width * 0.08
    let tailHeight = rect.height * 0.18
    let bubbleRect = CGRect(
      x: rect.minX + inset,
      y: rect.minY + inset,
      width: rect.width - inset * 2,
      height: rect.height - tailHeight - inset * 2
    )
    var path = Path(
      roundedRect: bubbleRect,
      cornerRadius: min(bubbleRect.width, bubbleRect.height) * 0.34
    )
    path.move(
      to: CGPoint(
        x: bubbleRect.minX + bubbleRect.width * 0.27,
        y: bubbleRect.maxY - inset * 0.15
      )
    )
    path.addLine(
      to: CGPoint(
        x: bubbleRect.minX + bubbleRect.width * 0.2,
        y: rect.maxY - inset * 0.35
      )
    )
    path.addLine(
      to: CGPoint(
        x: bubbleRect.minX + bubbleRect.width * 0.43,
        y: bubbleRect.maxY - inset * 0.15
      )
    )
    return path
  }
}
