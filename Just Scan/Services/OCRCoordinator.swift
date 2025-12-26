//
//  OCRCoordinator.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-21.
//

import Foundation
import Vision
import CoreImage
import UIKit

@MainActor
class OCRCoordinator: ObservableObject {
    @Published var resultText: String?
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false
    
    func performOCR(cgImage: CGImage) {
        resultText = nil
        errorMessage = nil
        isProcessing = true
        
        Task {
            do {
                let text = try await performVisionRequest(on: cgImage)
                self.resultText = text
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isProcessing = false
        }
    }
    
    private nonisolated func performVisionRequest(on cgImage: CGImage) async throws -> String {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        try requestHandler.perform([request])
        
        guard let observations = request.results else {
            throw NSError(domain: "OCR", code: 0, userInfo: [NSLocalizedDescriptionKey: "No text found"])
        }
        
        let extractedText = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if extractedText.isEmpty {
            throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "No text could be extracted"])
        }
        
        return extractedText
    }
}


