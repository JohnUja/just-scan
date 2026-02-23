//
//  SignaturePlacementView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import PDFKit
import UIKit
import CoreImage

struct SignaturePlacementView: View {
    let document: Document
    let signatureImage: UIImage
    let onSave: (() -> Void)?
    @Environment(\.dismiss) var dismiss
    
    init(document: Document, signatureImage: UIImage, onSave: (() -> Void)? = nil) {
        self.document = document
        self.signatureImage = signatureImage
        self.onSave = onSave
    }
    
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex = 0
    @State private var pdfViewInstance: PDFView? = nil  // Reference to PDFView for coordinate conversion
    @State private var zoomRefreshID = UUID()  // Forces SwiftUI to recalculate signature positions during zoom
    
    // Normalized coordinates (0.0 to 1.0) - much simpler!
    @State private var signaturePosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var signatureWidthRatio: CGFloat = 0.3 // 30% of page width
    @State private var signatureAspectRatio: CGFloat = 2.0 // width/height ratio
    @State private var copiedSignature: (position: CGPoint, widthRatio: CGFloat, rotation: CGFloat, color: SignatureColor)?
    
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
            .navigationTitle("Insert Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        applySignature()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                setupSignatureAspectRatio()
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
    
    private func setupSignatureAspectRatio() {
        // Calculate aspect ratio from the actual image
        if signatureImage.size.height > 0 {
            signatureAspectRatio = signatureImage.size.width / signatureImage.size.height
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        if let pdfDocument = pdfDocument {
            GeometryReader { geometry in
                let page = pdfDocument.page(at: currentPageIndex) ?? PDFPage()
                let pageRect = page.bounds(for: .mediaBox)
                
                // Calculate how PDF is displayed (Aspect Fit)
                let widthScale = geometry.size.width / pageRect.width
                let heightScale = geometry.size.height / pageRect.height
                let scale = min(widthScale, heightScale)
                
                let displayWidth = pageRect.width * scale
                let displayHeight = pageRect.height * scale
                let offsetX = (geometry.size.width - displayWidth) / 2
                let offsetY = (geometry.size.height - displayHeight) / 2
                
                ZStack {
                    // PDF View
                    PDFViewRepresentable(
                        pdfDocument: pdfDocument,
                        pageIndex: $currentPageIndex,
                        pdfViewInstance: $pdfViewInstance,
                        refreshTrigger: $zoomRefreshID  // Pass the zoom refresh trigger
                    )
                    .ignoresSafeArea()
                    
                    // Signature Overlay
                    signatureOverlay(
                        displayWidth: displayWidth,
                        displayHeight: displayHeight,
                        offsetX: offsetX,
                        offsetY: offsetY,
                        pageRect: pageRect
                    )
                }
            }
        } else {
            ProgressView()
        }
    }
    
    private func signatureOverlay(displayWidth: CGFloat, displayHeight: CGFloat, offsetX: CGFloat, offsetY: CGFloat, pageRect: CGRect) -> some View {
        // Calculate actual display size
        let elementWidth = displayWidth * signatureWidthRatio
        let elementHeight = elementWidth / signatureAspectRatio
        
        // Calculate position in display coordinates
        let xPos = signaturePosition.x * displayWidth + offsetX
        let yPos = signaturePosition.y * displayHeight + offsetY
        
        // Apply color to signature
        let coloredSignature: UIImage = {
            if selectedColor == .black {
                return signatureImage
            } else {
                return applyColor(to: signatureImage, color: selectedColor.uiColor)
            }
        }()
        
        return ZStack {
            // Signature Image with drag gesture
            Image(uiImage: coloredSignature)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: elementWidth, height: elementHeight)
                .rotationEffect(.degrees(signatureRotation))
                .position(x: xPos, y: yPos)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Use finger location directly - signature follows finger exactly
                            let fingerX = value.location.x
                            let fingerY = value.location.y
                            
                            // Convert finger position to normalized coordinates (0-1)
                            // Account for the offset where PDF is displayed
                            let normalizedX = (fingerX - offsetX) / displayWidth
                            let normalizedY = (fingerY - offsetY) / displayHeight
                            
                            // Clamp to page bounds (with small padding for signature size)
                            let halfWidth = (elementWidth / displayWidth) / 2
                            let halfHeight = (elementHeight / displayHeight) / 2
                            
                            signaturePosition.x = max(halfWidth, min(1 - halfWidth, normalizedX))
                            signaturePosition.y = max(halfHeight, min(1 - halfHeight, normalizedY))
                        }
                )
            
            // Selection Box & Controls
            if isSelected {
                SelectionBoxView(
                    position: CGPoint(x: xPos, y: yPos),
                    size: CGSize(width: elementWidth, height: elementHeight),
                    rotation: signatureRotation,
                    rotationHandleOffset: nil,  // ✅ Use default (scaling) for SignaturePlacementView
                    onMove: { delta in
                        // Center drag should also follow finger position directly
                        // This is handled by the signature image gesture above
                        // This callback is kept for compatibility but movement is handled by image gesture
                    },
                    onResize: { scaleFactor in
                        // Smooth resize with much smaller minimum (5% of page width)
                        signatureWidthRatio = max(0.05, min(0.8, signatureWidthRatio * scaleFactor))
                    },
                    onRotate: { angle in
                        signatureRotation += angle
                        // Normalize rotation
                        signatureRotation = signatureRotation.truncatingRemainder(dividingBy: 360)
                    },
                    onMoveEnd: {},
                    onResizeEnd: {},
                    onRotateEnd: {}
                )
                
                // Floating Toolbar (Apple-style subtle)
                FloatingToolbarView(
                    position: CGPoint(x: xPos, y: yPos - elementHeight/2 - 50),
                    onMove: nil,  // ✅ Not needed here, movement handled by image gesture
                    onMoveEnd: nil,
                    onColor: { showColorPicker = true },
                    onDelete: { dismiss() },
                    onDuplicate: {
                        // Duplicate signature object - save current signature first
                        applySignature()
                        
                        // Create new signature object with same properties at offset position
                        let offsetX = min(0.15, 1.0 - signaturePosition.x - 0.05)
                        let offsetY = min(0.15, 1.0 - signaturePosition.y - 0.05)
                        
                        // New signature at offset (keeps size, rotation, color)
                        signaturePosition = CGPoint(
                            x: signaturePosition.x + offsetX,
                            y: signaturePosition.y + offsetY
                        )
                        isSelected = true
                    },
                    onCopy: {
                        // Copy signature state
                        copiedSignature = (signaturePosition, signatureWidthRatio, signatureRotation, selectedColor)
                    },
                    onPaste: {
                        // Paste signature if available
                        if let copied = copiedSignature {
                            signaturePosition = CGPoint(x: copied.position.x + 0.1, y: copied.position.y + 0.1)
                            signatureWidthRatio = copied.widthRatio
                            signatureRotation = copied.rotation
                            selectedColor = copied.color
                        }
                    },
                    canPaste: copiedSignature != nil
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isSelected = true
        }
    }
    
    // MARK: - Save Signature (Fixed Coordinate System)
    private func applySignature() {
        guard let pdfDocument = pdfDocument,
              let page = pdfDocument.page(at: currentPageIndex) else {
            print("❌ Failed to get PDF page")
            return
        }
        
        let pageRect = page.bounds(for: .mediaBox)
        
        // Calculate signature size in PDF points
        let pdfWidth = pageRect.width * signatureWidthRatio
        let pdfHeight = pdfWidth / signatureAspectRatio
        
        // Calculate position in PDF coordinates
        // PDF uses bottom-left origin (0,0), SwiftUI uses top-left
        // Convert normalized position (0-1) to PDF coordinates
        let pdfX = (signaturePosition.x * pageRect.width) - (pdfWidth / 2)
        // Flip Y: SwiftUI top=0, PDF bottom=0
        let pdfY = pageRect.height - (signaturePosition.y * pageRect.height) - (pdfHeight / 2)
        
        let signatureRect = CGRect(x: pdfX, y: pdfY, width: pdfWidth, height: pdfHeight)
        
        // Prepare signature image with color (apply color transformation)
        var finalImage: UIImage
        if selectedColor == .black {
            finalImage = signatureImage
        } else {
            finalImage = applyColor(to: signatureImage, color: selectedColor.uiColor)
        }
        
        // Apply rotation to image
        if signatureRotation != 0 {
            finalImage = finalImage.rotated(by: signatureRotation) ?? finalImage
        }
        
        // Render signature onto page (most reliable method)
        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
        let newImage = renderer.image { context in
            let cgContext = context.cgContext
            
            // Save graphics state
            cgContext.saveGState()
            
            // Draw existing PDF page (PDF coordinate system - bottom-left origin)
            cgContext.translateBy(x: 0, y: pageRect.height)
            cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: cgContext)
            
            // Restore and prepare for signature drawing
            cgContext.restoreGState()
            
            // Draw signature in PDF coordinates (bottom-left origin)
            // We need to flip Y again for signature drawing
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pageRect.height)
            cgContext.scaleBy(x: 1.0, y: -1.0)
            
            // Draw the signature image with proper settings
            cgContext.setBlendMode(.normal)
            cgContext.setAlpha(1.0)
            cgContext.interpolationQuality = .high
            
            if let cgImage = finalImage.cgImage {
                cgContext.draw(cgImage, in: signatureRect)
            } else {
                // Fallback if CGImage conversion fails
                finalImage.draw(in: signatureRect, blendMode: .normal, alpha: 1.0)
            }
            
            cgContext.restoreGState()
        }
        
        // Replace page with new one containing signature
        guard let newPage = PDFPage(image: newImage) else {
            print("❌ Failed to create PDF page")
            return
        }
        
        pdfDocument.removePage(at: currentPageIndex)
        pdfDocument.insert(newPage, at: currentPageIndex)
        
        // Force save with explicit file handling
        // Save the PDF directly
        let fileURL = document.fileURL
        
        // Use data write method for more reliable saving
        if let pdfData = pdfDocument.dataRepresentation() {
            do {
                try pdfData.write(to: fileURL, options: .atomic)
                print("✅ Signature saved successfully to page \(currentPageIndex + 1)")
                
                // Reload PDF to show changes
                DispatchQueue.main.async {
                    self.loadPDF()
                    // Notify parent to reload
                    self.onSave?()
                }
            } catch {
                print("❌ Error writing PDF data: \(error.localizedDescription)")
            }
        } else {
            // Fallback to write method
            let success = pdfDocument.write(to: fileURL)
            if success {
                print("✅ Signature saved (fallback method) to page \(currentPageIndex + 1)")
                DispatchQueue.main.async {
                    self.loadPDF()
                    self.onSave?()
                }
            } else {
                print("❌ Failed to write PDF")
            }
        }
    }
    
    private func loadPDF() {
        pdfDocument = PDFDocument(url: document.fileURL)
    }
    
    private func applyColor(to image: UIImage, color: UIColor) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        
        // Use CIColorMonochrome filter for better color application
        guard let filter = CIFilter(name: "CIColorMonochrome") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIColor(color: color), forKey: kCIInputColorKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        
        guard let outputImage = filter.outputImage,
              let context = CIContext().createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        
        return UIImage(cgImage: context)
    }
}

// MARK: - Resize Handle
private struct ResizeHandle: View {
    enum Position {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    
    let position: Position
    
    var body: some View {
        Circle()
            .fill(Color.yellow)
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 2)
            )
    }
}

// MARK: - Rotation Handle
private struct RotationHandle: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue)
                .frame(width: 20, height: 20)
            
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Selection Box
struct SelectionBoxView: View {
    let position: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let rotationHandleOffset: CGFloat?  // ✅ Optional fixed offset (if nil, uses old scaling behavior)
    let onMove: (CGSize) -> Void
    let onResize: (CGFloat) -> Void
    let onRotate: (CGFloat) -> Void
    let onMoveEnd: () -> Void
    let onResizeEnd: () -> Void
    let onRotateEnd: () -> Void
    
    init(
        position: CGPoint,
        size: CGSize,
        rotation: CGFloat,
        rotationHandleOffset: CGFloat? = nil,  // ✅ Default to nil for backward compatibility
        onMove: @escaping (CGSize) -> Void,
        onResize: @escaping (CGFloat) -> Void,
        onRotate: @escaping (CGFloat) -> Void,
        onMoveEnd: @escaping () -> Void,
        onResizeEnd: @escaping () -> Void,
        onRotateEnd: @escaping () -> Void
    ) {
        self.position = position
        self.size = size
        self.rotation = rotation
        self.rotationHandleOffset = rotationHandleOffset
        self.onMove = onMove
        self.onResize = onResize
        self.onRotate = onRotate
        self.onMoveEnd = onMoveEnd
        self.onResizeEnd = onResizeEnd
        self.onRotateEnd = onRotateEnd
    }
    
    @State private var lastDragLocation: CGPoint = .zero
    @State private var lastResizeDistance: CGFloat = 0
    @State private var lastRotationAngle: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var showWarning: Bool = false
    @State private var hasStartedDrag: Bool = false // Track if drag has started (minimum distance)
    
    private var handleSize: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 28 : 16.8
    }
    private let minSize: CGFloat = 40
    
    var body: some View {
        ZStack {
            // ✅ Selection box border - visual only, doesn't intercept touches
            Rectangle()
                .stroke(Color.yellow, lineWidth: 1)  // ✅ Yellow line with regular stroke
                .frame(width: max(minSize, abs(size.width)), height: max(minSize, abs(size.height)))
                .rotationEffect(.degrees(rotation))
                .position(position)
                .allowsHitTesting(false)  // ✅ Border doesn't intercept touches - allows pan gesture to pass through
                .onAppear {
                    
                }
            
            // Warning icon when near borders
            if showWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 20))
                    .position(CGPoint(x: position.x, y: position.y - size.height/2 - 30))
                    .allowsHitTesting(false)  // ✅ Warning icon doesn't intercept touches
            }
            
            // ✅ CRITICAL: Pan gesture is handled by PDFView's handlePan (UIKit gesture recognizer)
            // The selection box border is purely visual - gestures pass through to PDFView
            // Corner handles and rotation handle still work (they have their own gestures and allowHitTesting)
            
            // FOUR CORNER HANDLES ONLY (not 8) - ✅ MUST have hit testing enabled
            ForEach(0..<4) { index in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: handleSize, height: handleSize)  // 70% of previous 24
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .position(cornerPosition(for: index))
                    .allowsHitTesting(true)  // ✅ CRITICAL: Corner handles must be interactive
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let distance = sqrt(
                                    pow(value.location.x - position.x, 2) +
                                    pow(value.location.y - position.y, 2)
                                )
                                let initialDistance = sqrt(
                                    pow(value.startLocation.x - position.x, 2) +
                                    pow(value.startLocation.y - position.y, 2)
                                )
                                
                                if lastResizeDistance == 0 {
                                    lastResizeDistance = initialDistance
                                }
                                
                                // Smooth scaling with better minimum handling
                                let scaleFactor = distance / lastResizeDistance
                                // Only update if change is significant (reduces choppiness)
                                if abs(scaleFactor - 1.0) > 0.01 {
                                    onResize(scaleFactor)
                                    lastResizeDistance = distance
                                }
                            }
                            .onEnded { _ in
                                lastResizeDistance = 0
                                onResizeEnd()
                            }
                    )
            }
            
            // ✅ Rotation handle - only show if rotationHandleOffset is provided (for SignaturePlacementView)
            // In DocumentReviewView, rotation handle is separate (RotationHandleView)
            if rotationHandleOffset != nil {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.gray.opacity(0.8))
                    .clipShape(Circle())
                .position(rotationHandlePosition)
                    .zIndex(3000)
                    .allowsHitTesting(true)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let center = position
                            let currentAngle = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
                            let startAngle = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x) * 180 / .pi
                            
                            if lastRotationAngle == 0 {
                                lastRotationAngle = startAngle
                            }
                            
                            let delta = currentAngle - lastRotationAngle
                            let normalizedDelta = ((delta + 180).truncatingRemainder(dividingBy: 360)) - 180
                            onRotate(normalizedDelta)
                            lastRotationAngle = currentAngle
                        }
                        .onEnded { _ in
                            lastRotationAngle = 0
                                onRotateEnd()
                        }
                )
        }
    }
        .onAppear {
            // Check if near borders and show warning
            checkBorders()
        }
        .onChange(of: position) { _ in
            checkBorders()
        }
    }
    
    // Helper - only 4 corners (not 8)
    private func cornerPosition(for index: Int) -> CGPoint {
        let corners: [(CGFloat, CGFloat)] = [
            (-size.width/2, -size.height/2), // Top-left
            (size.width/2, -size.height/2),   // Top-right
            (size.width/2, size.height/2),    // Bottom-right
            (-size.width/2, size.height/2)   // Bottom-left
        ]
        
        let (dx, dy) = corners[index]
        let angle = rotation * .pi / 180
        let rotatedX = dx * cos(angle) - dy * sin(angle)
        let rotatedY = dx * sin(angle) + dy * cos(angle)
        
        return CGPoint(x: position.x + rotatedX, y: position.y + rotatedY)
    }
    
    private var rotationHandlePosition: CGPoint {
        let angle = rotation * .pi / 180
        
        // ✅ Use fixed offset if provided, otherwise use old scaling behavior
        let distance: CGFloat
        if let fixedOffset = rotationHandleOffset {
            // Fixed pixel offset (doesn't scale with signature)
            distance = size.height / 2 + fixedOffset
        } else {
            // Old behavior: scales with signature height (at least 30pt, or 20% of height)
            let baseDistance = max(30, size.height * 0.2)
            distance = size.height / 2 + baseDistance
        }
        
        // Calculate top-center point of rotated selection box
        let topCenterX = position.x + (0 * cos(angle) - (-size.height/2) * sin(angle))
        let topCenterY = position.y + (0 * sin(angle) + (-size.height/2) * cos(angle))
        // Offset upward along the rotated Y-axis
        let handleX = topCenterX + distance * sin(angle)
        let handleY = topCenterY - distance * cos(angle)
        return CGPoint(x: handleX, y: handleY)
    }
    
    private func checkBorders() {
        // Simple border check - show warning if near edges
        // This is a placeholder - actual implementation would check against PDF page bounds
        let margin: CGFloat = 50
        showWarning = position.x < margin || position.y < margin
    }
}

// MARK: - Move Icon View (draggable)
private struct MoveIconView: View {
    let onMove: (CGSize) -> Void
    let onMoveEnd: (() -> Void)?
    
    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 12))  // ✅ Reduced by ~20%
            .foregroundColor(.white)
            .frame(width: 26, height: 26)  // ✅ Reduced by ~20% (32 * 0.8)
            .background(Color(white: 0.3, opacity: 0.9))
            .clipShape(Circle())
            .gesture(
                // ✅ SMOOTH: Use translation directly (native SwiftUI, no jitter)
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Use translation directly - SwiftUI handles smoothing
                        onMove(value.translation)
                    }
                    .onEnded { _ in
                        onMoveEnd?()
                    }
        )
    }
}

// MARK: - Floating Toolbar (Apple-style subtle)
struct FloatingToolbarView: View {
    let position: CGPoint
    let onMove: ((CGSize) -> Void)?  // ✅ Changed to accept CGSize delta
    let onMoveEnd: (() -> Void)?      // ✅ Added property
    let onColor: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let canPaste: Bool
    
    init(
        position: CGPoint,
        onMove: ((CGSize) -> Void)? = nil,  // ✅ Changed signature
        onMoveEnd: (() -> Void)? = nil,      // ✅ Added parameter
        onColor: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onPaste: @escaping () -> Void,
        canPaste: Bool
    ) {
        self.position = position
        self.onMove = onMove
        self.onMoveEnd = onMoveEnd
        self.onColor = onColor
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        self.onCopy = onCopy
        self.onPaste = onPaste
        self.canPaste = canPaste
    }
    
    var body: some View {
        HStack(spacing: 6) {  // ✅ Reduced spacing for more compact toolbar
            // ✅ Move button - draggable to move signature and toolbar together
            if let onMove = onMove {
                MoveIconView(
                    onMove: onMove,
                    onMoveEnd: onMoveEnd
                )
            }
            
            // Color picker (switched with duplicate)
            Button {
                onColor()
            } label: {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 12))  // ✅ Reduced by ~20%
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)  // ✅ Reduced by ~20% (32 * 0.8)
                    .background(Color(white: 0.3, opacity: 0.9))
                    .clipShape(Circle())
            }
            
            // Duplicate (switched with color)
            Button {
                onDuplicate()
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12))  // ✅ Reduced by ~20%
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)  // ✅ Reduced by ~20% (32 * 0.8)
                    .background(Color(white: 0.3, opacity: 0.9))
                    .clipShape(Circle())
            }
            
            // Paste (only if available)
            if canPaste {
                Button {
                    onPaste()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13))  // ✅ Reduced by ~20%
                        .foregroundColor(.white)
                        .frame(width: 29, height: 29)  // ✅ Reduced by ~20% (36 * 0.8)
                        .background(Color(white: 0.3, opacity: 0.9))
                        .clipShape(Circle())
                }
            }
            
            // Delete (red fill, grey background)
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.system(size: 13))  // ✅ Reduced by ~20%
                    .foregroundColor(.red)
                    .frame(width: 29, height: 29)  // ✅ Reduced by ~20% (36 * 0.8)
                    .background(Color(white: 0.3, opacity: 0.9))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 8)   // ✅ Reduced horizontal padding
        .padding(.vertical, 4)     // ✅ Reduced by ~20% (6 * 0.8 = 4.8, rounded to 4)
        .background(
            .ultraThinMaterial,
            in: Capsule()
        )
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .position(position)
    }
}

// MARK: - UIImage Rotation Extension
extension UIImage {
    func rotated(by degrees: CGFloat) -> UIImage? {
        let radians = degrees * .pi / 180
        
        var newSize = CGRect(origin: .zero, size: self.size)
            .applying(CGAffineTransform(rotationAngle: radians)).size
        newSize.width = floor(newSize.width)
        newSize.height = floor(newSize.height)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            return nil
        }
        
        context.translateBy(x: newSize.width/2, y: newSize.height/2)
        context.rotate(by: radians)
        self.draw(in: CGRect(
            x: -self.size.width/2,
            y: -self.size.height/2,
            width: self.size.width,
            height: self.size.height
        ))
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage
    }
}
