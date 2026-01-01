import SwiftUI

struct InlineSelectionBoxView: View {
    let position: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let scaleFactor: CGFloat
    let onMove: (CGSize) -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void
    let onRotate: (CGFloat) -> Void
    let onRotateEnd: () -> Void
    let onGestureStart: () -> Void
    
    private var safeScale: CGFloat { max(0.1, scaleFactor) }
    private var handleSize: CGFloat { max(12, min(20, 14 / safeScale)) }
    
    var body: some View {
        ZStack {
            // The selection border
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2.0 / safeScale)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotation))
                .position(position)
            
            // Interaction handles (simplified for stability)
            ForEach(0..<4) { index in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: handleSize, height: handleSize)
                    .position(rotatedCornerPosition(for: index))
            }
        }
    }

    private func rotatedCornerPosition(for index: Int) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        let p: CGPoint
        switch index {
        case 0: p = CGPoint(x: position.x - halfW, y: position.y - halfH)
        case 1: p = CGPoint(x: position.x + halfW, y: position.y - halfH)
        case 2: p = CGPoint(x: position.x + halfW, y: position.y + halfH)
        default: p = CGPoint(x: position.x - halfW, y: position.y + halfH)
        }
        
        let rad = rotation * .pi / 180
        let tx = p.x - position.x
        let ty = p.y - position.y
        return CGPoint(
            x: tx * cos(rad) - ty * sin(rad) + position.x,
            y: tx * sin(rad) + ty * cos(rad) + position.y
        )
    }
}