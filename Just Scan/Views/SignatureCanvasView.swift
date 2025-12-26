//
//  SignatureCanvasView.swift
//  Just Scan - ENHANCED VERSION
//

import SwiftUI

struct SignatureCanvasView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    
    let onSave: (() -> Void)?
    
    @State private var currentDrawing = Drawing()
    @State private var drawings: [Drawing] = []
    
    // ✅ Undo/Redo support
    @State private var undoStack: [[Drawing]] = []
    @State private var redoStack: [[Drawing]] = []
    
    // ✅ Stroke customization
    @State private var strokeWidth: CGFloat = 3.0
    @State private var showStrokeOptions = false
    
    init(onSave: (() -> Void)? = nil) {
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Canvas
                Canvas { context, size in
                    for drawing in drawings {
                        drawStroke(context: context, points: drawing.points, width: drawing.lineWidth)
                    }
                    drawStroke(context: context, points: currentDrawing.points, width: strokeWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            currentDrawing.points.append(value.location)
                        }
                        .onEnded { _ in
                            if !currentDrawing.points.isEmpty {
                                registerUndo()
                                currentDrawing.lineWidth = strokeWidth
                                drawings.append(currentDrawing)
                                currentDrawing = Drawing()
                            }
                        }
                )
                
                // Stroke Width Picker
                if showStrokeOptions {
                    VStack(spacing: 8) {
                        Text("Stroke Width: \(Int(strokeWidth))")
                            .foregroundColor(.white)
                            .font(.caption)
                        
                        Slider(value: $strokeWidth, in: 1...10, step: 1)
                            .tint(.blue)
                            .padding(.horizontal)
                    }
                    .padding(.vertical, 8)
                    .background(Color(white: 0.2))
                    .transition(.move(edge: .bottom))
                }
                
                // Toolbar
                HStack(spacing: 16) {
                    // Undo
                    Button {
                        undoAction()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundColor(undoStack.isEmpty ? .gray : .white)
                    }
                    .disabled(undoStack.isEmpty)
                    
                    // Redo
                    Button {
                        redoAction()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .foregroundColor(redoStack.isEmpty ? .gray : .white)
                    }
                    .disabled(redoStack.isEmpty)
                    
                    Divider()
                        .frame(height: 20)
                        .background(Color.white.opacity(0.3))
                    
                    // Stroke Width Toggle
                    Button {
                        withAnimation {
                            showStrokeOptions.toggle()
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.white)
                    }
                    
                    Divider()
                        .frame(height: 20)
                        .background(Color.white.opacity(0.3))
                    
                    // Clear
                    Button("Clear") {
                        registerUndo()
                        drawings.removeAll()
                        currentDrawing = Drawing()
                    }
                    .foregroundColor(.red)
                    .disabled(drawings.isEmpty && currentDrawing.points.isEmpty)
                    
                    Spacer()
                    
                    // Save
                    Button("Save Signature") {
                        saveSignature()
                    }
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(drawings.isEmpty && currentDrawing.points.isEmpty ? Color.gray : Color.blue)
                    .cornerRadius(20)
                    .disabled(drawings.isEmpty && currentDrawing.points.isEmpty)
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
    
    // MARK: - Drawing
    
    private func drawStroke(context: GraphicsContext, points: [CGPoint], width: CGFloat) {
        guard !points.isEmpty else { return }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    
    // MARK: - Undo/Redo
    
    private func registerUndo() {
        undoStack.append(drawings)
        redoStack.removeAll()
    }
    
    private func undoAction() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(drawings)
        drawings = previous
    }
    
    private func redoAction() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawings)
        drawings = next
    }
    
    // MARK: - Save
    
    private func saveSignature() {
        let allPoints = drawings.flatMap { $0.points } + currentDrawing.points
        guard !allPoints.isEmpty else {
            dismiss()
            return
        }
        
        let xs = allPoints.map { $0.x }
        let ys = allPoints.map { $0.y }
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        let maxX = xs.max() ?? 0
        let maxY = ys.max() ?? 0
        
        let drawingWidth = maxX - minX
        let drawingHeight = maxY - minY
        
        let padding: CGFloat = 20
        let renderSize = CGSize(width: drawingWidth + (padding * 2), height: drawingHeight + (padding * 2))
        
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        
        let image = renderer.image { context in
            let ctx = context.cgContext
            
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            
            ctx.translateBy(x: -minX + padding, y: -minY + padding)
            
            for drawing in drawings {
                guard let first = drawing.points.first else { continue }
                ctx.setLineWidth(drawing.lineWidth)
                ctx.move(to: first)
                for point in drawing.points.dropFirst() {
                    ctx.addLine(to: point)
                }
                ctx.strokePath()
            }
        }
        
        signatureService.saveSignature(image)
        dismiss()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onSave?()
        }
    }
}

struct Drawing {
    var points: [CGPoint] = []
    var lineWidth: CGFloat = 3.0
}
