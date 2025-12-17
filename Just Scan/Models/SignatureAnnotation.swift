//
//  SignatureAnnotation.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import Foundation
import CoreGraphics
import UIKit

struct SignatureAnnotation: Codable, Identifiable {
    let id: UUID
    var position: CGPoint
    var size: CGSize
    var rotation: CGFloat
    var strokes: [SignatureStroke]
    var color: SignatureColor
    
    init(id: UUID = UUID(), position: CGPoint, size: CGSize, rotation: CGFloat = 0, strokes: [SignatureStroke], color: SignatureColor = .black) {
        self.id = id
        self.position = position
        self.size = size
        self.rotation = rotation
        self.strokes = strokes
        self.color = color
    }
}

struct SignatureStroke: Codable {
    var points: [CGPoint]
    var lineWidth: CGFloat
    
    init(points: [CGPoint] = [], lineWidth: CGFloat = 3.0) {
        self.points = points
        self.lineWidth = lineWidth
    }
}

enum SignatureColor: String, Codable, CaseIterable {
    case black = "Black"
    case blue = "Blue"
    case red = "Red"
    case green = "Green"
    
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .blue: return .blue
        case .red: return .red
        case .green: return .green
        }
    }
}

