//
//  IntegratedScannerView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 1. MAIN SCANNER CONTAINER
struct IntegratedScannerView: View {
    @State private var scannedPages: [UIImage] = []
    @State private var selectedPageIndex: Int?
    @State private var showFullPageView = false
    @State private var isScanning = true
    
    let onSave: ([UIImage]) -> Void
    let onCancel: () -> Void
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if isScanning {
                DocumentScannerView(
                    didFinishScanning: { images in
                        Task { @MainActor in
                            self.scannedPages = images
                            self.isScanning = false
                            if !images.isEmpty { self.selectedPageIndex = 0 }
                        }
                    },
                    didCancel: {
                        onCancel()
                        dismiss()
                    }
                )
                .ignoresSafeArea()
            } else {
                // REVIEW / TRAY MODE
                VStack(spacing: 0) {
                    Spacer()
                    if let index = selectedPageIndex, scannedPages.indices.contains(index) {
                        Image(uiImage: scannedPages[index])
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                            .padding()
                            .id(index) // Force refresh on index change
                    }
                    Spacer()
                    
                    bottomTray
                }
            }
        }
        .sheet(isPresented: $showFullPageView) {
            if let index = selectedPageIndex {
                FullPageEditView(
                    pages: $scannedPages,
                    currentIndex: index,
                    onSave: { showFullPageView = false }
                )
            }
        }
    }
    
    private var bottomTray: some View {
        ZStack {
            Color(red: 0.1, green: 0.1, blue: 0.1).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Tap page to Edit • Drag to Reorder")
                    .font(.caption).foregroundColor(.gray).padding(.top, 8)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(scannedPages.enumerated()), id: \.offset) { index, page in
                            ThumbnailTrayItem(
                                page: page,
                                index: index,
                                isSelected: selectedPageIndex == index,
                                onTap: {
                                    selectedPageIndex = index
                                    showFullPageView = true // GO TO EDIT/SIGN VIEW
                                },
                                onDelete: {
                                    scannedPages.remove(at: index)
                                    if scannedPages.isEmpty { isScanning = true }
                                    else { selectedPageIndex = max(0, index - 1) }
                                }
                            )
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

// MARK: - 2. FULL PAGE EDIT (Filters + Signature)
struct FullPageEditView: View {
    @Binding var pages: [UIImage]
    let currentIndex: Int
    let onSave: () -> Void
    
    @State private var internalIndex: Int
    @State private var currentFilter: FilterType = .original
    
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
                        // Display the image with the LIVE filter applied
                        Image(uiImage: applyFilter(to: pages[internalIndex], type: currentFilter))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding()
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
                        
                        // 2. SIGNATURE STAMP
                        Button(action: stampSignature) {
                            VStack {
                                Image(systemName: "signature")
                                    .font(.title2)
                                Text("Sign").font(.caption)
                            }
                        }
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
        
        let context = CIContext()
        guard let ciImage = CIImage(image: image) else { return image }
        
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        
        if type == .blackAndWhite {
            filter.contrast = 1.5 // High contrast
            filter.saturation = 0.0 // No color
            filter.brightness = 0.1
        } else {
            filter.saturation = 0.0 // Just grayscale
        }
        
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: cgImage)
    }
    
    // Logic: Stamp Signature
    private func stampSignature() {
        guard let signature = SignatureService.shared.signatureImage else { return }
        guard pages.indices.contains(internalIndex) else { return }
        
        // Ensure we are stamping on the filtered version
        let currentPage = applyFilter(to: pages[internalIndex], type: currentFilter)
        
        let renderer = UIGraphicsImageRenderer(size: currentPage.size)
        let newPage = renderer.image { context in
            // Draw original page
            currentPage.draw(at: .zero)
            
            // Calculate center
            let sigWidth = currentPage.size.width * 0.5
            let sigHeight = sigWidth * (signature.size.height / signature.size.width)
            let rect = CGRect(
                x: (currentPage.size.width - sigWidth) / 2,
                y: (currentPage.size.height - sigHeight) / 2,
                width: sigWidth,
                height: sigHeight
            )
            
            // Draw Signature (Multiply blend mode ensures black ink looks natural)
            context.cgContext.setBlendMode(.multiply)
            context.cgContext.setAlpha(1.0)
            signature.draw(in: rect)
        }
        
        // Save back to array
        pages[internalIndex] = newPage
        currentFilter = .original // Reset filter since we "burned" it in
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