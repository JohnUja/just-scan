//
//  HomeView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import AVFoundation
import PDFKit
import UIKit

struct HomeView: View {
    @StateObject private var documentService = DocumentService.shared
    @StateObject private var signatureService = SignatureService.shared
    @State private var showScanner = false
    @State private var showSettings = false
    @State private var scannedImages: [UIImage]?
    @State private var selectedDocument: Document?
    @State private var showCameraPermissionAlert = false
    @State private var documentToRename: Document?
    @State private var documentToDelete: Document?
    @State private var showRenameAlert = false
    @State private var showDeleteAlert = false
    @State private var newDocumentName = ""
    @State private var showPageReorder = false
    @State private var pagesToReorder: [UIImage] = []
    
    let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    // Live camera tile (top-left)
                    LiveCameraTile {
                        checkCameraPermissionAndScan()
                    }
                    
                    // Document thumbnails
                    ForEach(documentService.documents) { document in
                        DocumentGridView(
                            document: document,
                            onTap: {
                                selectedDocument = document
                            },
                            onShare: {
                                shareDocument(document)
                            },
                            onRename: {
                                documentToRename = document
                                // Remove .pdf extension for editing
                                let nameWithoutExt = document.fileName.replacingOccurrences(of: ".pdf", with: "")
                                newDocumentName = nameWithoutExt
                                showRenameAlert = true
                            },
                            onDelete: {
                                documentToDelete = document
                                showDeleteAlert = true
                            }
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("My Scans")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                ZStack {
                    DocumentScannerView(
                        didFinishScanning: { images in
                            // Only show reorder screen if we have pages
                            guard !images.isEmpty else {
                                print("⚠️ No pages scanned")
                                // If we have existing pages, go back to review
                                if !pagesToReorder.isEmpty {
                                    showScanner = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                        showPageReorder = true
                                    }
                                }
                                return
                            }
                            // If we already have pages (coming back from review), append new ones
                            // Otherwise, start fresh
                            if pagesToReorder.isEmpty {
                                pagesToReorder = images
                            } else {
                                pagesToReorder.append(contentsOf: images)
                            }
                            // Close scanner sheet first
                            showScanner = false
                            // Wait for scanner to fully dismiss before showing reorder sheet
                            // This prevents "only presenting a single sheet is supported" warning
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                if !pagesToReorder.isEmpty {
                                    showPageReorder = true
                                }
                            }
                        },
                        didCancel: {
                            // Scanner was cancelled - if we have existing pages, go back to review
                            if !pagesToReorder.isEmpty {
                                showScanner = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    showPageReorder = true
                                }
                            }
                        }
                    )
                    
                    // Persistent banner showing existing pages (only when continuing session)
                    if !pagesToReorder.isEmpty {
                        VStack {
                            HStack {
                                Spacer()
                                VStack(spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.on.doc.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Continuing Session")
                                                .font(.system(size: 9))
                                                .fontWeight(.medium)
                                                .foregroundColor(.white.opacity(0.9))
                                            Text("\(pagesToReorder.count) page\(pagesToReorder.count == 1 ? "" : "s") already scanned")
                                                .font(.system(size: 11))
                                                .fontWeight(.bold)
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.blue, Color.blue.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(10)
                                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                                    .scaleEffect(0.8)
                                }
                                Spacer()
                            }
                            .padding(.top, 50)
                            Spacer()
                        }
                        .allowsHitTesting(false) // Don't block scanner interactions
                    }
                }
                .interactiveDismissDisabled(true) // Prevent accidental swipe-to-dismiss
            }
            .sheet(isPresented: Binding(
                get: { showPageReorder && !pagesToReorder.isEmpty },
                set: { newValue in
                    showPageReorder = newValue
                    if !newValue {
                        // Don't clear pages when dismissed - they might be going back to scanner
                        // Only clear if explicitly cancelled
                    }
                }
            )) {
                PageReorderView(
                    pages: $pagesToReorder, // Use binding so changes sync automatically
                    onSave: { reorderedPages in
                        scannedImages = reorderedPages
                        pagesToReorder = []
                        showPageReorder = false
                    },
                    onBack: {
                        // Go back to scanner - pages are already preserved in pagesToReorder via binding
                        showPageReorder = false
                        // Show scanner again after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showScanner = true
                        }
                    },
                    onCancel: {
                        // Full cancel - clear everything
                        scannedImages = nil
                        pagesToReorder = []
                        showPageReorder = false
                    }
                )
                .interactiveDismissDisabled(true) // Prevent accidental swipe-to-dismiss
            }
            .sheet(item: $selectedDocument) { document in
                DocumentReviewView(document: document)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Camera Permission Required", isPresented: $showCameraPermissionAlert) {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Just Scan needs camera access to scan documents. Please enable it in Settings.")
            }
            .onChange(of: scannedImages) { newValue in
                if let images = newValue {
                    processScannedImages(images)
                }
            }
            .alert("Rename Document", isPresented: $showRenameAlert) {
                TextField("Document name", text: $newDocumentName)
                Button("Cancel", role: .cancel) {
                    documentToRename = nil
                    newDocumentName = ""
                }
                Button("Rename") {
                    if let document = documentToRename, !newDocumentName.isEmpty {
                        renameDocument(document, newName: newDocumentName)
                    }
                }
            } message: {
                Text("Enter a new name for this document.")
            }
            .alert("Delete Document", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let document = documentToDelete {
                        deleteDocument(document)
                    }
                }
                Button("Cancel", role: .cancel) {
                    documentToDelete = nil
                }
            } message: {
                Text("Are you sure you want to delete this document? This action cannot be undone.")
            }
            // Refresh thumbnails when PDF files change
            .onReceive(NotificationCenter.default.publisher(for: .init("RefreshDocumentThumbnails"))) { _ in
                documentService.loadDocuments()
            }
        }
    }
    
    private func shareDocument(_ document: Document) {
        let activityVC = UIActivityViewController(activityItems: [document.fileURL], applicationActivities: nil)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityVC, animated: true)
        }
    }
    
    private func renameDocument(_ document: Document, newName: String) {
        // Ensure .pdf extension
        var finalName = newName
        if !finalName.hasSuffix(".pdf") {
            finalName += ".pdf"
        }
        
        do {
            try documentService.renameDocument(document, newName: finalName)
            documentToRename = nil
            newDocumentName = ""
        } catch {
            print("Failed to rename document: \(error)")
        }
    }
    
    private func deleteDocument(_ document: Document) {
        do {
            try documentService.deleteDocument(document)
            documentToDelete = nil
        } catch {
            print("Failed to delete document: \(error)")
        }
    }
    
    private func checkCameraPermissionAndScan() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
            showScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showScanner = true
                    } else {
                        showCameraPermissionAlert = true
                    }
                }
            }
        default:
            showCameraPermissionAlert = true
        }
    }
    
    private func processScannedImages(_ images: [UIImage]) {
        guard !images.isEmpty else {
            print("No images to process")
            return
        }
        
        let pdfDocument = PDFDocument()
        
        // Process all images and add to PDF
        for image in images {
            // Stage 1: downscale and lightly compress to save storage, then apply B&W
            let compressed = compressImage(image, maxDimension: 2500, quality: 0.8)
            let filteredImage = applyBlackAndWhiteFilter(to: compressed)
            
            // Ensure image is properly sized for PDF
            guard let pdfPage = PDFPage(image: filteredImage) else {
                print("Failed to create PDF page from image")
                continue
            }
            
            pdfDocument.insert(pdfPage, at: pdfDocument.pageCount)
        }
        
        // Verify we have pages before saving
        guard pdfDocument.pageCount > 0 else {
            print("No pages to save")
            return
        }
        
        do {
            // Already filtered; avoid reprocessing by passing .color
            _ = try documentService.savePDF(pdfDocument, filterType: .color)
            // Clear scanned images after successful save
            scannedImages = nil
        } catch {
            print("Failed to save document: \(error.localizedDescription)")
        }
    }
    
    private func applyBlackAndWhiteFilter(to image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
        let context = CIContext(options: nil)
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(1.5, forKey: kCIInputContrastKey) // High contrast
        filter.setValue(0.0, forKey: kCIInputSaturationKey) // Remove color
        
        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func compressImage(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        if scale >= 1.0 {
            // Still convert to JPEG to strip excess metadata/compression
            if let data = image.jpegData(compressionQuality: quality),
               let img = UIImage(data: data) {
                return img
            }
            return image
        }
        
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaled = renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        if let data = scaled.jpegData(compressionQuality: quality),
           let img = UIImage(data: data) {
            return img
        }
        return scaled
    }
}

