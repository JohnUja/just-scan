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
    
    // Optional callback if you want to trigger something after save
    let onSave: (() -> Void)?
    
    @State private var currentDrawing = Drawing()
    @State private var drawings: [Drawing] = []
    
    init(onSave: (() -> Void)? = nil) {
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Canvas
                Canvas { context, size in
                    // Draw existing strokes
                    for drawing in drawings {
                        drawStroke(context: context, points: drawing.points)
                    }
                    // Draw active stroke
                    drawStroke(context: context, points: currentDrawing.points)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black) // Dark UI for contrast
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
                
                // Toolbar
                HStack {
                    Button("Clear") {
                        drawings.removeAll()
                        currentDrawing = Drawing()
                    }
                    .foregroundColor(.red)
                    
                    Spacer()
                    
                    Button("Save Signature") {
                        saveSignature()
                    }
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
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
    
    private func drawStroke(context: GraphicsContext, points: [CGPoint]) {
        guard !points.isEmpty else { return }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(.white), lineWidth: 3)
    }
    
    private func saveSignature() {
        let allPoints = drawings.flatMap { $0.points } + currentDrawing.points
        guard !allPoints.isEmpty else {
            dismiss()
            return
        }
        
        // 1. Calculate Bounding Box of the drawing
        let xs = allPoints.map { $0.x }
        let ys = allPoints.map { $0.y }
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let maxX = xs.max() ?? 0
        let maxY = ys.max() ?? 0
        
        let drawingWidth = maxX - minX
        let drawingHeight = maxY - minY
        
        // Add padding
        let padding: CGFloat = 20
        let renderSize = CGSize(width: drawingWidth + (padding * 2), height: drawingHeight + (padding * 2))
        
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        
        let image = renderer.image { context in
            let ctx = context.cgContext
            
            // 2. Set Ink to BLACK (for documents)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            
            // 3. Translate context so the drawing starts at (padding, padding)
            ctx.translateBy(x: -minX + padding, y: -minY + padding)
            
            // 4. Draw
            for drawing in drawings {
                guard let first = drawing.points.first else { continue }
                ctx.move(to: first)
                for point in drawing.points.dropFirst() {
                    ctx.addLine(to: point)
                }
                ctx.strokePath()
            }
        }
        
        signatureService.saveSignature(image)
        dismiss()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            onSave?()
        }
    }
}

struct Drawing {
    var points: [CGPoint] = []
}