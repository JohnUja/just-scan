//
//  SignatureService.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import Foundation
import UIKit

@MainActor
class SignatureService: ObservableObject {
    static let shared = SignatureService()
    
    @Published var signatureImage: UIImage?
    
    private let signatureKey = "savedSignature"
    private let fileManager = FileManager.default
    
    private var signatureURL: URL {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("signature.png")
    }
    
    private init() {
        loadSignature()
    }
    
    func saveSignature(_ image: UIImage) {
        guard let data = image.pngData() else { return }
        
        do {
            try data.write(to: signatureURL)
            signatureImage = image
        } catch {
            print("Failed to save signature: \(error)")
        }
    }
    
    func loadSignature() {
        guard let data = try? Data(contentsOf: signatureURL),
              let image = UIImage(data: data) else {
            return
        }
        signatureImage = image
    }
    
    func clearSignature() {
        try? fileManager.removeItem(at: signatureURL)
        signatureImage = nil
    }
    
    var hasSignature: Bool {
        signatureImage != nil
    }
}

