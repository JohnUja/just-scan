//
//  Document.swift
//  Just Scan - ENHANCED
//

import Foundation
import UIKit
import PDFKit

struct Document: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    let fileURL: URL
    
    // ✅ Additional metadata
    var pageCount: Int?
    var fileSize: Int64?
    var lastModified: Date?
    var thumbnailURL: URL?
    
    init(id: UUID = UUID(), fileName: String, createdAt: Date = Date(), fileURL: URL) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.fileURL = fileURL
        
        // Auto-populate metadata
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            self.fileSize = attributes[.size] as? Int64
            self.lastModified = attributes[.modificationDate] as? Date
        }
        
        if let pdf = PDFDocument(url: fileURL) {
            self.pageCount = pdf.pageCount
        }
    }
    
    static func generateFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Scan_\(formatter.string(from: Date())).pdf"
    }
    
    // ✅ Human-readable file size
    var fileSizeString: String {
        guard let size = fileSize else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    // ✅ Generate thumbnail
    func generateThumbnail(size: CGSize = CGSize(width: 200, height: 200)) -> UIImage? {
        guard let pdf = PDFDocument(url: fileURL),
              let page = pdf.page(at: 0) else { return nil }
        
        let pageRect = page.bounds(for: .mediaBox)
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let thumbnailSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        return renderer.image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: thumbnailSize))
            
            context.cgContext.translateBy(x: 0, y: thumbnailSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }
}

enum FilterType: String, CaseIterable, Codable {
    case blackAndWhite = "B&W"
    case grayscale = "Grayscale"
    case color = "Color"
    
    var icon: String {
        switch self {
        case .blackAndWhite: return "circle.lefthalf.filled"
        case .grayscale: return "circle.grid.cross"
        case .color: return "paintpalette"
        }
    }
}
