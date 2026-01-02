//
//  SignatureModel.swift
//  Just Scan
//
//  UNIFIED STRUCTURE: Single source of truth for signature state
//

import Foundation
import UIKit
import PDFKit

/// Unified signature model that works with both overlay rendering and PDF annotations
/// Uses NORMALIZED coordinates (0...1) for consistency across different page sizes
struct SignatureModel: Identifiable, Equatable {
    let id: UUID
    
    /// Normalized center point (0...1, bottom-left origin like PDF)
    var center: CGPoint
    
    /// Width as ratio of page width (0...1)
    var widthRatio: CGFloat
    
    /// Rotation in degrees (clockwise)
    var rotation: CGFloat
    
    /// Signature color
    var color: SignatureColor
    
    /// Image ID (references SignatureService history)
    let imageID: String
    
    /// Aspect ratio (width / height)
    let aspectRatio: CGFloat
    
    /// Whether this signature has been committed to PDF
    var isCommitted: Bool
    
    /// Annotation ID (if committed)
    var annotationID: String?
    
    init(id: UUID = UUID(),
         center: CGPoint,
         widthRatio: CGFloat,
         rotation: CGFloat,
         color: SignatureColor,
         imageID: String,
         aspectRatio: CGFloat,
         isCommitted: Bool = false,
         annotationID: String? = nil) {
        self.id = id
        self.center = center
        self.widthRatio = widthRatio
        self.rotation = rotation
        self.color = color
        self.imageID = imageID
        self.aspectRatio = aspectRatio
        self.isCommitted = isCommitted
        self.annotationID = annotationID
    }
    
    // MARK: - PDF Rect Conversion Helpers
    
    /// Get PDF rect from normalized properties
    func pdfRect(for page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        
        // Convert normalized center to PDF coordinates
        let pdfCenterX = center.x * pageBounds.width
        let pdfCenterY = center.y * pageBounds.height
        
        // Calculate size from width ratio
        let width = widthRatio * pageBounds.width
        let height = width / aspectRatio
        
        return CGRect(
            x: pdfCenterX - width/2,
            y: pdfCenterY - height/2,
            width: width,
            height: height
        )
    }
    
    /// Update from PDF rect
    mutating func updateFromPDFRect(_ rect: CGRect, page: PDFPage) {
        let pageBounds = page.bounds(for: .mediaBox)
        
        // Normalize center
        center = CGPoint(
            x: rect.midX / pageBounds.width,
            y: rect.midY / pageBounds.height
        )
        
        // Normalize width
        widthRatio = rect.width / pageBounds.width
    }
    
    // MARK: - Loading from Annotation
    
    static func fromAnnotation(_ annotation: PDFAnnotation, page: PDFPage) -> SignatureModel? {
        // Only load annotations marked as JustScan signatures
        guard let name = annotation.value(forAnnotationKey: .name) as? String,
              name == "JustScanSignature_v1" else {
            return nil
        }
        
        guard let stamp = annotation as? ImageStampAnnotation else {
            return nil
        }
        
        let pageBounds = page.bounds(for: .mediaBox)
        let bounds = annotation.bounds
        
        // Use stored properties from annotation
        let normalizedCenter = CGPoint(
            x: bounds.midX / pageBounds.width,
            y: bounds.midY / pageBounds.height
        )
        
        let widthRatio = stamp.originalWidthRatio
        
        // Get image ID from annotation (would need to be stored)
        // For now, use a placeholder
        let imageID = UUID().uuidString
        
        return SignatureModel(
            center: normalizedCenter,
            widthRatio: widthRatio,
            rotation: stamp.originalRotation,
            color: stamp.originalColor,
            imageID: imageID,
            aspectRatio: stamp.originalAspectRatio,
            isCommitted: true,
            annotationID: annotation.userName
        )
    }
    
    static func == (lhs: SignatureModel, rhs: SignatureModel) -> Bool {
        lhs.id == rhs.id &&
        lhs.center == rhs.center &&
        lhs.widthRatio == rhs.widthRatio &&
        lhs.rotation == rhs.rotation &&
        lhs.color == rhs.color &&
        lhs.imageID == rhs.imageID
    }
}

// MARK: - SignatureColor Enum

enum SignatureColor: String, CaseIterable, Codable {
    case black
    case blue
    case red
    
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .blue: return .systemBlue
        case .red: return .systemRed
        }
    }
}