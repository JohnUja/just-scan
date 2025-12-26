//
//  IntegratedScannerView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - 1. MAIN SCANNER CONTAINER
struct IntegratedScannerView: View {
    @State private var scannedPages: [UIImage] = []
    @State private var selectedPageIndex: Int = 0 // Expert Fix: Non-optional for TabView
    @State private var showFullPageView = false
    @State private var isScanning: Bool
    @State private var draggedIndex: Int? // For drag-to-reorder (expert fix: index-based)
    
    let onSave: ([UIImage]) -> Void
    let onCancel: () -> Void
    
    @Environment(\.dismiss) var dismiss
    
    // Custom init: Allows starting with existing images (edit mode)
    init(existingImages: [UIImage] = [], onSave: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
        self._scannedPages = State(initialValue: existingImages)
        self._isScanning = State(initialValue: existingImages.isEmpty) // No images? Scan. Images? Review.
        self._selectedPageIndex = State(initialValue: 0) // Always start at 0
        self.onSave = onSave
        self.onCancel = onCancel
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if isScanning {
                DocumentScannerView(
                    didFinishScanning: { images in
                        Task { @MainActor in
                            withAnimation(.easeInOut(duration: 0.3)) {
                                self.scannedPages = images
                                self.isScanning = false
                                if !images.isEmpty { self.selectedPageIndex = 0 }
                            }
                            print("📸 Scan complete: \(images.count) pages - Review mode active")
                        }
                    },
                    didCancel: {
                        onCancel()
                        dismiss()
                    }
                )
                .ignoresSafeArea()
            } else {
                // REVIEW / TRAY MODE (with swipeable pages)
                VStack(spacing: 0) {
                    // Prominent header showing page count and instructions
                    if !scannedPages.isEmpty {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Review & Reorder")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(scannedPages.count) page\(scannedPages.count == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            Text("Swipe pages • Drag thumbnails to reorder • Tap to edit")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.15, green: 0.15, blue: 0.15), Color(red: 0.1, green: 0.1, blue: 0.1)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    
                    if !scannedPages.isEmpty {
                        TabView(selection: $selectedPageIndex) {
                            ForEach(scannedPages.indices, id: \.self) { index in
                                Image(uiImage: scannedPages[index])
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .cornerRadius(12)
                                    .padding()
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                        .frame(maxHeight: .infinity)
                    } else {
                        Spacer()
                    }
                    
                    bottomTray
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.3), value: scannedPages.count)
            }
        }
        .sheet(isPresented: $showFullPageView) {
            if scannedPages.indices.contains(selectedPageIndex) {
                FullPageEditView(
                    pages: $scannedPages,
                    currentIndex: selectedPageIndex,
                    onSave: { showFullPageView = false }
                )
            }
        }
    }
    
    private var bottomTray: some View {
        ZStack {
            // More prominent background
            LinearGradient(
                colors: [Color(red: 0.15, green: 0.15, blue: 0.15), Color(red: 0.1, green: 0.1, blue: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 12) {
                // More visible instructions
                HStack {
                    Image(systemName: "hand.draw")
                        .foregroundColor(.blue)
                    Text("Drag thumbnails to reorder")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "hand.tap")
                        .foregroundColor(.green)
                    Text("Tap to edit")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(scannedPages.indices, id: \.self) { index in
                            ThumbnailTrayItem(
                                page: scannedPages[index],
                                index: index,
                                isSelected: selectedPageIndex == index,
                                onTap: {
                                    selectedPageIndex = index
                                    showFullPageView = true // GO TO EDIT/SIGN VIEW
                                },
                                onDelete: {
                                    withAnimation {
                                        scannedPages.remove(at: index)
                                        if scannedPages.isEmpty { 
                                            isScanning = true 
                                        } else if selectedPageIndex >= scannedPages.count {
                                            selectedPageIndex = max(0, scannedPages.count - 1)
                                        }
                                    }
                                }
                            )
                            .onDrag {
                                draggedIndex = index
                                return NSItemProvider(object: String(index) as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDelegate(
                                itemIndex: index,
                                items: $scannedPages,
                                draggedIndex: $draggedIndex
                            ))
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 100)
                
                HStack {
                    Button("Retake") {
                        scannedPages.removeAll()
                        isScanning = true
                    }
                    .foregroundColor(.red)
                    Spacer()
                    Button(action: { onSave(scannedPages) }) {
                        Text("Save PDF").bold()
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(Color.blue).foregroundColor(.white).cornerRadius(20)
                    }
                }
                .padding(.horizontal).padding(.bottom, 20)
            }
        }
        .frame(height: 200)
    }
}

// MARK: - REORDER DELEGATE (Index-Based, Expert Fix)
struct ReorderDelegate: DropDelegate {
    let itemIndex: Int
    @Binding var items: [UIImage]
    @Binding var draggedIndex: Int?
    
    func dropEntered(info: DropInfo) {
        guard let fromIndex = draggedIndex, fromIndex != itemIndex else { return }
        
        // Safe index check
        if items.indices.contains(fromIndex) && items.indices.contains(itemIndex) {
            withAnimation {
                items.move(fromOffsets: IndexSet(integer: fromIndex),
                          toOffset: itemIndex > fromIndex ? itemIndex + 1 : itemIndex)
                // Update dragged index to follow the item
                draggedIndex = itemIndex
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        draggedIndex = nil
        return true
    }
}

// MARK: - 2. FULL PAGE EDIT (Filters + Signature)
struct FullPageEditView: View {
    @Binding var pages: [UIImage]
    let currentIndex: Int
    let onSave: () -> Void
    
    @State private var internalIndex: Int
    @State private var currentFilter: FilterType = .original
    @State private var showSignaturePlacement = false
    
    enum FilterType {
        case original, blackAndWhite, grayscale
    }
    
    init(pages: Binding<[UIImage]>, currentIndex: Int, onSave: @escaping () -> Void) {
        self._pages = pages
        self.currentIndex = currentIndex
        self.onSave = onSave
        _internalIndex = State(initialValue: currentIndex)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack {
                    if pages.indices.contains(internalIndex) {
                        let pageImage = pages[internalIndex]
                        // Validate image before displaying
                        if pageImage.size.width > 0 && pageImage.size.height > 0 {
                            // Display the image with the LIVE filter applied
                            Image(uiImage: applyFilter(to: pageImage, type: currentFilter))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding()
                        } else {
                            Text("Invalid image")
                                .foregroundColor(.white)
                        }
                    } else {
                        Spacer()
                    }
                    
                    // EDIT TOOLBAR
                    HStack(spacing: 40) {
                        // 1. FILTER TOGGLE
                        Button(action: cycleFilter) {
                            VStack {
                                Image(systemName: "wand.and.stars")
                                    .font(.title2)
                                Text(filterName).font(.caption)
                            }
                        }
                        
                        // 2. SIGNATURE PLACEMENT (Vector-based)
                        Button(action: {
                            guard SignatureService.shared.hasSignature else { return }
                            showSignaturePlacement = true
                        }) {
                            VStack {
                                Image(systemName: "signature")
                                    .font(.title2)
                                Text("Sign").font(.caption)
                            }
                        }
                        .disabled(!SignatureService.shared.hasSignature)
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color(white: 0.15))
                    .cornerRadius(16)
                    .padding(.bottom)
                }
            }
            .navigationTitle("Edit Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") {
                    // Make filter permanent on save
                    if pages.indices.contains(internalIndex) {
                        pages[internalIndex] = applyFilter(to: pages[internalIndex], type: currentFilter)
                    }
                    onSave()
                }
            }
            .sheet(isPresented: $showSignaturePlacement) {
                if pages.indices.contains(internalIndex),
                   let signature = SignatureService.shared.signatureImage {
                    VectorSignaturePlacementView(
                        pageImage: applyFilter(to: pages[internalIndex], type: currentFilter),
                        signatureImage: signature,
                        onSave: { editedImage in
                            // Apply the edited image back
                            pages[internalIndex] = editedImage
                            currentFilter = .original // Reset filter since signature is burned in
                            showSignaturePlacement = false
                        },
                        onCancel: {
                            showSignaturePlacement = false
                        }
                    )
                }
            }
        }
    }
    
    // Logic: Filter Cycling
    private var filterName: String {
        switch currentFilter {
        case .original: return "Color"
        case .blackAndWhite: return "B&W"
        case .grayscale: return "Gray"
        }
    }
    
    private func cycleFilter() {
        switch currentFilter {
        case .original: currentFilter = .blackAndWhite
        case .blackAndWhite: currentFilter = .grayscale
        case .grayscale: currentFilter = .original
        }
    }
    
    // Logic: Apply Filter
    private func applyFilter(to image: UIImage, type: FilterType) -> UIImage {
        if type == .original { return image }
        
        // Validate image before processing
        guard image.size.width > 0 && image.size.height > 0 else {
            return image
        }
        
        // Limit processing to reasonable sizes to prevent memory crashes
        let maxDimension: CGFloat = 2000
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1.0)
        let workingImage: UIImage
        
        if scale < 1.0 {
            // Downscale first to prevent memory issues
            let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: scaledSize)
            workingImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: scaledSize))
            }
        } else {
            workingImage = image
        }
        
        let context = CIContext()
        guard let ciImage = CIImage(image: workingImage) else { return image }
        
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        
        if type == .blackAndWhite {
            filter.contrast = 1.5
            filter.saturation = 0.0
            filter.brightness = 0.1
        } else {
            filter.saturation = 0.0
        }
        
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: cgImage)
    }
    
}

// MARK: - VECTOR-BASED SIGNATURE PLACEMENT (Drag/Resize/Rotate)
struct VectorSignaturePlacementView: View {
    let pageImage: UIImage
    let signatureImage: UIImage
    let onSave: (UIImage) -> Void
    let onCancel: () -> Void
    
    @State private var signaturePosition: CGPoint
    @State private var signatureSize: CGSize
    @State private var signatureRotation: CGFloat = 0
    @State private var isSelected = true
    @State private var selectedColor: SignatureColor = .black
    @State private var showColorPicker = false
    
    @Environment(\.dismiss) var dismiss
    
    init(pageImage: UIImage, signatureImage: UIImage, onSave: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.pageImage = pageImage
        self.signatureImage = signatureImage
        self.onSave = onSave
        self.onCancel = onCancel
        
        // Start signature in center, 50% of page width
        let initialWidth = pageImage.size.width * 0.5
        let initialHeight = initialWidth * (signatureImage.size.height / signatureImage.size.width)
        self._signatureSize = State(initialValue: CGSize(width: initialWidth, height: initialHeight))
        self._signaturePosition = State(initialValue: CGPoint(x: pageImage.size.width / 2, y: pageImage.size.height / 2))
    }
    
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    // Page image
                    Image(uiImage: pageImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                    
                    // Signature overlay with controls
                    signatureOverlay(geometry: geometry)
                }
            }
            .navigationTitle("Place Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        applySignature()
                    }
                    .fontWeight(.semibold)
                }
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
    
    private func signatureOverlay(geometry: GeometryProxy) -> some View {
        let imageAspectRatio = pageImage.size.width / pageImage.size.height
        let viewAspectRatio = geometry.size.width / geometry.size.height
        
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        
        if imageAspectRatio > viewAspectRatio {
            // Image is wider - fit to width
            scale = (geometry.size.width - 32) / pageImage.size.width
            offsetX = 16
            offsetY = (geometry.size.height - pageImage.size.height * scale) / 2
        } else {
            // Image is taller - fit to height
            scale = (geometry.size.height - 32) / pageImage.size.height
            offsetX = (geometry.size.width - pageImage.size.width * scale) / 2
            offsetY = 16
        }
        
        let screenX = signaturePosition.x * scale + offsetX
        let screenY = signaturePosition.y * scale + offsetY
        let screenWidth = signatureSize.width * scale
        let screenHeight = signatureSize.height * scale
        
        return ZStack {
            // Signature image
            Image(uiImage: applyColor(to: signatureImage, color: selectedColor.uiColor))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: screenWidth, height: screenHeight)
                .rotationEffect(.degrees(signatureRotation))
                .position(x: screenX, y: screenY)
                .onTapGesture {
                    isSelected = true
                }
            
            // Selection controls
            if isSelected {
                SelectionControlsView(
                    position: CGPoint(x: screenX, y: screenY),
                    size: CGSize(width: screenWidth, height: screenHeight),
                    rotation: signatureRotation,
                    onMove: { delta in
                        signaturePosition.x += delta.width / scale
                        signaturePosition.y += delta.height / scale
                    },
                    onResize: { newSize in
                        signatureSize.width = max(50, min(pageImage.size.width * 0.8, newSize.width / scale))
                        signatureSize.height = signatureSize.width * (signatureImage.size.height / signatureImage.size.width)
                    },
                    onRotate: { angle in
                        signatureRotation += angle
                    }
                )
                
                // Color picker button
                Button(action: { showColorPicker = true }) {
                    Image(systemName: "paintpalette.fill")
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
                .position(x: screenX, y: screenY - screenHeight / 2 - 40)
            }
        }
    }
    
    private func applyColor(to image: UIImage, color: UIColor) -> UIImage {
        if color == .black { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            color.set()
            image.draw(at: .zero, blendMode: .multiply, alpha: 1.0)
        }
    }
    
    private func applySignature() {
        let renderer = UIGraphicsImageRenderer(size: pageImage.size)
        let finalImage = renderer.image { context in
            // Draw page
            pageImage.draw(at: .zero)
            
            // Draw signature with transform
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: signaturePosition.x, y: signaturePosition.y)
            context.cgContext.rotate(by: signatureRotation * .pi / 180)
            context.cgContext.translateBy(x: -signatureSize.width / 2, y: -signatureSize.height / 2)
            
            let coloredSig = applyColor(to: signatureImage, color: selectedColor.uiColor)
            coloredSig.draw(in: CGRect(origin: .zero, size: signatureSize))
            
            context.cgContext.restoreGState()
        }
        
        onSave(finalImage)
        dismiss()
    }
}

// MARK: - Selection Controls (Resize/Rotate Handles)
struct SelectionControlsView: View {
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
            // Border
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: size.width, height: size.height)
                .position(position)
                .rotationEffect(.degrees(rotation))
            
            // Corner resize handles
            ForEach(0..<4) { index in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)
                    .position(cornerPosition(for: index))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newSize = CGSize(
                                    width: abs(value.translation.width * 2),
                                    height: abs(value.translation.height * 2)
                                )
                                onResize(newSize)
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
                            let center = position
                            let angle = atan2(value.location.y - center.y, value.location.x - center.x) * 180 / .pi
                            let lastAngle = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x) * 180 / .pi
                            onRotate(angle - lastAngle)
                        }
                )
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    onMove(value.translation)
                }
        )
    }
    
    private func cornerPosition(for index: Int) -> CGPoint {
        let corners: [(CGFloat, CGFloat)] = [
            (-size.width/2, -size.height/2),
            (size.width/2, -size.height/2),
            (size.width/2, size.height/2),
            (-size.width/2, size.height/2)
        ]
        let (dx, dy) = corners[index]
        let angle = rotation * .pi / 180
        let rotatedX = dx * cos(angle) - dy * sin(angle)
        let rotatedY = dx * sin(angle) + dy * cos(angle)
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
}

// MARK: - 3. HELPER TRAY ITEM
struct ThumbnailTrayItem: View {
    let page: UIImage
    let index: Int
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: page)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 80)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                )
            
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .background(Color.white.clipShape(Circle()))
            }
            .offset(x: 5, y: -5)
        }
        .onTapGesture { onTap() }
    }
}