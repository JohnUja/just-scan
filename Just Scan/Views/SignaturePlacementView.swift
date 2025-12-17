//
//  SignaturePlacementView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import PDFKit
import UIKit

struct SignaturePlacementView: View {
    let document: Document
    let signatureImage: UIImage
    @Environment(\.dismiss) var dismiss
    
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex = 0
    @State private var signaturePosition: CGPoint = CGPoint(x: 0.5, y: 0.5) // Normalized (0-1)
    @State private var signatureSize: CGSize = CGSize(width: 200, height: 100)
    @State private var dragOffset: CGSize = .zero
    @State private var signatureRotation: CGFloat = 0
    @State private var isSelected = true
    @State private var showColorPicker = false
    @State private var selectedColor: SignatureColor = .black
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                mainContent
            }
            .navigationTitle("Place Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        applySignature()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                loadPDF()
            }
            .confirmationDialog("Signature Color", isPresented: $showColorPicker) {
                ForEach(SignatureColor.allCases, id: \.self) { color in
                    Button(color.rawValue) {
                        selectedColor = color
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        if let pdfDocument = pdfDocument {
            PDFViewRepresentable(
                pdfDocument: pdfDocument,
                pageIndex: $currentPageIndex
            )
            .ignoresSafeArea()
            signatureOverlay(pdfDocument: pdfDocument)
        } else {
            ProgressView()
        }
    }
    
    private func signatureOverlay(pdfDocument: PDFDocument) -> some View {
        GeometryReader { geometry in
            let pageRect = pdfDocument.page(at: currentPageIndex)?.bounds(for: .mediaBox) ?? .zero
            let scale = min(geometry.size.width / pageRect.width, geometry.size.height / pageRect.height)
            let offsetX = (geometry.size.width - pageRect.width * scale) / 2
            let offsetY = (geometry.size.height - pageRect.height * scale) / 2
            
            let x = signaturePosition.x * pageRect.width * scale + offsetX
            let y = signaturePosition.y * pageRect.height * scale + offsetY
            
            signatureContentView(
                x: x,
                y: y,
                scale: scale,
                offsetX: offsetX,
                offsetY: offsetY,
                pageRect: pageRect
            )
        }
    }
    
    private func signatureContentView(x: CGFloat, y: CGFloat, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat, pageRect: CGRect) -> some View {
        ZStack {
            signatureImage(x: x, y: y, scale: scale)
            
            if isSelected {
                selectionControls(
                    x: x,
                    y: y,
                    scale: scale,
                    offsetX: offsetX,
                    offsetY: offsetY,
                    pageRect: pageRect
                )
            }
        }
        .onTapGesture {
            isSelected = true
        }
        .gesture(dragGesture(x: x, y: y, scale: scale, offsetX: offsetX, offsetY: offsetY, pageRect: pageRect))
    }
    
    private func signatureImage(x: CGFloat, y: CGFloat, scale: CGFloat) -> some View {
        Image(uiImage: signatureImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: signatureSize.width * scale, height: signatureSize.height * scale)
            .rotationEffect(.degrees(signatureRotation))
            .position(x: x, y: y)
            .opacity(1.0)
    }
    
    @ViewBuilder
    private func selectionControls(x: CGFloat, y: CGFloat, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat, pageRect: CGRect) -> some View {
        SelectionBoxView(
            position: CGPoint(x: x, y: y),
            size: CGSize(width: signatureSize.width * scale, height: signatureSize.height * scale),
            rotation: signatureRotation,
            onMove: { delta in
                updatePosition(x: x, y: y, delta: delta, scale: scale, offsetX: offsetX, offsetY: offsetY, pageRect: pageRect)
            },
            onResize: { newSize in
                signatureSize = CGSize(
                    width: max(50, min(400, newSize.width / scale)),
                    height: max(30, min(200, newSize.height / scale))
                )
            },
            onRotate: { angle in
                signatureRotation += angle
            }
        )
        
        FloatingToolbarView(
            position: CGPoint(x: x, y: y - signatureSize.height * scale / 2 - 60),
            onColor: { showColorPicker = true },
            onDelete: {
                dismiss()
            },
            onDuplicate: {
                // Duplicate functionality
            }
        )
    }
    
    private func dragGesture(x: CGFloat, y: CGFloat, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat, pageRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if isSelected {
                    // Calculate new position in screen coordinates
                    let newScreenX = x + value.translation.width
                    let newScreenY = y + value.translation.height
                    
                    // Convert back to normalized coordinates (0-1)
                    let newX = (newScreenX - offsetX) / (pageRect.width * scale)
                    let newY = (newScreenY - offsetY) / (pageRect.height * scale)
                    
                    // Clamp to page bounds
                    signaturePosition = CGPoint(
                        x: max(0, min(1, newX)),
                        y: max(0, min(1, newY))
                    )
                }
            }
    }
    
    private func updatePosition(x: CGFloat, y: CGFloat, delta: CGSize, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat, pageRect: CGRect) {
        // Calculate new position in screen coordinates
        let newScreenX = x + delta.width
        let newScreenY = y + delta.height
        
        // Convert back to normalized coordinates
        let newX = (newScreenX - offsetX) / (pageRect.width * scale)
        let newY = (newScreenY - offsetY) / (pageRect.height * scale)
        
        signaturePosition = CGPoint(
            x: max(0, min(1, newX)),
            y: max(0, min(1, newY))
        )
    }
    
    private func loadPDF() {
        pdfDocument = PDFDocument(url: document.fileURL)
    }
    
    private func applySignature() {
        guard let pdfDocument = pdfDocument,
              let page = pdfDocument.page(at: currentPageIndex) else {
            return
        }
        
        let pageRect = page.bounds(for: .mediaBox)
        let signatureRect = CGRect(
            x: signaturePosition.x * pageRect.width - signatureSize.width / 2,
            y: signaturePosition.y * pageRect.height - signatureSize.height / 2,
            width: signatureSize.width,
            height: signatureSize.height
        )
        
        // Use signature as-is (already black) or apply color if needed
        let coloredSignature = selectedColor == .black ? signatureImage : applyColor(to: signatureImage, color: selectedColor.uiColor)
        
        // Create new page with signature
        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
        let newImage = renderer.image { context in
            // Draw existing PDF page
            context.cgContext.translateBy(x: 0, y: pageRect.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: context.cgContext)
            
            // Reset and draw signature
            context.cgContext.translateBy(x: 0, y: -pageRect.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            
            // Apply rotation if needed
            if signatureRotation != 0 {
                context.cgContext.translateBy(x: signatureRect.midX, y: signatureRect.midY)
                context.cgContext.rotate(by: signatureRotation * .pi / 180)
                context.cgContext.translateBy(x: -signatureRect.midX, y: -signatureRect.midY)
            }
            
            coloredSignature.draw(in: signatureRect)
        }
        
        guard let newPage = PDFPage(image: newImage) else { return }
        
        pdfDocument.removePage(at: currentPageIndex)
        pdfDocument.insert(newPage, at: currentPageIndex)
        pdfDocument.write(to: document.fileURL)
    }
    
    private func applyColor(to image: UIImage, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            color.set()
            image.draw(at: .zero, blendMode: .multiply, alpha: 1.0)
        }
    }
}

struct SelectionBoxView: View {
    let position: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let onMove: (CGSize) -> Void
    let onResize: (CGSize) -> Void
    let onRotate: (CGFloat) -> Void
    
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragLocation: CGPoint = .zero
    
    var body: some View {
        ZStack {
            // Yellow border
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: size.width, height: size.height)
                .position(position)
                .rotationEffect(.degrees(rotation))
            
            // Corner handles
            ForEach(0..<4) { index in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)
                    .position(cornerPosition(for: index))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                handleCornerDrag(index: index, value: value)
                            }
                    )
            }
            
            // Rotation handle
            Circle()
                .fill(Color.yellow)
                .frame(width: 12, height: 12)
                .position(rotationHandlePosition)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            handleRotation(value: value)
                        }
                )
        }
    }
    
    private func cornerPosition(for index: Int) -> CGPoint {
        let corners: [(CGFloat, CGFloat)] = [
            (-size.width/2, -size.height/2), // Top-left
            (size.width/2, -size.height/2),  // Top-right
            (size.width/2, size.height/2),   // Bottom-right
            (-size.width/2, size.height/2)   // Bottom-left
        ]
        
        let (dx, dy) = corners[index]
        let rotatedX = dx * cos(rotation * .pi / 180) - dy * sin(rotation * .pi / 180)
        let rotatedY = dx * sin(rotation * .pi / 180) + dy * cos(rotation * .pi / 180)
        
        return CGPoint(x: position.x + rotatedX, y: position.y + rotatedY)
    }
    
    private var rotationHandlePosition: CGPoint {
        let angle = (rotation - 90) * .pi / 180
        let distance: CGFloat = size.height / 2 + 30
        return CGPoint(
            x: position.x + distance * cos(angle),
            y: position.y + distance * sin(angle)
        )
    }
    
    private func handleCornerDrag(index: Int, value: DragGesture.Value) {
        // Resize logic
        let newSize = CGSize(
            width: abs(value.translation.width * 2),
            height: abs(value.translation.height * 2)
        )
        onResize(newSize)
    }
    
    private func handleRotation(value: DragGesture.Value) {
        let center = position
        let angle = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
        let lastAngle = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x) * 180 / .pi
        onRotate(angle - lastAngle)
    }
}

struct FloatingToolbarView: View {
    let position: CGPoint
    let onColor: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                onColor()
            } label: {
                Image(systemName: "paintpalette.fill")
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
            
            Button {
                onDuplicate()
            } label: {
                Image(systemName: "square.on.square")
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
            
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.red)
                    .clipShape(Circle())
            }
        }
        .padding(8)
        .background(Color(white: 0.2))
        .cornerRadius(20)
        .position(position)
    }
}

