//
//  SignatureCanvasView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

struct SignatureCanvasView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    
    // Optional callback to tell the parent view we finished
    let onSave: (() -> Void)?
    
    @State private var currentDrawing = Drawing()
    @State private var drawings: [Drawing] = []
    
    init(onSave: (() -> Void)? = nil) {
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 1. THE DRAWING CANVAS
                Canvas { context, size in
                    // Draw saved strokes
                    for drawing in drawings {
                        var path = Path()
                        if let first = drawing.points.first {
                            path.move(to: first)
                            for point in drawing.points.dropFirst() {
                                path.addLine(to: point)
                            }
                        }
                        context.stroke(path, with: .color(.white), lineWidth: 3)
                    }
                    // Draw current active stroke
                    if !currentDrawing.points.isEmpty {
                        var path = Path()
                        path.move(to: currentDrawing.points[0])
                        for point in currentDrawing.points.dropFirst() {
                            path.addLine(to: point)
                        }
                        context.stroke(path, with: .color(.white), lineWidth: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black) // Dark Mode Background
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            currentDrawing.points.append(value.location)
                        }
                        .onEnded { _ in
                            if !currentDrawing.points.isEmpty {
                                drawings.append(currentDrawing)
                                currentDrawing = Drawing()
                            }
                        }
                )
                
                // 2. TOOLBAR
                HStack {
                    Button("Clear") {
                        drawings.removeAll()
                        currentDrawing = Drawing()
                    }
                    .foregroundColor(.red)
                    
                    Spacer()
                    
                    Button("Save Signature") {
                        saveSmartSignature()
                    }
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(20)
                }
                .padding()
                .background(Color(uiColor: .systemBackground))
            }
            .navigationTitle("Sign Here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - SMART CROP LOGIC
    private func saveSmartSignature() {
        // Collect all points to find the bounding box
        let allPoints = drawings.flatMap { $0.points } + currentDrawing.points
        guard !allPoints.isEmpty else {
            dismiss()
            return
        }
        
        // 1. Calculate the bounding box of the actual signature
        let xs = allPoints.map { $0.x }
        let ys = allPoints.map { $0.y }
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let maxX = xs.max() ?? 0
        let maxY = ys.max() ?? 0
        
        let width = maxX - minX
        let height = maxY - minY
        
        // 2. Add some breathing room (padding)
        let padding: CGFloat = 20
        let finalSize = CGSize(width: width + (padding * 2), height: height + (padding * 2))
        
        let renderer = UIGraphicsImageRenderer(size: finalSize)
        
        let image = renderer.image { context in
            let ctx = context.cgContext
            
            // 3. SET INK TO BLACK (For Documents)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            
            // 4. Shift the coordinate system so the signature starts at (0,0) + padding
            ctx.translateBy(x: -minX + padding, y: -minY + padding)
            
            // 5. Draw
            for drawing in drawings {
                guard let first = drawing.points.first else { continue }
                ctx.move(to: first)
                for point in drawing.points.dropFirst() {
                    ctx.addLine(to: point)
                }
                ctx.strokePath()
            }
        }
        
        // Save to Service
        signatureService.saveSignature(image)
        dismiss()
        
        // Tell parent we are done
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onSave?()
        }
    }
}

struct Drawing {
    var points: [CGPoint] = []
}