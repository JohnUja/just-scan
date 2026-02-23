//
//  SignatureExportService.swift
//  Just Scan
//
//  Export service for PDF documents with signatures.
//  This is the ONLY place where PDF annotations are created.
//
//  ARCHITECTURE NOTES:
//  - During editing, signatures are NEVER stored as PDF annotations
//  - This service creates annotations ONLY at export time
//  - Two export modes:
//    1. Flattened: Signatures burned into page pixels (non-editable)
//    2. Secure: Signatures as annotations with payload (re-importable in Just Scan)
//

import Foundation
import UIKit
import PDFKit

// MARK: - Standalone Export Functions (Nonisolated for Background Threading)

/// Helper struct for nonisolated export functions
struct PDFExportHelper {
    /// Export PDF with signatures flattened (burned into page pixels) directly to file
    /// Result: Signatures cannot be moved in any PDF viewer. This is the "final" export.
    /// - Parameters:
    ///   - inputPDFData: The original PDF as Data (snapshot taken on main thread)
    ///   - signatures: Signatures indexed by page number
    ///   - signatureImages: Dictionary mapping signature imageID to UIImage (pre-fetched on MainActor)
    ///   - outputURL: File URL to write the exported PDF to
    /// - Returns: URL if successful, nil on failure
    /// - Note: Static method in nonisolated struct so it can be called from background threads without MainActor access
    static func exportFlattened(inputPDFData: Data, signatures: [Int: [SignatureModel]], signatureImages: [String: UIImage], to outputURL: URL) -> URL? {
        // ✅ Use CGPDFDocument (thread-safe) instead of PDFDocument
        // Create CGDataProvider from Data
        guard let dataProvider = CGDataProvider(data: inputPDFData as CFData),
              let cgPDFDoc = CGPDFDocument(dataProvider) else { return nil }
        guard cgPDFDoc.numberOfPages > 0 else { return nil }
        
        // ✅ Create file-based consumer (writes directly to disk, not memory)
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let firstPage = cgPDFDoc.page(at: 1) else { return nil }
        
        var mediaBox = firstPage.getBoxRect(CGPDFBox.mediaBox)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        
        // ✅ Wrap page rendering in autoreleasepool to release memory after each page
        for pageIndex in 1...cgPDFDoc.numberOfPages {
            autoreleasepool {
                guard let page = cgPDFDoc.page(at: pageIndex) else { return }
                let pageRect = page.getBoxRect(CGPDFBox.mediaBox)
                
                let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: pageRect]
                context.beginPDFPage(pageInfo as CFDictionary)
                
                // Draw original page content
                context.saveGState()
                context.drawPDFPage(page)
                context.restoreGState()
                
                // Draw signatures for this page (pageIndex - 1 because CGPDFDocument is 1-indexed)
                let signaturePageIndex = pageIndex - 1
                if let pageSignatures = signatures[signaturePageIndex] {
                    for signature in pageSignatures {
                        Self.drawSignatureOnContext(signature, to: context, pageRect: pageRect, signatureImages: signatureImages)
                    }
                }
                
                context.endPDFPage()
                
                // ✅ OOM insurance: flush every few pages (optional but recommended)
                if pageIndex % 5 == 0 {
                    context.flush()
                }
            }
        }
        
        context.closePDF()
        
        return outputURL
    }
    
    /// Draw a signature onto a CGContext (for flattened export) - updated to work with CGPDFDocument
    /// ✅ Uses same coordinate math as SignatureModel.pdfRect(for:) - no Y flip needed
    private static func drawSignatureOnContext(_ signature: SignatureModel, to context: CGContext, pageRect: CGRect, signatureImages: [String: UIImage]) {
    guard let image = signatureImages[signature.imageID] else { return }
    
    // Apply color tint
    let tintedImage = Self.applyColorTintToImage(image, color: signature.color.uiColor)
    guard let cgImage = tintedImage.cgImage else { return }
    
    // ✅ Calculate PDF rect from normalized coordinates (EXACT same math as SignatureModel.pdfRect)
    let pdfCenterX = signature.center.x * pageRect.width
    let pdfCenterY = signature.center.y * pageRect.height  // ✅ No Y flip - center is already in PDF coords
    let width = signature.widthRatio * pageRect.width
    let height = width / signature.aspectRatio
    
    let pdfRect = CGRect(
        x: pdfCenterX - width/2,
        y: pdfCenterY - height/2,
        width: width,
        height: height
    )
    
    context.saveGState()
    
    // Move to center of signature rect
    context.translateBy(x: pdfRect.midX, y: pdfRect.midY)
    
    // Apply rotation (convert degrees to radians, negate for CoreGraphics CCW convention)
    let radians = -signature.rotation * .pi / 180.0
    context.rotate(by: radians)
    
    // Draw centered on origin
    let drawRect = CGRect(
        x: -pdfRect.width / 2,
        y: -pdfRect.height / 2,
        width: pdfRect.width,
        height: pdfRect.height
    )
    context.draw(cgImage, in: drawRect)
    
    context.restoreGState()
    }
    
    /// Apply color tint to a signature image
    /// Note: Flip context when drawing CGImage so tinted result has same orientation as original.
    /// (UIGraphicsImageRenderer is Y-down; CGImage draw uses bottom-left origin, so without flip the tinted image would be upside down in flattened export.)
    private static func applyColorTintToImage(_ image: UIImage, color: UIColor) -> UIImage {
    if color == .black {
        return image
    }
    
    guard let cgImage = image.cgImage else { return image }
    let size = image.size
    let renderer = UIGraphicsImageRenderer(size: size)
    
    return renderer.image { context in
        let ctx = context.cgContext
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setBlendMode(.destinationIn)
        // Flip so CGImage (bottom-left origin) is drawn right-way up into the renderer buffer (top-left origin)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
    }
}

// MARK: - Service Class

/// Service for exporting PDFs with signatures
@MainActor
class SignatureExportService {
    
    static let shared = SignatureExportService()
    
    private let signatureService = SignatureService.shared
    
    private init() {}
    
    // MARK: - Export: Secure (Editable in Just Scan)
    
    /// Export PDF with signatures as annotations containing payload directly to file
    /// - Parameters:
    ///   - inputPDFData: The original PDF as Data (snapshot taken on main thread)
    ///   - signatures: Signatures indexed by page number
    ///   - outputURL: File URL to write the exported PDF to
    /// - Returns: URL if successful, nil on failure
    func exportSecure(inputPDFData: Data, signatures: [Int: [SignatureModel]], to outputURL: URL) -> URL? {
        // ✅ Use autoreleasepool for the entire document copy
        return autoreleasepool {
            // Create a copy of the document to avoid modifying the original
            guard let exportDoc = PDFDocument(data: inputPDFData) else { return nil }
            
            for pageIndex in 0..<exportDoc.pageCount {
                guard let page = exportDoc.page(at: pageIndex) else { continue }
                
                // Add signature annotations for this page
                if let pageSignatures = signatures[pageIndex] {
                    for signature in pageSignatures {
                        if let annotation = createAnnotation(from: signature, page: page) {
                            page.addAnnotation(annotation)
                        }
                    }
                }
            }
            
            // ✅ Write directly to file instead of returning Data
            guard exportDoc.write(to: outputURL) else { return nil }
            return outputURL
        }
    }
    
    // MARK: - Private Helpers
    
    /// Get signature image from SignatureService
    private func getSignatureImage(for signature: SignatureModel) -> UIImage? {
        // Try to find in signature history first
        if let uuid = UUID(uuidString: signature.imageID),
           let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
            return savedSignature.image
        }
        // Fallback to current signature
        return signatureService.signatureImage
    }
    
    /// Create an ImageStampAnnotation from a SignatureModel (for secure export)
    private func createAnnotation(from signature: SignatureModel, page: PDFPage) -> ImageStampAnnotation? {
        guard let image = getSignatureImage(for: signature) else { return nil }
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        
        // Calculate bounding box with rotation padding
        let rotationRadians = abs(signature.rotation.truncatingRemainder(dividingBy: 180)) * .pi / 180
        let rotatedWidth = abs(cos(rotationRadians)) * pdfRect.width + abs(sin(rotationRadians)) * pdfRect.height
        let rotatedHeight = abs(sin(rotationRadians)) * pdfRect.width + abs(cos(rotationRadians)) * pdfRect.height
        
        let boundsWidth = max(rotatedWidth, pdfRect.width) * 1.05
        let boundsHeight = max(rotatedHeight, pdfRect.height) * 1.05
        
        let annotationBounds = CGRect(
            x: pdfRect.midX - boundsWidth / 2,
            y: pdfRect.midY - boundsHeight / 2,
            width: boundsWidth,
            height: boundsHeight
        )
        
        let annotation = ImageStampAnnotation(
            bounds: annotationBounds,
            image: image,
            rotation: signature.rotation,
            color: signature.color,
            aspectRatio: signature.aspectRatio,
            widthRatio: signature.widthRatio,
            signatureID: signature.id.uuidString,
            imageID: signature.imageID
        )
        
        // Set annotation properties
        annotation.setValue(SignatureAnnotationKeys.annotationName, forAnnotationKey: PDFAnnotationKey.name)
        annotation.userName = signature.id.uuidString
        annotation.shouldPrint = true
        annotation.isReadOnly = false
        
        // Update payload with exact center (for re-import)
        annotation.updatePayload(centerNormalized: signature.center)
        
        return annotation
    }
    
}

