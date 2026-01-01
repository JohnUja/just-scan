import SwiftUI
import PDFKit

struct FloatingToolbarViewInline: View {
    let position: CGPoint
    let pdfView: PDFView?
    let page: PDFPage?
    let onColor: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    
    // Parameters to match DocumentReviewView calls
    var onMoveStart: () -> Void = {}
    var onMoveChanged: (CGPoint) -> Void = { _ in }
    var onMoveEnded: () -> Void = {}
    @Binding var isMoveMode: Bool
    let currentPosition: CGPoint
    let currentWidthRatio: CGFloat
    let currentAspectRatio: CGFloat

    var body: some View {
        HStack(spacing: 15) {
            Button(action: onColor) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 14, weight: .bold))
            }
            
            Divider().frame(height: 20)
            
            Button(action: onDuplicate) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 14, weight: .bold))
            }
            
            Button(action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color(.systemBackground)).shadow(radius: 8))
        .position(position)
    }
}