import SwiftUI

struct AppIconView: View {
    let size: CGFloat
    
    init(size: CGFloat = 1024) {
        self.size = size
    }

    // Match paywall color
    private let electricBlue = Color(red: 0.0, green: 0.7, blue: 1.0)

    // Tuning (adjust if you want)
    private let baseSize: CGFloat = 1024
    private let baseStroke: CGFloat = 22           // ~80% of your current “feel”
    private let basePaperInset: CGFloat = 210      // controls paper size (more inset = smaller paper)
    private let baseFoldSize: CGFloat = 120        // smaller fold corner
    private let baseDashInset: CGFloat = 285       // makes dash not touch paper edges
    private let dashYRatio: CGFloat = 0.50         // 0.50 = center

    var body: some View {
        GeometryReader { geo in
            let renderSize = min(geo.size.width, geo.size.height)
            let scale = renderSize / baseSize
            let stroke = baseStroke * scale
            let paperInset = basePaperInset * scale
            let foldSize = baseFoldSize * scale
            let dashInset = baseDashInset * scale
            let dashY = renderSize * dashYRatio

            ZStack {
                Color.black

                // Ambient glow behind everything (subtle)
                Circle()
                    .fill(electricBlue.opacity(0.18))
                    .frame(width: renderSize * 0.75, height: renderSize * 0.75)
                    .blur(radius: renderSize * 0.10)

                // Document outline (custom, smaller fold)
                DocShape(inset: paperInset, fold: foldSize)
                    .stroke(
                        electricBlue,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: electricBlue.opacity(0.55), radius: 55)

                // Fold inner crease (same stroke, lighter)
                FoldCreaseShape(inset: paperInset, fold: foldSize)
                    .stroke(
                        electricBlue.opacity(0.85),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                    )
                    .opacity(0.35)

                // Scan dash (same stroke as file, DOES NOT touch edges)
                ScanDashShape(y: dashY, inset: dashInset)
                    .stroke(
                        electricBlue,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                    )
                    // Blue glow
                    .shadow(color: electricBlue.opacity(1.0), radius: 40)
                    .shadow(color: electricBlue.opacity(0.65), radius: 80)
            }
            .frame(width: renderSize, height: renderSize)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
}

// MARK: - Shapes

/// Document outline with a smaller top-right fold.
private struct DocShape: Shape {
    let inset: CGFloat
    let fold: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let f = min(fold, min(r.width, r.height) * 0.28)

        let x0 = r.minX
        let y0 = r.minY
        let x1 = r.maxX
        let y1 = r.maxY

        var p = Path()
        p.move(to: CGPoint(x: x0, y: y0))                 // top-left
        p.addLine(to: CGPoint(x: x1 - f, y: y0))          // top to fold start
        p.addLine(to: CGPoint(x: x1, y: y0 + f))          // fold diagonal
        p.addLine(to: CGPoint(x: x1, y: y1))              // right edge
        p.addLine(to: CGPoint(x: x0, y: y1))              // bottom edge
        p.addLine(to: CGPoint(x: x0, y: y0))              // left edge
        p.closeSubpath()
        return p
    }
}

/// Inner fold crease (keeps fold looking “small” and clean)
private struct FoldCreaseShape: Shape {
    let inset: CGFloat
    let fold: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let f = min(fold, min(r.width, r.height) * 0.28)

        let x1 = r.maxX
        let y0 = r.minY

        var p = Path()
        p.move(to: CGPoint(x: x1 - f, y: y0))
        p.addLine(to: CGPoint(x: x1 - f, y: y0 + f))
        p.addLine(to: CGPoint(x: x1, y: y0 + f))
        return p
    }
}

/// Scan line dash across the paper, not touching edges.
private struct ScanDashShape: Shape {
    let y: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: inset, y: y))
        p.addLine(to: CGPoint(x: rect.width - inset, y: y))
        return p
    }
}
