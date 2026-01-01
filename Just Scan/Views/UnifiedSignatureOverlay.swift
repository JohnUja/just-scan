import SwiftUI
import PDFKit

struct UnifiedSignatureOverlay: View {
    let pageIndex: Int
    let pdfDocument: PDFDocument
    let pdfView: PDFView
    @Binding var placement: DocumentReviewView.SignaturePlacement
    let isActive: Bool
    
    let onDelete: () -> Void
    let onGestureStart: () -> Void
    let onDuplicate: () -> Void

    @State private var ghostPosition: CGPoint? = nil
    @State private var initialWidthRatio: CGFloat? = nil
    @State private var initialRotation: CGFloat? = nil
    
    var body: some View {
        if let page = pdfDocument.page(at: pageIndex), pdfView.scaleFactor > 0.1 {
            let pageBounds = page.bounds(for: .mediaBox)
            let currentScale = pdfView.scaleFactor
            
            let effectiveCenter = ghostPosition ?? placement.center
            let pdfPoint = CGPoint(x: effectiveCenter.x * pageBounds.width, y: effectiveCenter.y * pageBounds.height)
            let screenPoint = pdfView.convert(pdfPoint, from: page)
            
            let visualWidth = (pageBounds.width * placement.widthRatio) * currentScale
            let visualHeight = visualWidth / placement.aspectRatio

            ZStack {
                Image(uiImage: placement.signatureImage)
                    .renderingMode(placement.color == .black ? .original : .template)
                    .resizable()
                    .foregroundColor(Color(placement.color.uiColor))
                    .frame(width: visualWidth, height: visualHeight)
                    .rotationEffect(.degrees(placement.rotation))
                    .position(screenPoint)
                    .opacity(ghostPosition != nil ? 0.6 : 1.0)
                
                if isActive {
                    InlineSelectionBoxView(
                        position: screenPoint,
                        size: CGSize(width: visualWidth, height: visualHeight),
                        rotation: placement.rotation,
                        scaleFactor: currentScale,
                        onMove: { _ in },
                        onResize: { factor in
                            if initialWidthRatio == nil { initialWidthRatio = placement.widthRatio }
                            placement.widthRatio = max(0.05, min(0.8, (initialWidthRatio ?? 0.2) * factor))
                        },
                        onResizeEnd: { initialWidthRatio = nil },
                        onRotate: { delta in
                            if initialRotation == nil { initialRotation = placement.rotation; onGestureStart() }
                            placement.rotation = (initialRotation! + delta).truncatingRemainder(dividingBy: 360)
                        },
                        onRotateEnd: { initialRotation = nil },
                        onGestureStart: onGestureStart
                    )
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                if ghostPosition == nil { onGestureStart() }
                                let loc = pdfView.convert(value.location, to: page)
                                ghostPosition = GeometryMath.clampedCenter(
                                    CGPoint(x: loc.x / pageBounds.width, y: loc.y / pageBounds.height),
                                    widthRatio: placement.widthRatio,
                                    aspectRatio: placement.aspectRatio
                                )
                            }
                            .onEnded { _ in
                                if let final = ghostPosition { placement.center = final }
                                ghostPosition = nil
                            }
                    )
                    
                    FloatingToolbarViewInline(
                        position: CGPoint(x: screenPoint.x, y: screenPoint.y - visualHeight/2 - 50),
                        pdfView: pdfView,
                        page: page,
                        onColor: { /* Handled via binding in placement */ },
                        onDelete: onDelete,
                        onDuplicate: onDuplicate,
                        onMoveStart: {}, onMoveChanged: { _ in }, onMoveEnded: {},
                        isMoveMode: .constant(false),
                        currentPosition: .zero, currentWidthRatio: 0, currentAspectRatio: 0
                    )
                }
            }
        }
    }
}