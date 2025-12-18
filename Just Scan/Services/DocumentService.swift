//
//  DocumentService.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import Foundation
import PDFKit
import UIKit

@MainActor
class DocumentService: ObservableObject {
    static let shared = DocumentService()
    
    @Published var documents: [Document] = []
    
    private let documentsDirectory: URL
    
    private init() {
        let fileManager = FileManager.default
        documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        loadDocuments()
    }
    
    func loadDocuments() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }
        
        documents = files
            .filter { $0.pathExtension == "pdf" }
            .compactMap { url in
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let creationDate = attributes[.creationDate] as? Date else {
                    return nil
                }
                return Document(
                    fileName: url.lastPathComponent,
                    createdAt: creationDate,
                    fileURL: url
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
    
    // MARK: - COMPRESSED SAVE FUNCTION
    func savePDF(_ pdfDocument: PDFDocument, filterType: FilterType = .blackAndWhite) throws -> Document {
        let fileName = Document.generateFileName()
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        
        // 1. Create a NEW PDF for the compressed output
        let compressedPDF = PDFDocument()
        
        // 2. Loop through pages and compress each one
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            
            // Get the image from the page
            let pageRect = page.bounds(for: .mediaBox)
            let renderer = UIGraphicsImageRenderer(size: pageRect.size)
            let image = renderer.image { ctx in
                UIColor.white.set()
                ctx.fill(pageRect)
                ctx.cgContext.translateBy(x: 0, y: pageRect.height)
                ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                page.draw(with: .mediaBox, to: ctx.cgContext)
            }
            
            // 3. COMPRESSION MAGIC (0.7 quality is the sweet spot)
            if let compressedData = image.jpegData(compressionQuality: 0.7),
               let compressedImage = UIImage(data: compressedData),
               let newPage = PDFPage(image: compressedImage) {
                compressedPDF.insert(newPage, at: compressedPDF.pageCount)
            }
        }
        
        // 4. Save the smaller PDF
        guard compressedPDF.write(to: fileURL) else {
            throw DocumentError.saveFailed
        }
        
        let document = Document(fileName: fileName, fileURL: fileURL)
        documents.insert(document, at: 0)
        return document
    }
    
    func deleteDocument(_ document: Document) throws {
        let fileManager = FileManager.default
        try fileManager.removeItem(at: document.fileURL)
        documents.removeAll { $0.id == document.id }
    }
    
    func renameDocument(_ document: Document, newName: String) throws {
        let newURL = documentsDirectory.appendingPathComponent(newName)
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: newURL.path) {
            throw DocumentError.nameExists
        }
        
        try fileManager.moveItem(at: document.fileURL, to: newURL)
        
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = Document(
                id: document.id,
                fileName: newName,
                createdAt: document.createdAt,
                fileURL: newURL
            )
        }
    }
}

enum FilterType {
    case original
    case blackAndWhite
    case grayscale
    case color
}

enum DocumentError: LocalizedError {
    case saveFailed
    case nameExists
    
    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Failed to save document"
        case .nameExists: return "A document with this name already exists"
        }
    }
}