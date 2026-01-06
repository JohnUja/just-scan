//
//  SignatureAnnotationPayload.swift
//  Just Scan
//
//  Metadata structure for storing signature identity and properties in PDF annotations
//

import Foundation

struct SignatureAnnotationPayload: Codable {
    let version: Int
    let signatureID: String      // UUID string
    let imageID: String          // UUID string from SignatureService
    let rotation: CGFloat
    let color: String
    let aspectRatio: CGFloat
    let widthRatio: CGFloat
    let centerX: CGFloat?        // ✅ NEW: Exact center X (normalized 0-1) to prevent coordinate bouncing
    let centerY: CGFloat?        // ✅ NEW: Exact center Y (normalized 0-1) to prevent coordinate bouncing
    let imageDataB64: String?     // Optional: base64 encoded image data for self-contained storage
}

// Legacy metadata format (for backward compatibility)
struct LegacySignatureMetadata: Codable {
    let rotation: CGFloat
    let color: String
    let aspectRatio: CGFloat
    let widthRatio: CGFloat
    let imageDataB64: String?
}

enum SignatureAnnotationKeys {
    static let annotationName = "JustScanSignature_v1"
    static let payloadPrefix = "JUSTSCAN_SIG_PAYLOAD:"
}

