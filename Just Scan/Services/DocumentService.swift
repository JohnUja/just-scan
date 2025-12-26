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
        
        let context = CIContext(options: nil)
        let ciImage = CIImage(cgImage: cgImage)
        
        let filter: CIFilter?
        
        switch filterType {
        case .blackAndWhite:
            // High contrast black and white
            filter = CIFilter(name: "CIColorControls")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(1.5, forKey: kCIInputContrastKey) // High contrast
            filter?.setValue(0.0, forKey: kCIInputSaturationKey) // Remove color
            
        case .grayscale:
            filter = CIFilter(name: "CIColorControls")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(0.0, forKey: kCIInputSaturationKey) // Remove color
            
        case .color:
            return image
        }
        
        guard let filter = filter,
              let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Flatten and Compress
    // Renders each page to an image, downscales, JPEG-compresses, and reassembles into a PDF.
    // Use for export/share to make signatures non-editable and shrink file size.
    func flattenAndCompress(pdfDocument: PDFDocument,
                            maxDimension: CGFloat = 2000,
                            jpegQuality: CGFloat = 0.6) -> PDFDocument? {
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
            
            // Render page into downscaled image
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
// ✅ ACTUALLY APPLY FILTERS TO PDF

func applyFilter(to pdfDocument: PDFDocument, filterType: FilterType) -> PDFDocument {
    guard filterType != .color else {
        return pdfDocument // No processing for color
    }
    
    let filteredPDF = PDFDocument()
    
    for pageIndex in 0..<pdfDocument.pageCount {
        guard let page = pdfDocument.page(at: pageIndex) else { continue }
        
        let pageRect = page.bounds(for: .mediaBox)
        
        // ✅ High-resolution rendering (3x scale for quality)
        let scale: CGFloat = 3.0
        let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        
        let image = renderer.image { context in
            // White background to avoid transparency issues
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: renderSize))
            
            context.cgContext.translateBy(x: 0, y: renderSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        
        let filteredImage = applyImageFilter(to: image, filterType: filterType)
        
        if let filteredPage = PDFPage(image: filteredImage) {
            filteredPDF.insert(filteredPage, at: filteredPDF.pageCount)
        }
    }
    
    return filteredPDF
}

// ✅ Enhanced filter implementation
private func applyImageFilter(to image: UIImage, filterType: FilterType) -> UIImage {
    guard let cgImage = image.cgImage else { return image }
    
    let context = CIContext(options: [.useSoftwareRenderer: false])
    let ciImage = CIImage(cgImage: cgImage)
    
    let filteredCIImage: CIImage
    
    switch filterType {
    case .blackAndWhite:
        // High contrast B&W for document scanning
        guard let contrastFilter = CIFilter(name: "CIColorControls") else { return image }
        contrastFilter.setValue(ciImage, forKey: kCIInputImageKey)
        contrastFilter.setValue(1.8, forKey: kCIInputContrastKey) // High contrast
        contrastFilter.setValue(0.0, forKey: kCIInputSaturationKey) // Remove color
        contrastFilter.setValue(0.1, forKey: kCIInputBrightnessKey) // Slight brightness boost
        
        guard let bwImage = contrastFilter.outputImage,
              let thresholdFilter = CIFilter(name: "CIColorThreshold") else { return image }
        
        thresholdFilter.setValue(bwImage, forKey: kCIInputImageKey)
        thresholdFilter.setValue(0.5, forKey: "inputThreshold")
        
        filteredCIImage = thresholdFilter.outputImage ?? bwImage
        
    case .grayscale:
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        filter.setValue(1.1, forKey: kCIInputContrastKey) // Slight contrast boost
        
        filteredCIImage = filter.outputImage ?? ciImage
        
    case .color:
        return image
    }
    
    guard let outputCGImage = context.createCGImage(filteredCIImage, from: filteredCIImage.extent) else {
        return image
    }
    
    return UIImage(cgImage: outputCGImage)
}


