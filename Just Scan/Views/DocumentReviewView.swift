//
//  DocumentReviewView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import PDFKit
@preconcurrency import Vision

struct DocumentReviewView: View {
    let document: Document
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex = 0
    @State private var showSignatureCanvas = false
    @State private var showSignatureOptions = false
    @State private var showSignaturePreview = false
    @State private var showSignaturePlacement = false
    @State private var showOCROverlay = false
    @State private var ocrText = ""
    @State private var isProcessingOCR = false
    @State private var showFilterOptions = false
    @State private var selectedFilter: FilterType = .blackAndWhite
    
    @StateObject private var ocrCoordinator = OCRCoordinator()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // PDF viewer
                if let pdfDocument = pdfDocument {
                    PDFViewRepresentable(
                        pdfDocument: pdfDocument,
                        pageIndex: $currentPageIndex
                    )
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture()
                            .onEnded { value in
                                let threshold: CGFloat = 50
                                if value.translation.width > threshold && currentPageIndex > 0 {
                                    // Swipe right - previous page
                                    currentPageIndex -= 1
                                } else if value.translation.width < -threshold && currentPageIndex < pdfDocument.pageCount - 1 {
                                    // Swipe left - next page
                                    currentPageIndex += 1
                                }
                            }
                    )
                } else {
                    ProgressView()
                }
                
                // OCR loading overlay
                if isProcessingOCR {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    
                    VStack {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Extracting text...")
                            .foregroundColor(.white)
                            .padding(.top)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                // Page navigation
                if let pdfDoc = pdfDocument, pdfDoc.pageCount > 1 {
                    ToolbarItem(placement: .principal) {
                        HStack {
                            Button {
                                if currentPageIndex > 0 {
                                    currentPageIndex -= 1
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(currentPageIndex == 0)
                            
                            Text("\(currentPageIndex + 1) / \(pdfDoc.pageCount)")
                                .font(.caption)
                                .frame(minWidth: 60)
                            
                            Button {
                                if currentPageIndex < pdfDoc.pageCount - 1 {
                                    currentPageIndex += 1
                                }
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(currentPageIndex >= pdfDoc.pageCount - 1)
                        }
                    }
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Filter button
                    Button {
                        showFilterOptions = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    
                    // OCR button
                    Button {
                        performOCR()
                    } label: {
                        Image(systemName: "text.viewfinder")
                    }
                    
                    // Signature button
                    Button {
                        showSignatureOptions = true
                    } label: {
                        Image(systemName: "signature")
                    }
                    
                    // Share button
                    ShareLink(item: document.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showSignatureCanvas) {
                SignatureCanvasView(onSave: {
                    // Auto-open placement view after signature is created
                    if signatureService.hasSignature {
                        showSignaturePlacement = true
                    }
                })
            }
            .sheet(isPresented: $showSignaturePreview) {
                SignaturePreviewView(onEdit: {
                    showSignaturePreview = false
                    showSignatureCanvas = true
                })
            }
            .sheet(isPresented: $showSignaturePlacement) {
                if signatureService.hasSignature, let signature = signatureService.signatureImage {
                    SignaturePlacementView(
                        document: document,
                        signatureImage: signature
                    )
                }
            }
            .confirmationDialog("Signature", isPresented: $showSignatureOptions) {
                if signatureService.hasSignature {
                    Button("Place Signature") {
                        if let signature = signatureService.signatureImage {
                            showSignaturePlacement = true
                        }
                    }
                    Button("Preview Signature") {
                        showSignaturePreview = true
                    }
                    Button("Edit Signature") {
                        showSignatureCanvas = true
                    }
                    Button("Delete Signature", role: .destructive) {
                        signatureService.clearSignature()
                    }
                } else {
                    Button("Create Signature") {
                        showSignatureCanvas = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Filter", isPresented: $showFilterOptions) {
                ForEach(FilterType.allCases, id: \.self) { filter in
                    Button(filter.rawValue) {
                        applyFilter(filter)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showOCROverlay) {
                OCRResultView(text: ocrText)
            }
            .onAppear {
                loadPDF()
            }
            .onChange(of: ocrCoordinator.resultText) { newValue in
                if let text = newValue {
                    isProcessingOCR = false
                    ocrText = text
                    showOCROverlay = true
                    ocrCoordinator.resultText = nil // Reset
                }
            }
            .onChange(of: ocrCoordinator.errorMessage) { newValue in
                if let errorMsg = newValue, !errorMsg.isEmpty {
                    isProcessingOCR = false
                    ocrText = "Error extracting text: \(errorMsg)"
                    showOCROverlay = true
                    ocrCoordinator.errorMessage = nil // Reset
                }
            }
        }
    }
    
    private var navigationTitle: String {
        if let pdfDoc = pdfDocument, pdfDoc.pageCount > 1 {
            return "\(document.fileName) (\(currentPageIndex + 1)/\(pdfDoc.pageCount))"
        }
        return document.fileName
    }
    
    private func loadPDF() {
        pdfDocument = PDFDocument(url: document.fileURL)
    }
    
    private func performOCR() {
        // Add safety check
        guard !isProcessingOCR else {
            print("OCR: Already processing")
            return
        }
        
        guard let pdfDocument = pdfDocument else {
            print("OCR: No PDF document")
            ocrText = "Error: No document loaded"
            showOCROverlay = true
            return
        }
        
        guard currentPageIndex >= 0 && currentPageIndex < pdfDocument.pageCount else {
            print("OCR: Invalid page index")
            ocrText = "Error: Invalid page"
            showOCROverlay = true
            return
        }
        
        guard let page = pdfDocument.page(at: currentPageIndex) else {
            print("OCR: Failed to get PDF page")
            ocrText = "Error: Could not load page"
            showOCROverlay = true
            return
        }
        
        isProcessingOCR = true
        
        // Render PDF page to image
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0 && pageRect.height > 0 else {
            isProcessingOCR = false
            print("OCR: Invalid page size")
            ocrText = "Error: Invalid page size"
            showOCROverlay = true
            return
        }
        
        // Limit size to prevent memory issues
        let maxSize: CGFloat = 3000
        let scale = min(1.0, maxSize / max(pageRect.width, pageRect.height))
        let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { context in
            context.cgContext.translateBy(x: 0, y: renderSize.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            context.cgContext.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        
        guard let cgImage = image.cgImage else {
            isProcessingOCR = false
            print("OCR: Failed to create CGImage")
            ocrText = "Error: Could not process image"
            showOCROverlay = true
            return
        }
        
        // Use coordinator to handle OCR
        ocrCoordinator.performOCR(cgImage: cgImage)
    }
    
    private func addSignatureToCurrentPage() {
        guard let pdfDocument = pdfDocument,
              let signatureImage = signatureService.signatureImage,
              let page = pdfDocument.page(at: currentPageIndex) else {
            print("Failed to get required objects for signature")
            return
        }
        
        let pageRect = page.bounds(for: .mediaBox)
        let signatureSize = CGSize(width: min(200, pageRect.width * 0.4), height: min(100, pageRect.height * 0.2))
        let signatureRect = CGRect(
            x: (pageRect.width - signatureSize.width) / 2,
            y: (pageRect.height - signatureSize.height) / 2,
            width: signatureSize.width,
            height: signatureSize.height
        )
        
        // Use UIGraphicsImageRenderer for better quality
        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
        let newImage = renderer.image { context in
            // Draw existing PDF page
            context.cgContext.translateBy(x: 0, y: pageRect.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: context.cgContext)
            
            // Reset transform and draw signature on top
            context.cgContext.translateBy(x: 0, y: -pageRect.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            signatureImage.draw(in: signatureRect)
        }
        
        guard let newPage = PDFPage(image: newImage) else {
            print("Failed to create PDF page from image")
            return
        }
        
        // Replace the page
        pdfDocument.removePage(at: currentPageIndex)
        pdfDocument.insert(newPage, at: currentPageIndex)
        
        // Save updated PDF
        if !pdfDocument.write(to: document.fileURL) {
            print("Failed to save PDF with signature")
        } else {
            // Reload the PDF to show the signature
            loadPDF()
        }
    }
    
    private func applyFilter(_ filterType: FilterType) {
        guard let pdfDocument = pdfDocument else {
            print("Filter: No PDF document available")
            return
        }
        
        // Re-apply filter to all pages
        let filteredPDF = DocumentService.shared.applyFilter(to: pdfDocument, filterType: filterType)
        
        // Replace current document
        if filteredPDF.write(to: document.fileURL) {
            // Reload the PDF to show the filtered version
            self.pdfDocument = filteredPDF
            selectedFilter = filterType
        } else {
            print("Filter: Failed to save filtered PDF")
        }
    }
}

@MainActor
class OCRCoordinator: ObservableObject {
    @Published var resultText: String?
    @Published var errorMessage: String?
    
    func performOCR(cgImage: CGImage) {
        let request = VNRecognizeTextRequest { [weak self] request, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    self.resultText = "No text found in this document."
                    return
                }
                
                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                
                if text.isEmpty {
                    self.resultText = "No text found in this document."
                } else {
                    self.resultText = text
                }
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        // Use DispatchQueue instead of Task.detached to avoid Sendable requirements
        // Vision framework types are not Sendable but are thread-safe
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                // Send error to main thread
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct PDFViewRepresentable: UIViewRepresentable {
    let pdfDocument: PDFDocument
    @Binding var pageIndex: Int
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemBackground
        // Disable double-tap to zoom to prevent shape changes
        pdfView.gestureRecognizers?.forEach { recognizer in
            if recognizer is UITapGestureRecognizer {
                let tapRecognizer = recognizer as! UITapGestureRecognizer
                if tapRecognizer.numberOfTapsRequired == 2 {
                    recognizer.isEnabled = false
                }
            }
        }
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        if let page = pdfDocument.page(at: pageIndex) {
            uiView.go(to: page)
        }
    }
}

