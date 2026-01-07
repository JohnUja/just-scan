//
//  DocumentSignatureStore.swift
//  Just Scan
//
//  Persistence layer for signature placements per document.
//  Stores [SignatureModel] as JSON, keyed by documentID.
//
//  CRITICAL GUARDRAIL: This is the ONLY persistence mechanism for signatures during editing.
//  PDFKit annotations are NEVER used for runtime state - only for export.
//

import Foundation
import UIKit

/// Manages signature placement persistence for documents.
/// Each document has its own placements.json file stored alongside it.
@MainActor
class DocumentSignatureStore: ObservableObject {
    
    static let shared = DocumentSignatureStore()
    
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    /// Cache of loaded signatures per document ID (avoids repeated disk reads)
    private var cache: [UUID: [Int: [SignatureModel]]] = [:]
    
    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    
    // MARK: - Public API
    
    /// Load signatures for a document. Returns empty dictionary if none exist.
    /// - Parameter document: The document to load signatures for
    /// - Returns: Dictionary of page index to signature models
    func loadSignatures(for document: Document) -> [Int: [SignatureModel]] {
        // Check cache first
        if let cached = cache[document.id] {
            return cached
        }
        
        let storageURL = signatureStorageURL(for: document)
        
        guard fileManager.fileExists(atPath: storageURL.path) else {
            // No signatures yet - return empty
            return [:]
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            let wrapper = try decoder.decode(SignaturePlacementsWrapper.self, from: data)
            
            // Convert array-based storage to dictionary format
            var result: [Int: [SignatureModel]] = [:]
            for placement in wrapper.placements {
                if result[placement.pageIndex] == nil {
                    result[placement.pageIndex] = []
                }
                result[placement.pageIndex]?.append(placement.toSignatureModel())
            }
            
            // Update cache
            cache[document.id] = result
            
            print("✅ Loaded \(wrapper.placements.count) signatures for document \(document.id)")
            return result
            
        } catch {
            print("❌ Failed to load signatures: \(error)")
            return [:]
        }
    }
    
    /// Save signatures for a document.
    /// - Parameters:
    ///   - signatures: Dictionary of page index to signature models
    ///   - document: The document to save signatures for
    /// - Returns: True if save succeeded
    @discardableResult
    func saveSignatures(_ signatures: [Int: [SignatureModel]], for document: Document) -> Bool {
        let storageURL = signatureStorageURL(for: document)
        
        // Ensure directory exists
        let directoryURL = storageURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                print("❌ Failed to create signatures directory: \(error)")
                return false
            }
        }
        
        // Convert dictionary to array format for storage
        var placements: [SignaturePlacement] = []
        for (pageIndex, models) in signatures {
            for model in models {
                placements.append(SignaturePlacement(from: model, pageIndex: pageIndex))
            }
        }
        
        let wrapper = SignaturePlacementsWrapper(
            version: 1,
            documentID: document.id.uuidString,
            placements: placements
        )
        
        do {
            let data = try encoder.encode(wrapper)
            try data.write(to: storageURL, options: .atomic)
            
            // Update cache
            cache[document.id] = signatures
            
            print("✅ Saved \(placements.count) signatures for document \(document.id)")
            return true
            
        } catch {
            print("❌ Failed to save signatures: \(error)")
            return false
        }
    }
    
    /// Delete all signatures for a document (called when document is deleted)
    func deleteSignatures(for document: Document) {
        let storageURL = signatureStorageURL(for: document)
        
        do {
            if fileManager.fileExists(atPath: storageURL.path) {
                try fileManager.removeItem(at: storageURL)
            }
            // Also try to remove the directory if empty
            let directoryURL = storageURL.deletingLastPathComponent()
            let contents = try? fileManager.contentsOfDirectory(atPath: directoryURL.path)
            if contents?.isEmpty == true {
                try? fileManager.removeItem(at: directoryURL)
            }
            
            // Clear cache
            cache.removeValue(forKey: document.id)
            
            print("✅ Deleted signatures for document \(document.id)")
        } catch {
            print("❌ Failed to delete signatures: \(error)")
        }
    }
    
    /// Clear cache for a document (call when document is closed)
    func clearCache(for document: Document) {
        cache.removeValue(forKey: document.id)
    }
    
    /// Clear all caches
    func clearAllCaches() {
        cache.removeAll()
    }
    
    // MARK: - Private Helpers
    
    /// Get the storage URL for a document's signatures
    private func signatureStorageURL(for document: Document) -> URL {
        // Store in a folder named after the document ID, alongside the documents
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let signatureDataDirectory = documentsDirectory.appendingPathComponent("SignatureData", isDirectory: true)
        let documentDirectory = signatureDataDirectory.appendingPathComponent(document.id.uuidString, isDirectory: true)
        return documentDirectory.appendingPathComponent("placements.json")
    }
}

// MARK: - Storage Models

/// Wrapper for the placements.json file
private struct SignaturePlacementsWrapper: Codable {
    let version: Int
    let documentID: String
    let placements: [SignaturePlacement]
}

/// Individual signature placement (Codable version of SignatureModel)
private struct SignaturePlacement: Codable {
    let id: String
    let pageIndex: Int
    let centerX: CGFloat
    let centerY: CGFloat
    let widthRatio: CGFloat
    let rotation: CGFloat
    let color: String
    let imageID: String
    let aspectRatio: CGFloat
    
    init(from model: SignatureModel, pageIndex: Int) {
        self.id = model.id.uuidString
        self.pageIndex = pageIndex
        self.centerX = model.center.x
        self.centerY = model.center.y
        self.widthRatio = model.widthRatio
        self.rotation = model.rotation
        self.color = model.color.rawValue
        self.imageID = model.imageID
        self.aspectRatio = model.aspectRatio
    }
    
    func toSignatureModel() -> SignatureModel {
        SignatureModel(
            id: UUID(uuidString: id) ?? UUID(),
            center: CGPoint(x: centerX, y: centerY),
            widthRatio: widthRatio,
            rotation: rotation,
            color: SignatureColor(rawValue: color) ?? .black,
            imageID: imageID,
            aspectRatio: aspectRatio,
            isCommitted: false,  // All signatures are "uncommitted" in the new architecture
            annotationID: nil    // No annotation IDs in the new architecture
        )
    }
}

