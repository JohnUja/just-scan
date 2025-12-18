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
    @State private var showSettings = false
    @State private var scannedImages: [UIImage]?
    @State private var selectedDocument: Document?
    @State private var showCameraPermissionAlert = false
    @State private var documentToRename: Document?
    @State private var documentToDelete: Document?
    @State private var showRenameAlert = false
    @State private var showDeleteAlert = false
    @State private var newDocumentName = ""
    @State private var showIntegratedScanner = false
    
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
            .sheet(isPresented: $showIntegratedScanner) {
                IntegratedScannerView(
                    onSave: { images in
                        processScannedImages(images)
                        showIntegratedScanner = false
                    },
                    onCancel: {
                        showIntegratedScanner = false
                    }
                )
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
            showIntegratedScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showIntegratedScanner = true
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
        
        do {
            // Images are already processed (filtered/signed) in IntegratedScannerView
            // Just save them as PDF with color filter (images are already processed)
            _ = try documentService.saveImagesAsPDF(images, filterType: .color)
            // Clear scanned images after successful save
            scannedImages = nil
        } catch {
            print("Failed to save document: \(error.localizedDescription)")
        }
    }
}

