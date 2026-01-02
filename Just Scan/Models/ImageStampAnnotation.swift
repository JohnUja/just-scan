//
//  ImageStampAnnotation.swift - DEFINITIVE FIX
//  Just Scan
//
//  Fixed drawing to prevent flipping and ensure proper rotation
//

import PDFKit
import UIKit

class ImageStampAnnotation: PDFAnnotation {
    var originalRotation: CGFloat
    var originalColor: SignatureColor
    var originalAspectRatio: CGFloat
    var originalWidthRatio: CGFloat
    private var storedImageData: Data?
    var isLocked: Bool = false
    
    var imageSnapshot: UIImage? {
        guard let data = storedImageData else { return nil }
        return UIImage(data: data)
    }
    
    init(bounds: CGRect, image: UIImage, rotation: CGFloat, color: SignatureColor, aspectRatio: CGFloat, widthRatio: CGFloat) {
        self.originalRotation = rotation
        self.originalColor = color
        self.originalAspectRatio = aspectRatio
        self.originalWidthRatio = widthRatio
        self.storedImageData = image.pngData()
        
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        
        self.userName = "JustScanSignature"
        updateContents()
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
        
        storedImageData = coder.decodeObject(of: NSData.self, forKey: "storedImageData") as Data?
        
        super.init(coder: coder)
    }
    
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(Double(originalRotation), forKey: "originalRotation")
        coder.encode(originalColor.rawValue, forKey: "originalColor")
        coder.encode(Double(originalAspectRatio), forKey: "originalAspectRatio")
        coder.encode(Double(originalWidthRatio), forKey: "originalWidthRatio")
        if let imageData = storedImageData {
            coder.encode(imageData as NSData, forKey: "storedImageData")
        }
    }
    
    private func updateContents() {
        guard let data = storedImageData else { return }
        let b64 = data.base64EncodedString()
        let metadata: [String: Any] = [
            "rotation": originalRotation,
            "color": originalColor.rawValue,
            "aspectRatio": originalAspectRatio,
            "widthRatio": originalWidthRatio,
            "imageDataB64": b64
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.contents = jsonString
        }
    }
    
    // CRITICAL FIX: Proper drawing without flipping
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let imageData = storedImageData,
              let image = UIImage(data: imageData) else {
            return
        }
        
        // Apply color tint to create the final image
        let tintedImage = applyColorTint(to: image, color: originalColor.uiColor)
        guard let cgImage = tintedImage.cgImage else { return }
        
        context.saveGState()
        
        // Calculate the actual signature size (unrotated)
        let imageAspectRatio = image.size.width / image.size.height
        let storedAspectRatio = originalAspectRatio > 0 ? originalAspectRatio : imageAspectRatio
        
        // Fit to 95% of bounds to avoid clipping
        let boundsAspectRatio = bounds.width / bounds.height
        let actualWidth: CGFloat
        let actualHeight: CGFloat
        
        if storedAspectRatio > boundsAspectRatio {
            actualWidth = bounds.width * 0.95
            actualHeight = actualWidth / storedAspectRatio
        } else {
            actualHeight = bounds.height * 0.95
            actualWidth = actualHeight * storedAspectRatio
        }
        
        // Move to center of bounds
        context.translateBy(x: bounds.midX, y: bounds.midY)
        
        // Apply rotation (PDF uses counter-clockwise, we store clockwise)
        if originalRotation != 0 {
            let radians = -originalRotation * .pi / 180.0
            context.rotate(by: radians)
        }
        
        // CRITICAL: Flip Y-axis for image drawing (CGImage is always top-down)
        // This is the KEY FIX - we flip once, correctly
        context.scaleBy(x: 1.0, y: -1.0)
        
        // Draw the image centered
        let imageRect = CGRect(
            x: -actualWidth / 2,
            y: -actualHeight / 2, // Negative because Y is flipped
            width: actualWidth,
            height: actualHeight
        )
        
        context.draw(cgImage, in: imageRect)
        
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