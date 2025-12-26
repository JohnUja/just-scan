//
//  ImageStampAnnotation.swift
//  Just Scan
//
//  Created to fix compilation errors
//

import PDFKit
import UIKit

class ImageStampAnnotation: PDFAnnotation {
    var originalRotation: CGFloat
    var originalColor: SignatureColor
    var originalAspectRatio: CGFloat
    private var storedImageData: Data?
    var isLocked: Bool = false
    var imageSnapshot: UIImage? {
        guard let data = storedImageData else { return nil }
        return UIImage(data: data)
    }
    
    init(bounds: CGRect, image: UIImage, rotation: CGFloat, color: SignatureColor, aspectRatio: CGFloat) {
        self.originalRotation = rotation
        self.originalColor = color
        self.originalAspectRatio = aspectRatio
        
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        
        // Set the annotation properties
        self.userName = "Signature"
        
        // Store the image data
        self.storedImageData = image.pngData()
        
        // Store metadata in annotation's contents as JSON for backward compatibility
        // (in case the annotation is read as a regular PDFAnnotation elsewhere)
        let metadata: [String: Any] = [
            "rotation": rotation,
            "color": color.rawValue,
            "aspectRatio": aspectRatio
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.contents = jsonString
        }
    }
    
    required init?(coder: NSCoder) {
        // Decode properties
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
        
        storedImageData = coder.decodeObject(of: NSData.self, forKey: "storedImageData") as Data?
        
        super.init(coder: coder)
    }
    
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(Double(originalRotation), forKey: "originalRotation")
        coder.encode(originalColor.rawValue, forKey: "originalColor")
        coder.encode(Double(originalAspectRatio), forKey: "originalAspectRatio")
        if let imageData = storedImageData {
            coder.encode(imageData as NSData, forKey: "storedImageData")
        }
    }
    
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // Draw the stored image
        guard let imageData = storedImageData,
              let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            return
        }
        
        // Save graphics state
        context.saveGState()
        
        // Move to center of bounds
        let centerX = bounds.midX
        let centerY = bounds.midY
        
        context.translateBy(x: centerX, y: centerY)
        
        // SwiftUI rotation is clockwise; Quartz is counter‑clockwise.
        // Use the negated angle and avoid extra Y flips to keep orientation consistent.
        if originalRotation != 0 {
            let rotationRadians = -(originalRotation * .pi / 180.0)
            context.rotate(by: rotationRadians)
        }
        
        // Draw the image
        let imageRect = CGRect(
            x: -bounds.width / 2,
            y: -bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )
        
        context.draw(cgImage, in: imageRect)
        
        // Restore graphics state
        context.restoreGState()
    }
}

