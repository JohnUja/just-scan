//
//  ImageStampAnnotation.swift - DEFINITIVE FIX
//  Just Scan
//
//  Fixed drawing to prevent flipping and ensure proper rotation
//

import PDFKit
import UIKit
import Foundation

class ImageStampAnnotation: PDFAnnotation {
    var originalRotation: CGFloat
    var originalColor: SignatureColor
    var originalAspectRatio: CGFloat
    var originalWidthRatio: CGFloat
    
    // NEW: Identity fields
    var signatureID: String
    var imageID: String
    
    var storedImageData: Data?  // ✅ Current tinted image data (for drawing)
    var baseImageData: Data?  // ✅ CRITICAL: Original untinted image (never changes, used for retinting)
    
    var imageSnapshot: UIImage? {
        guard let data = storedImageData else { return nil }
        return UIImage(data: data)
    }
    
    /// Get the original untinted base image (for color changes)
    var baseImage: UIImage? {
        guard let data = baseImageData else { return nil }
        return UIImage(data: data)
    }
    
    init(bounds: CGRect, image: UIImage, rotation: CGFloat, color: SignatureColor, aspectRatio: CGFloat, widthRatio: CGFloat, signatureID: String, imageID: String) {
        self.originalRotation = rotation
        self.originalColor = color
        self.originalAspectRatio = aspectRatio
        self.originalWidthRatio = widthRatio
        self.signatureID = signatureID
        self.imageID = imageID
        // ✅ CRITICAL FIX: Normalize image orientation to .up BEFORE storing
        // This prevents color tinting from flipping/inverting the signature
        // UIGraphicsImageRenderer doesn't preserve orientation metadata, so we must ensure .up
        let normalizedImage = image.normalizedToUp()
        let baseImageData = normalizedImage.pngData()
        self.baseImageData = baseImageData  // Original untinted image (never changes)
        self.storedImageData = baseImageData  // Also store as base (draw() will tint on render)
        
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        
        // IMPORTANT: unique mapping - userName must equal signatureID
        self.userName = signatureID
        self.setValue(SignatureAnnotationKeys.annotationName, forAnnotationKey: .name)
        
        // ✅ Initialize payload without center (center will be set later via updatePayload when annotation is added to page)
        updateContents(centerNormalized: nil)
    }
    
    required init?(coder: NSCoder) {
        if coder.containsValue(forKey: "originalRotation") {
            originalRotation = CGFloat(coder.decodeDouble(forKey: "originalRotation"))
        } else {
            originalRotation = 0
        }
        
        if let colorString = coder.decodeObject(of: NSString.self, forKey: "originalColor") as String?,
           let color = SignatureColor(rawValue: colorString) {
            originalColor = color
        } else {
            originalColor = .black
        }
        
        if coder.containsValue(forKey: "originalAspectRatio") {
            originalAspectRatio = CGFloat(coder.decodeDouble(forKey: "originalAspectRatio"))
        } else {
            originalAspectRatio = 2.0
        }
        
        if coder.containsValue(forKey: "originalWidthRatio") {
            originalWidthRatio = CGFloat(coder.decodeDouble(forKey: "originalWidthRatio"))
        } else {
            originalWidthRatio = 0.2
        }
        
        // NEW: Decode identity fields
        if let sigID = coder.decodeObject(of: NSString.self, forKey: "signatureID") as String? {
            signatureID = sigID
        } else {
            signatureID = UUID().uuidString // Fallback (shouldn't happen if encoded)
        }
        
        if let imgID = coder.decodeObject(of: NSString.self, forKey: "imageID") as String? {
            imageID = imgID
        } else {
            imageID = UUID().uuidString // Fallback
        }
        
        storedImageData = coder.decodeObject(of: NSData.self, forKey: "storedImageData") as Data?
        baseImageData = coder.decodeObject(of: NSData.self, forKey: "baseImageData") as Data?
        
        // ✅ If baseImageData is missing (old annotations), use storedImageData as fallback
        if baseImageData == nil {
            baseImageData = storedImageData
        }
        
        super.init(coder: coder)
        
        // Ensure the PDF recognizes it as our annotation even after decode
        self.userName = signatureID
        self.setValue(SignatureAnnotationKeys.annotationName, forAnnotationKey: .name)
    }
    
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(Double(originalRotation), forKey: "originalRotation")
        coder.encode(originalColor.rawValue, forKey: "originalColor")
        coder.encode(Double(originalAspectRatio), forKey: "originalAspectRatio")
        coder.encode(Double(originalWidthRatio), forKey: "originalWidthRatio")
        coder.encode(signatureID, forKey: "signatureID")
        coder.encode(imageID, forKey: "imageID")
        if let imageData = storedImageData {
            coder.encode(imageData as NSData, forKey: "storedImageData")
        }
        if let baseData = baseImageData {
            coder.encode(baseData as NSData, forKey: "baseImageData")
        }
    }
    
    /// Update payload with optional center coordinates (prevents post-save drift)
    /// ✅ CRITICAL: Always use this method, never updatePayloadIfNeeded() (which wipes center)
    func updatePayload(centerNormalized: CGPoint?) {
        updateContents(centerNormalized: centerNormalized)
    }
    
    /// ✅ DEPRECATED: This method can wipe center - use updatePayload(centerNormalized:) instead
    /// This will crash in debug to prevent accidental use
    @available(*, deprecated, message: "Use updatePayload(centerNormalized:) with a real center to preserve center")
    func updatePayloadIfNeeded() {
#if DEBUG
        fatalError("Do not call updatePayloadIfNeeded() - use updatePayload(centerNormalized:) instead")
#else
        // In release, preserve existing center as fallback (but this should never be called)
        var existingCenter: CGPoint? = nil
        if let contents = self.contents,
           contents.hasPrefix(SignatureAnnotationKeys.payloadPrefix) {
            let json = String(contents.dropFirst(SignatureAnnotationKeys.payloadPrefix.count))
            if let data = json.data(using: .utf8),
               let payload = try? JSONDecoder().decode(SignatureAnnotationPayload.self, from: data) {
                if let centerX = payload.centerX, let centerY = payload.centerY {
                    existingCenter = CGPoint(x: centerX, y: centerY)
                }
            }
        }
        updateContents(centerNormalized: existingCenter)
#endif
    }
    
    private func updateContents(centerNormalized: CGPoint? = nil) {
        // ✅ STRATEGY A: Store base (untinted) image in payload for clean retinting
        // Use baseImageData if available, fallback to storedImageData for backward compatibility
        let baseData = baseImageData ?? storedImageData
        guard let imageData = baseData else { return }
        let b64 = imageData.base64EncodedString()
        
        let payload = SignatureAnnotationPayload(
            version: 1,
            signatureID: signatureID,
            imageID: imageID,
            rotation: originalRotation,
            color: originalColor.rawValue,
            aspectRatio: originalAspectRatio,
            widthRatio: originalWidthRatio,
            centerX: centerNormalized?.x,  // ✅ CRITICAL: Store exact center to prevent post-save drift
            centerY: centerNormalized?.y,  // ✅ CRITICAL: Store exact center to prevent post-save drift
            imageDataB64: b64  // Store image data for self-contained storage
        )
        
        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            self.contents = SignatureAnnotationKeys.payloadPrefix + json
        }
    }
    
    // CRITICAL FIX: Draw in annotation-local coordinates
    // ✅ STRATEGY A: Tint in draw only - storedImageData should be base (untinted) image
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // ✅ NOTE: Cannot log here - draw() is called from PDFKit's rendering context (not main actor)
        // Logging should happen at controller level, not in draw() method
        
        // ✅ Use baseImageData (untinted) for tinting, fallback to storedImageData for backward compatibility
        let baseData = baseImageData ?? storedImageData
        guard let imageData = baseData,
              let image = UIImage(data: imageData) else {
            // Cannot log here - not on main actor
            return
        }
        
        // ✅ Tint the base image using current color (no double-tinting)
        let tinted = applyColorTint(to: image, color: originalColor.uiColor)
        guard let cgImage = tinted.cgImage else { return }

        let b = self.bounds

        // Compute actual draw size (fit inside bounds)
        let imgAR = image.size.width / max(image.size.height, 1)
        let ar = originalAspectRatio > 0 ? originalAspectRatio : imgAR

        let boundsAR = b.width / max(b.height, 1)
        let drawW: CGFloat
        let drawH: CGFloat

        if ar > boundsAR {
            drawW = b.width * 0.95
            drawH = drawW / ar
        } else {
            drawH = b.height * 0.95
            drawW = drawH * ar
        }

        context.saveGState()
        
        // ✅ REMOVED: CTM logging from draw() - draw() runs off main actor, can't call main actor-isolated DebugLogger
        // CTM tracking will be done from controller side before/after setNeedsDisplay()
        
        // Move origin to annotation rect (LOCALIZE)
        context.translateBy(x: b.minX, y: b.minY)

        // Now we draw in local space (0..b.width, 0..b.height)
        context.translateBy(x: b.width * 0.5, y: b.height * 0.5)

        // Your model stores clockwise degrees; CoreGraphics rotation is CCW, so negate
        let radians = -originalRotation * .pi / 180.0
        context.rotate(by: radians)

        // Draw in local coordinates
        let rect = CGRect(x: -drawW/2, y: -drawH/2, width: drawW, height: drawH)
        context.draw(cgImage, in: rect)

        context.restoreGState()
    }
    
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

// MARK: - UIImage Orientation Normalization Extension
extension UIImage {
    /// Normalize image orientation to .up to prevent flipping during color tinting
    /// UIGraphicsImageRenderer doesn't preserve orientation metadata, so we must redraw
    func normalizedToUp() -> UIImage {
        // If already .up, no work needed
        if imageOrientation == .up {
            return self
        }
        
        // Redraw the image in correct orientation
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return normalizedImage ?? self
    }
}