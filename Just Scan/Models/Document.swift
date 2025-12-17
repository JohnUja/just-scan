//
//  Document.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import Foundation
import UIKit

struct Document: Identifiable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    let fileURL: URL
    
    init(id: UUID = UUID(), fileName: String, createdAt: Date = Date(), fileURL: URL) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.fileURL = fileURL
    }
    
    static func generateFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Scan_\(formatter.string(from: Date())).pdf"
    }
}

enum FilterType: String, CaseIterable {
    case blackAndWhite = "B&W"
    case grayscale = "Grayscale"
    case color = "Color"
}

