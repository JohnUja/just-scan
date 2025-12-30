import SwiftUI
import PDFKit

struct UnsavedSignatureOverlay: View {
    let pageIndex: Int
    let pdfDocument: PDFDocument
    let pdfViewInstance: PDFView?  // PDFView instance for coordinate conversion
    let signatureImage: UIImage
    let placement: DocumentReviewView.SignaturePlacement
    let showImage: Bool
    
    var body: some View {
        GeometryReader { _ in
            // DEPRECATED: UnsavedSignatureOverlay is no longer used - replaced by UnifiedSignatureOverlay
            // This struct is kept for reference but should not be called
            // If it needs to be used, it should be updated to use pdfView.convert like UnifiedSignatureOverlay
            if let page = pdfDocument.page(at: pageIndex),
               let pdfView = pdfViewInstance,
               pdfView.scaleFactor > 0 {
                let pageBounds = page.bounds(for: .mediaBox)
                let currentScale = pdfView.scaleFactor
                
                // Calculate PDF point from normalized placement
                let pdfPoint = CGPoint(
                    x: placement.center.x * pageBounds.width,
                    y: placement.center.y * pageBounds.height
                )
                
                // Convert to screen coordinates using native PDFKit conversion
                let center = pdfView.convert(pdfPoint, from: page)
                
                // Scale visual size by zoom level
                let visualWidth = (pageBounds.width * placement.widthRatio) * currentScale
                let visualHeight = visualWidth / placement.aspectRatio
                
                // Only render if coordinate is valid
                if center != .zero {
                    ZStack {
                        if showImage {
                            Image(uiImage: tinted(signatureImage, color: placement.color))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: visualWidth, height: visualHeight)
                                .rotationEffect(.degrees(placement.rotation))
                                .contentShape(Rectangle())
                        } else {
                            // no image; area remains hittable if wrapped by parent
                            Color.clear
                                .frame(width: visualWidth, height: visualHeight)
                        }
                    }
                    .position(center)
                }
            }
        }
    }
    
    private func tinted(_ image: UIImage, color: SignatureColor) -> UIImage {
        guard color != .black, let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorMonochrome") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIColor(color: color.uiColor), forKey: kCIInputColorKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        guard let outputImage = filter.outputImage else { return image }
        let context = CIContext(options: nil)
        guard let cgImageOutput = context.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        return UIImage(cgImage: cgImageOutput)
    }
}

