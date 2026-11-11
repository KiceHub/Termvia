import SwiftUI

/// Keep the system link's weight and shape, opening a gap through its joining
/// section. SF Symbols has no link.slash on the supported SDK.
struct BrokenLinkSymbol: View {
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "link").resizable().scaledToFit().frame(width: size, height: size)
            .mask { BrokenLinkMask().fill(.white, style: FillStyle(eoFill: true)) }
    }
}
struct BrokenLinkMask: Shape {
    func path(in rect: CGRect) -> Path {
        let gap = min(rect.width, rect.height) * 0.12
        var path = Path(rect)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY - gap))
        path.addLine(to: CGPoint(x: rect.maxX + gap, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + gap))
        path.addLine(to: CGPoint(x: rect.minX - gap, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
