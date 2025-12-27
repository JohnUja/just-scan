import SwiftUI
import PDFKit

struct UnsavedSignatureOverlay: View {
    let pageIndex: Int
    let pdfDocument: PDFDocument
    let signatureImage: UIImage
    let placement: DocumentReviewView.SignaturePlacement
    let showImage: Bool
    
    var body: some View {
        GeometryReader { geometry in
            if let page = pdfDocument.page(at: pageIndex) {
                let transform = DocumentReviewView.PDFPageTransform(page: page, viewSize: geometry.size)
                let center = transform.viewPoint(from: placement.center)
                let size = transform.viewSize(widthRatio: placement.widthRatio, aspectRatio: placement.aspectRatio)
                
                ZStack {
                    if showImage {
                        Image(uiImage: tinted(signatureImage, color: placement.color))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height)
                            .rotationEffect(.degrees(placement.rotation))
                            .contentShape(Rectangle())
                    } else {
                        // no image; area remains hittable if wrapped by parent
                        Color.clear
                            .frame(width: size.width, height: size.height)
                    }
                }
                .position(center)
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

