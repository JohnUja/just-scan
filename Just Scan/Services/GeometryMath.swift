import SwiftUI
import CoreGraphics

struct GeometryMath {
    /// Calculates the bounding box of a rotated rectangle.
    static func rotatedRect(size: CGSize, degrees: CGFloat) -> CGSize {
        let radians = abs(degrees.truncatingRemainder(dividingBy: 180)) * .pi / 180
        let width = abs(size.width * cos(radians)) + abs(size.height * sin(radians))
        let height = abs(size.width * sin(radians)) + abs(size.height * cos(radians))
        return CGSize(width: width * 1.1, height: height * 1.1) // 10% safety padding
    }
    
    /// Clamps a signature center to ensure it stays on the page.
    static func clampedCenter(_ center: CGPoint, widthRatio: CGFloat, aspectRatio: CGFloat) -> CGPoint {
        let heightRatio = widthRatio / aspectRatio
        let hW = widthRatio / 2
        let hH = heightRatio / 2
        return CGPoint(
            x: max(hW, min(1.0 - hW, center.x)),
            y: max(hH, min(1.0 - hH, center.y))
        )
    }
}