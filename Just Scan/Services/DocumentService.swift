//
//  DocumentService.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import Foundation
import PDFKit

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
            .sorted { $0.createdAt > $1.createdAt } // Newest first
    }
    
    func savePDF(_ pdfDocument: PDFDocument, filterType: FilterType = .blackAndWhite) throws -> Document {
        let fileName = Document.generateFileName()
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        
        // Apply filter to PDF pages
        let processedPDF = applyFilter(to: pdfDocument, filterType: filterType)
        
        // Save PDF
        guard processedPDF.write(to: fileURL) else {
            throw DocumentError.saveFailed
        }
        
        let document = Document(fileName: fileName, fileURL: fileURL)
        documents.insert(document, at: 0) // Insert at beginning (newest first)
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
        
        // Check if new name already exists
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
    
    func applyFilter(to pdfDocument: PDFDocument, filterType: FilterType) -> PDFDocument {
        guard filterType != .color else {
            return pdfDocument // No processing needed for color
        }
        
        let filteredPDF = PDFDocument()
        
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            
            let pageRect = page.bounds(for: .mediaBox)
            // Use opaque rendering to avoid alpha channel issues
            let renderer = UIGraphicsImageRenderer(size: pageRect.size)
            
            let image = renderer.image { context in
                context.cgContext.translateBy(x: 0, y: pageRect.height)
                context.cgContext.scaleBy(x: 1.0, y: -1.0)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            
            let filteredImage = applyFilter(to: image, filterType: filterType)
            
            // Convert to non-alpha image to avoid PDF warnings
            if let cgImage = filteredImage.cgImage {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let context = CGContext(
                    data: nil,
                    width: cgImage.width,
                    height: cgImage.height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
                
                if let context = context {
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                    if let finalImage = context.makeImage() {
                        let uiImage = UIImage(cgImage: finalImage)
                        if let filteredPage = PDFPage(image: uiImage) {
                            filteredPDF.insert(filteredPage, at: filteredPDF.pageCount)
                        }
                    }
                }
            }
        }
        
        return filteredPDF
    }
    
    private func applyFilter(to image: UIImage, filterType: FilterType) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let ciImage = CIImage(cgImage: cgImage)

        let filteredCIImage: CIImage

        switch filterType {
        case .blackAndWhite:
            guard let controls = CIFilter(name: "CIColorControls") else { return image }
            controls.setValue(ciImage, forKey: kCIInputImageKey)
            controls.setValue(1.8, forKey: kCIInputContrastKey)
            controls.setValue(0.0, forKey: kCIInputSaturationKey)
            controls.setValue(0.1, forKey: kCIInputBrightnessKey)
            filteredCIImage = controls.outputImage ?? ciImage

        case .grayscale:
            guard let controls = CIFilter(name: "CIColorControls") else { return image }
            controls.setValue(ciImage, forKey: kCIInputImageKey)
            controls.setValue(0.0, forKey: kCIInputSaturationKey)
            controls.setValue(1.1, forKey: kCIInputContrastKey)
            filteredCIImage = controls.outputImage ?? ciImage

        case .color:
            return image
        }

        guard let outputCGImage = context.createCGImage(filteredCIImage, from: filteredCIImage.extent) else {
            return image
        }
        return UIImage(cgImage: outputCGImage)
    }

    // MARK: - Flatten and Compress
    // Renders each page to an image, downscales, JPEG-compresses, and reassembles into a PDF.
    // Use for export/share to make signatures non-editable and shrink file size.
    func flattenAndCompress(pdfDocument: PDFDocument,
                            maxDimension: CGFloat = 4000,
                            jpegQuality: CGFloat = 0.9) -> PDFDocument? {
        let outputData = NSMutableData()
        guard let consumer = CGDataConsumer(data: outputData as CFMutableData) else { return nil }
        guard let firstPage = pdfDocument.page(at: 0) else { return nil }
        var mediaBox = firstPage.bounds(for: .mediaBox)
        
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        
        for index in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: index) else { continue }
            let pageRect = page.bounds(for: .mediaBox)
            let scale = min(1.0, maxDimension / max(pageRect.width, pageRect.height))
            let targetSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let targetBox = CGRect(origin: .zero, size: targetSize)
            
            context.beginPDFPage([kCGPDFContextMediaBox as String: targetBox] as CFDictionary)
            
            // Render page into high-quality image
            let image = UIGraphicsImageRenderer(size: targetSize).image { ctx in
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: 0, y: targetSize.height)
                ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                ctx.cgContext.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
            
            guard let jpegData = image.jpegData(compressionQuality: jpegQuality),
                  let compressed = UIImage(data: jpegData)?.cgImage else {
                context.endPDFPage()
                continue
            }
            
            context.draw(compressed, in: targetBox)
            context.endPDFPage()
        }
        
        context.closePDF()
        
        return PDFDocument(data: outputData as Data)
    }
}

enum DocumentError: LocalizedError {
    case saveFailed
    case nameExists
    
    var errorDescription: String? {
        switch self {
        case .saveFailed:
            return "Failed to save document"
        case .nameExists:
            return "A document with this name already exists"
        }
    }
}


