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
        // CRITICAL: Check if this is our signature annotation (multiple ways for reliability)
        let name = annotation.value(forAnnotationKey: .name) as? String
        let contents = annotation.contents ?? ""
        
        let isOurs =
            (name == SignatureAnnotationKeys.annotationName) ||
            contents.hasPrefix(SignatureAnnotationKeys.payloadPrefix) ||
            contents.contains("imageDataB64")
        
        guard isOurs else { return nil }
        
        // 1) Signature ID from userName (stable!)
        let sigIDString = annotation.userName ?? ""
        guard !sigIDString.isEmpty,
              let sigUUID = UUID(uuidString: sigIDString) else { return nil }
        
        // 2) Parse payload with fallback support for old format
        var payload: SignatureAnnotationPayload?
        var legacyMetadata: LegacySignatureMetadata?
        
        if let contents = annotation.contents {
            if contents.hasPrefix(SignatureAnnotationKeys.payloadPrefix) {
                // New format: parse payload
                let json = String(contents.dropFirst(SignatureAnnotationKeys.payloadPrefix.count))
                if let data = json.data(using: .utf8) {
                    payload = try? JSONDecoder().decode(SignatureAnnotationPayload.self, from: data)
                }
            } else if contents.contains("imageDataB64") {
                // Legacy format: parse old metadata
                if let data = contents.data(using: .utf8),
                   let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    legacyMetadata = try? JSONDecoder().decode(LegacySignatureMetadata.self, from: data)
                }
            }
        }
        
        // 3) Extract properties with fallback chain
        let pageBounds = page.bounds(for: .mediaBox)
        let bounds = annotation.bounds
        
        let normalizedCenter = CGPoint(
            x: bounds.midX / pageBounds.width,
            y: bounds.midY / pageBounds.height
        )
        
        // Rotation: payload -> legacy -> annotation property (if ImageStampAnnotation)
        let rotation: CGFloat
        if let r = payload?.rotation {
            rotation = r
        } else if let r = legacyMetadata?.rotation {
            rotation = r
        } else if let stamp = annotation as? ImageStampAnnotation {
            rotation = stamp.originalRotation
        } else {
            rotation = 0  // Fallback
        }
        
        // Color: payload -> legacy -> annotation property
        let color: SignatureColor
        if let c = payload?.color, let col = SignatureColor(rawValue: c) {
            color = col
        } else if let c = legacyMetadata?.color, let col = SignatureColor(rawValue: c) {
            color = col
        } else if let stamp = annotation as? ImageStampAnnotation {
            color = stamp.originalColor
        } else {
            color = .black  // Fallback
        }
        
        // Aspect ratio: payload -> legacy -> annotation property
        let aspect: CGFloat
        if let a = payload?.aspectRatio {
            aspect = a
        } else if let a = legacyMetadata?.aspectRatio {
            aspect = a
        } else if let stamp = annotation as? ImageStampAnnotation {
            aspect = stamp.originalAspectRatio
        } else {
            // Calculate from bounds if available
            aspect = bounds.height > 0 ? bounds.width / bounds.height : 2.0
        }
        
        // Width ratio: payload -> legacy -> annotation property
        let widthRatio: CGFloat
        if let w = payload?.widthRatio {
            widthRatio = w
        } else if let w = legacyMetadata?.widthRatio {
            widthRatio = w
        } else if let stamp = annotation as? ImageStampAnnotation {
            widthRatio = stamp.originalWidthRatio
        } else {
            // Calculate from bounds
            widthRatio = pageBounds.width > 0 ? bounds.width / pageBounds.width : 0.2
        }
        
        // Image ID: payload -> annotation property -> generate from imageData
        let imageID: String
        if let id = payload?.imageID, !id.isEmpty {
            imageID = id
        } else if let stamp = annotation as? ImageStampAnnotation, !stamp.imageID.isEmpty {
            imageID = stamp.imageID
        } else if let b64 = payload?.imageDataB64 ?? legacyMetadata?.imageDataB64,
                  let data = Data(base64Encoded: b64) {
            // Generate stable ID from image data (deterministic)
            imageID = "img_" + String(data.hashValue)
        } else {
            // Last resort: generate new ID (shouldn't happen)
            imageID = UUID().uuidString
        }
        
        return SignatureModel(
            id: sigUUID,
            center: normalizedCenter,
            widthRatio: widthRatio,
            rotation: rotation,
            color: color,
            imageID: imageID,
            aspectRatio: aspect,
            isCommitted: true,
            annotationID: sigIDString
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