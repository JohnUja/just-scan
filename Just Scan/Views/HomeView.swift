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
                DocumentScannerView(
                    didFinishScanning: { images in
                        // Show reordering screen instead of processing immediately
                        pagesToReorder = images
                        showPageReorder = true
                    },
                    didCancel: {
                        // Scanner was cancelled, nothing to do
                    }
                )
            }
            .sheet(isPresented: $showPageReorder) {
                if !pagesToReorder.isEmpty {
                    PageReorderView(
                        pages: pagesToReorder,
                        onSave: { reorderedPages in
                            scannedImages = reorderedPages
                            showPageReorder = false
                        },
                        onCancel: {
                            scannedImages = nil
                            pagesToReorder = []
                            showPageReorder = false
                        }
                    )
                }
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
            // Apply B&W filter immediately
            let filteredImage = applyBlackAndWhiteFilter(to: image)
            
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
            _ = try documentService.savePDF(pdfDocument, filterType: .blackAndWhite)
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
}

