//
//  PDFCoordinateConverter.swift
//  Just Scan
//
//  Created as part of signature architecture refactor
//  Phase 2: Single authoritative coordinate conversion service
//

import UIKit
import PDFKit

/// Centralized coordinate conversion service.
/// This is the single source of truth for all coordinate transformations
/// between PDF coordinate space, normalized space (0-1), and view/screen space.
///
/// All coordinate conversions should go through this service to ensure
/// consistency and prevent rounding errors that cause snapping bugs.
@MainActor
class PDFCoordinateConverter {
    
    // MARK: - PDF ↔ View Conversions
    
    /// Convert a point from PDF coordinate space to view/screen coordinate space
    /// - Parameters:
    ///   - pdfPoint: Point in PDF coordinate space (page space, bottom-left origin)
    ///   - page: The PDF page containing the point
    ///   - pdfView: The PDFView instance for conversion
    /// - Returns: Point in view coordinate space (top-left origin)
    static func pdfToView(_ pdfPoint: CGPoint, page: PDFPage, pdfView: PDFView) -> CGPoint {
        return pdfView.convert(pdfPoint, from: page)
    }
    
    /// Convert a point from view/screen coordinate space to PDF coordinate space
    /// - Parameters:
    ///   - viewPoint: Point in view coordinate space (top-left origin)
    ///   - page: The PDF page to convert to
    ///   - pdfView: The PDFView instance for conversion
    /// - Returns: Point in PDF coordinate space (page space, bottom-left origin)
    static func viewToPDF(_ viewPoint: CGPoint, page: PDFPage, pdfView: PDFView) -> CGPoint {
        return pdfView.convert(viewPoint, to: page)
    }
    
    /// Convert a rect from PDF coordinate space to view/screen coordinate space
    /// - Parameters:
    ///   - pdfRect: Rect in PDF coordinate space
    ///   - page: The PDF page containing the rect
    ///   - pdfView: The PDFView instance for conversion
    /// - Returns: Rect in view coordinate space
    static func pdfRectToView(_ pdfRect: CGRect, page: PDFPage, pdfView: PDFView) -> CGRect {
        // Convert all four corners to ensure correct orientation (handles rotation)
        let topLeft = CGPoint(x: pdfRect.minX, y: pdfRect.maxY)
        let topRight = CGPoint(x: pdfRect.maxX, y: pdfRect.maxY)
        let bottomLeft = CGPoint(x: pdfRect.minX, y: pdfRect.minY)
        let bottomRight = CGPoint(x: pdfRect.maxX, y: pdfRect.minY)
        
        let viewTopLeft = pdfView.convert(topLeft, from: page)
        let viewTopRight = pdfView.convert(topRight, from: page)
        let viewBottomLeft = pdfView.convert(bottomLeft, from: page)
        let viewBottomRight = pdfView.convert(bottomRight, from: page)
        
        // Find the bounding box in view coordinates
        let minX = min(viewTopLeft.x, viewTopRight.x, viewBottomLeft.x, viewBottomRight.x)
        let maxX = max(viewTopLeft.x, viewTopRight.x, viewBottomLeft.x, viewBottomRight.x)
        let minY = min(viewTopLeft.y, viewTopRight.y, viewBottomLeft.y, viewBottomRight.y)
        let maxY = max(viewTopLeft.y, viewTopRight.y, viewBottomLeft.y, viewBottomRight.y)
        
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
    
    /// Convert a rect from view/screen coordinate space to PDF coordinate space
    /// - Parameters:
    ///   - viewRect: Rect in view coordinate space
    ///   - page: The PDF page to convert to
    ///   - pdfView: The PDFView instance for conversion
    /// - Returns: Rect in PDF coordinate space
    static func viewRectToPDF(_ viewRect: CGRect, page: PDFPage, pdfView: PDFView) -> CGRect {
        let topLeft = CGPoint(x: viewRect.minX, y: viewRect.minY)
        let bottomRight = CGPoint(x: viewRect.maxX, y: viewRect.maxY)
        
        let pdfTopLeft = pdfView.convert(topLeft, to: page)
        let pdfBottomRight = pdfView.convert(bottomRight, to: page)
        
        return CGRect(
            x: min(pdfTopLeft.x, pdfBottomRight.x),
            y: min(pdfTopLeft.y, pdfBottomRight.y),
            width: abs(pdfTopLeft.x - pdfBottomRight.x),
            height: abs(pdfTopLeft.y - pdfBottomRight.y)
        )
    }
    
    // MARK: - PDF ↔ Normalized Conversions
    
    /// Convert a point from PDF coordinate space to normalized space (0.0 to 1.0)
    /// Normalized space uses bottom-left origin (PDF convention)
    /// - Parameters:
    ///   - pdfPoint: Point in PDF coordinate space
    ///   - page: The PDF page containing the point
    /// - Returns: Normalized point (0.0 to 1.0, bottom-left origin)
    static func pdfToNormalized(_ pdfPoint: CGPoint, page: PDFPage) -> CGPoint {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 && bounds.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: pdfPoint.x / bounds.width,
            y: pdfPoint.y / bounds.height
        )
    }
    
    /// Convert a point from normalized space (0.0 to 1.0) to PDF coordinate space
    /// Normalized space uses bottom-left origin (PDF convention)
    /// - Parameters:
    ///   - normalized: Normalized point (0.0 to 1.0, bottom-left origin)
    ///   - page: The PDF page to convert to
    /// - Returns: Point in PDF coordinate space
    static func normalizedToPDF(_ normalized: CGPoint, page: PDFPage) -> CGPoint {
        let bounds = page.bounds(for: .mediaBox)
        return CGPoint(
            x: normalized.x * bounds.width,
            y: normalized.y * bounds.height
        )
    }
    
    /// Convert a rect from PDF coordinate space to normalized space
    /// - Parameters:
    ///   - pdfRect: Rect in PDF coordinate space
    ///   - page: The PDF page containing the rect
    /// - Returns: Normalized rect (0.0 to 1.0, bottom-left origin)
    static func pdfRectToNormalized(_ pdfRect: CGRect, page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 && bounds.height > 0 else {
            return .zero
        }
        return CGRect(
            x: pdfRect.origin.x / bounds.width,
            y: pdfRect.origin.y / bounds.height,
            width: pdfRect.width / bounds.width,
            height: pdfRect.height / bounds.height
        )
    }
    
    /// Convert a rect from normalized space to PDF coordinate space
    /// - Parameters:
    ///   - normalizedRect: Normalized rect (0.0 to 1.0, bottom-left origin)
    ///   - page: The PDF page to convert to
    /// - Returns: Rect in PDF coordinate space
    static func normalizedRectToPDF(_ normalizedRect: CGRect, page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .mediaBox)
        return CGRect(
            x: normalizedRect.origin.x * bounds.width,
            y: normalizedRect.origin.y * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        )
    }
    
    // MARK: - View ↔ Normalized Conversions (via PDF)
    
    /// Convert a point from view space to normalized space
    /// This is a convenience method that goes through PDF space
    /// - Parameters:
    ///   - viewPoint: Point in view coordinate space
    ///   - page: The PDF page
    ///   - pdfView: The PDFView instance
    /// - Returns: Normalized point (0.0 to 1.0, bottom-left origin)
    static func viewToNormalized(_ viewPoint: CGPoint, page: PDFPage, pdfView: PDFView) -> CGPoint {
        let pdfPoint = viewToPDF(viewPoint, page: page, pdfView: pdfView)
        return pdfToNormalized(pdfPoint, page: page)
    }
    
    /// Convert a point from normalized space to view space
    /// This is a convenience method that goes through PDF space
    /// - Parameters:
    ///   - normalized: Normalized point (0.0 to 1.0, bottom-left origin)
    ///   - page: The PDF page
    ///   - pdfView: The PDFView instance
    /// - Returns: Point in view coordinate space
    static func normalizedToView(_ normalized: CGPoint, page: PDFPage, pdfView: PDFView) -> CGPoint {
        let pdfPoint = normalizedToPDF(normalized, page: page)
        return pdfToView(pdfPoint, page: page, pdfView: pdfView)
    }
    
    // MARK: - Size Conversions
    
    /// Convert a size from PDF space to view space (accounting for zoom)
    /// - Parameters:
    ///   - pdfSize: Size in PDF coordinate space
    ///   - pdfView: The PDFView instance
    /// - Returns: Size in view coordinate space (scaled by zoom)
    static func pdfSizeToView(_ pdfSize: CGSize, pdfView: PDFView) -> CGSize {
        let scale = pdfView.scaleFactor
        return CGSize(width: pdfSize.width * scale, height: pdfSize.height * scale)
    }
    
    /// Convert a size from view space to PDF space (accounting for zoom)
    /// - Parameters:
    ///   - viewSize: Size in view coordinate space
    ///   - pdfView: The PDFView instance
    /// - Returns: Size in PDF coordinate space
    static func viewSizeToPDF(_ viewSize: CGSize, pdfView: PDFView) -> CGSize {
        let scale = pdfView.scaleFactor
        guard scale > 0 else { return .zero }
        return CGSize(width: viewSize.width / scale, height: viewSize.height / scale)
    }
    
    // MARK: - Validation Helpers
    
    /// Validate that a point is within page bounds
    /// - Parameters:
    ///   - pdfPoint: Point in PDF coordinate space
    ///   - page: The PDF page
    /// - Returns: true if point is within page bounds
    static func isValidPDFPoint(_ pdfPoint: CGPoint, page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .mediaBox)
        return pdfPoint.x >= 0 && pdfPoint.x <= bounds.width &&
               pdfPoint.y >= 0 && pdfPoint.y <= bounds.height
    }
    
    /// Clamp a point to page bounds
    /// - Parameters:
    ///   - pdfPoint: Point in PDF coordinate space
    ///   - page: The PDF page
    /// - Returns: Clamped point within page bounds
    static func clampToPageBounds(_ pdfPoint: CGPoint, page: PDFPage) -> CGPoint {
        let bounds = page.bounds(for: .mediaBox)
        return CGPoint(
            x: max(0, min(bounds.width, pdfPoint.x)),
            y: max(0, min(bounds.height, pdfPoint.y))
        )
    }
    
    /// Clamp a rect to page bounds, ensuring it stays within the page
    /// ✅ CRITICAL FIX: Shift-only clamping (prevents box morphing and signature bouncing)
    /// - Parameters:
    ///   - pdfRect: Rect in PDF coordinate space
    ///   - page: The PDF page
    /// - Returns: Clamped rect within page bounds (shifted, NOT resized)
    static func clampRectToPageBounds(_ pdfRect: CGRect, page: PDFPage) -> CGRect {
        let bounds = page.bounds(for: .mediaBox)
        
        // If rect is bigger than the page, then yes — it must shrink.
        // But for normal signatures, it shouldn't ever be bigger, so this is rare.
        let w = min(pdfRect.width, bounds.width)
        let h = min(pdfRect.height, bounds.height)
        
        var x = pdfRect.origin.x
        var y = pdfRect.origin.y
        
        // ✅ CRITICAL: Shift rect inside bounds WITHOUT changing size (prevents morphing/bouncing)
        if x < bounds.minX { x = bounds.minX }
        if y < bounds.minY { y = bounds.minY }
        if x + w > bounds.maxX { x = bounds.maxX - w }
        if y + h > bounds.maxY { y = bounds.maxY - h }
        
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

