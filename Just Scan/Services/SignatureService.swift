//
//  SignatureService.swift
//  Just Scan - FIXED VERSION
//

import Foundation
import UIKit
import SwiftUI

@MainActor
class SignatureService: ObservableObject {
    static let shared = SignatureService()
    
    // Prepare directories once to avoid repeated disk writes
    private static let preparedPaths: (signaturesDirectory: URL, metadataURL: URL) = {
        let fm = FileManager.default
        let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let signaturesDirectory = documentsDirectory.appendingPathComponent("Signatures", isDirectory: true)
        let metadataURL = signaturesDirectory.appendingPathComponent("metadata.json")
        
        if !fm.fileExists(atPath: signaturesDirectory.path) {
            do {
                try fm.createDirectory(at: signaturesDirectory, withIntermediateDirectories: true)
            } catch {
                print("❌ Failed to create signatures directory: \(error)")
            }
        }
        return (signaturesDirectory, metadataURL)
    }()
    
    
    @Published var signatureHistory: [SavedSignature] = []
    @Published var currentSignatureID: UUID?
    
    private let fileManager = FileManager.default
    private let signaturesDirectory: URL
    private let metadataURL: URL
    
    // Computed property for backward compatibility
    var signatureImage: UIImage? {
        guard let id = currentSignatureID,
              let signature = signatureHistory.first(where: { $0.id == id }) else {
            return signatureHistory.last?.image // Fallback to most recent
        }
        return signature.image
    }
    
    var hasSignature: Bool {
        !signatureHistory.isEmpty
    }
    
    private init() {
        signaturesDirectory = SignatureService.preparedPaths.signaturesDirectory
        metadataURL = SignatureService.preparedPaths.metadataURL
        
        loadSignatures()
    }
    
    
    func saveSignature(_ image: UIImage, name: String? = nil) {
        let signature = SavedSignature(
            id: UUID(),
            image: image,
            name: name ?? "Signature \(signatureHistory.count + 1)",
            createdAt: Date()
        )
        
        // Save image
        guard let data = image.pngData() else { return }
        let fileURL = signatureURL(for: signature.id)
        
        do {
            try data.write(to: fileURL)
            signatureHistory.append(signature)
            currentSignatureID = signature.id
            saveMetadata()
            objectWillChange.send()
        } catch {
            print("❌ Failed to save signature: \(error)")
        }
    }
    
    
    func loadSignatures() {
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([SignatureMetadata].self, from: metadataData) else {
            // Migration: Load old single signature if exists
            migrateOldSignature()
            return
        }
        
        signatureHistory = metadata.compactMap { meta in
            let fileURL = signatureURL(for: meta.id)
            guard let imageData = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: imageData) else {
                return nil
            }
            return SavedSignature(
                id: meta.id,
                image: image,
                name: meta.name,
                createdAt: meta.createdAt
            )
        }
        
        currentSignatureID = metadata.first?.id
    }
    
    
    private func migrateOldSignature() {
        let oldURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("signature.png")
        
        guard let data = try? Data(contentsOf: oldURL),
              let image = UIImage(data: data) else {
            return
        }
        
        saveSignature(image, name: "Migrated Signature")
        try? fileManager.removeItem(at: oldURL)
    }
    
   
    func deleteSignature(_ id: UUID) {
        signatureHistory.removeAll { $0.id == id }
        let fileURL = signatureURL(for: id)
        try? fileManager.removeItem(at: fileURL)
        
        if currentSignatureID == id {
            currentSignatureID = signatureHistory.last?.id
        }
        
        saveMetadata()
    }
    
    
    func clearSignature() {
        signatureHistory.forEach { signature in
            let fileURL = signatureURL(for: signature.id)
            try? fileManager.removeItem(at: fileURL)
        }
        signatureHistory.removeAll()
        currentSignatureID = nil
        try? fileManager.removeItem(at: metadataURL)
    }
    
    
    func selectSignature(_ id: UUID) {
        guard signatureHistory.contains(where: { $0.id == id }) else { return }
        currentSignatureID = id
        objectWillChange.send()
    }
    
    // MARK: - Private Helpers
    
    private func signatureURL(for id: UUID) -> URL {
        signaturesDirectory.appendingPathComponent("\(id.uuidString).png")
    }
    
    private func saveMetadata() {
        let metadata = signatureHistory.map { SignatureMetadata(id: $0.id, name: $0.name, createdAt: $0.createdAt) }
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL)
    }
}

// MARK: - Data Models

struct SavedSignature: Identifiable {
    let id: UUID
    let image: UIImage
    let name: String
    let createdAt: Date
}

struct SignatureMetadata: Codable {
    let id: UUID
    let name: String
    let createdAt: Date
}
