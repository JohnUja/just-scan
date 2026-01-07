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

/// Service for exporting PDFs with signatures
@MainActor
class SignatureExportService {
    
    static let shared = SignatureExportService()
    
    private let signatureService = SignatureService.shared
    
    private init() {}
    
    // MARK: - Export: Flattened (Final)
    
    /// Export PDF with signatures flattened (burned into page pixels)
    /// Result: Signatures cannot be moved in any PDF viewer. This is the "final" export.
    /// - Parameters:
    ///   - pdfDocument: The original PDF document
    ///   - signatures: Signatures indexed by page number
    /// - Returns: PDF data with signatures rendered into pages, or nil on failure
    func exportFlattened(pdfDocument: PDFDocument, signatures: [Int: [SignatureModel]]) -> Data? {
        guard pdfDocument.pageCount > 0 else { return nil }
        
        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData as CFMutableData) else { return nil }
        
        // Get first page to initialize context
        guard let firstPage = pdfDocument.page(at: 0) else { return nil }
        var mediaBox = firstPage.bounds(for: .mediaBox)
        
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            var pageBox = pageRect
            
            context.beginPDFPage([kCGPDFContextMediaBox as String: pageBox] as CFDictionary)
            
            // Draw original page content
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            
            // Draw signatures for this page
            if let pageSignatures = signatures[pageIndex] {
                for signature in pageSignatures {
                    drawSignature(signature, to: context, page: page)
                }
            }
            
            context.endPDFPage()
        }
        
        context.closePDF()
        
        return outputData as Data
    }
    
    // MARK: - Export: Secure (Editable in Just Scan)
    
    /// Export PDF with signatures as annotations containing payload
    /// Result: Signatures can be moved in some PDF viewers.
    ///         Re-importing in Just Scan will restore full editability.
    /// - Parameters:
    ///   - pdfDocument: The original PDF document
    ///   - signatures: Signatures indexed by page number
    /// - Returns: PDF data with signature annotations, or nil on failure
    func exportSecure(pdfDocument: PDFDocument, signatures: [Int: [SignatureModel]]) -> Data? {
        guard pdfDocument.pageCount > 0 else { return nil }
        
        // Create a copy of the document to avoid modifying the original
        guard let pdfData = pdfDocument.dataRepresentation(),
              let exportDoc = PDFDocument(data: pdfData) else { return nil }
        
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
        
        return exportDoc.dataRepresentation()
    }
    
    // MARK: - Private Helpers
    
    /// Draw a signature onto a CGContext (for flattened export)
    private func drawSignature(_ signature: SignatureModel, to context: CGContext, page: PDFPage) {
        guard let image = getSignatureImage(for: signature) else { return }
        
        // Apply color tint
        let tintedImage = applyColorTint(to: image, color: signature.color.uiColor)
        guard let cgImage = tintedImage.cgImage else { return }
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        
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
        annotation.setValue(SignatureAnnotationKeys.annotationName, forAnnotationKey: .name)
        annotation.userName = signature.id.uuidString
        annotation.shouldPrint = true
        annotation.isReadOnly = false
        
        // Update payload with exact center (for re-import)
        annotation.updatePayload(centerNormalized: signature.center)
        
        return annotation
    }
    
    /// Get the signature image from SignatureService
    private func getSignatureImage(for signature: SignatureModel) -> UIImage? {
        if let uuid = UUID(uuidString: signature.imageID),
           let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
            return savedSignature.image
        }
        // Fallback to current signature
        return signatureService.signatureImage
    }
    
    /// Apply color tint to a signature image
    private func applyColorTint(to image: UIImage, color: UIColor) -> UIImage {
        // If black, return original (no tint needed)
        if color == .black {
            return image
        }
        
        guard let cgImage = image.cgImage else { return image }
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // Draw the color
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            
            // Use destination-in blend mode to tint only the non-transparent parts
            context.cgContext.setBlendMode(.destinationIn)
            context.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
    }
}

