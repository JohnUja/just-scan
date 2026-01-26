//  DocumentReviewView.swift
//  Just Scan
//
//  FIXED: Brackets, parentheses, and view hierarchy nesting

import SwiftUI
@preconcurrency import PDFKit
import UIKit
import CoreImage
@preconcurrency import Vision

struct DocumentReviewView: View {
    let document: Document
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    
    fileprivate static let ciContext = CIContext(options: nil)
    
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex = 0
    @State private var showSignatureCanvas = false
    @State private var showSignatureOptions = false
    @State private var showSignaturePreview = false
    @State private var showOCROverlay = false
    @State private var ocrText = ""
    @State private var showColorPicker = false
    @State private var editingSignatureID: UUID? = nil // ✅ ID of signature being edited
    
    // Unified signature state
    @State private var signatures: [Int: [SignatureModel]] = [:]
    @State private var activeSignatureID: UUID? = nil {
        didSet {
            
            // ✅ Force view refresh when selection changes
            selectionBoxRefreshID = UUID()
        }
    }
    @State private var hasPendingChanges: Bool = false
    @State private var selectionBoxRefreshID = UUID()  // ✅ Force refresh when selection changes
    
    /// Debug counter for instrumentation
    @State private var selectionBoxRenderCount: Int = 0
    
    @StateObject private var editorProxy = PDFEditorControllerProxy()
    @StateObject private var ocrCoordinator = OCRCoordinator()
    
    // UI state
    @State private var showSignatureWarning: Bool = false
    @State private var showExitPrompt: Bool = false
    @State private var showDocumentSignatureWarning: Bool = false
    @State private var pendingShareAction: (() -> Void)? = nil
    @State private var showPaywall = false
    @State private var pendingExportType: ExportType? = nil
    @State private var isExporting = false  // ✅ Export lock to prevent double-taps
    @StateObject private var storeManager = StoreManager.shared
    
    enum ExportType {
        case secure
        case flattened
    }
    
    private let signatureAnnotationName = "JustScanSignature_v1"
    
    // Helper to identify signature annotations
    private func isSignatureAnnotation(_ ann: PDFAnnotation) -> Bool {
        if let name = ann.value(forAnnotationKey: .name) as? String,
           name == signatureAnnotationName {
            return true
        }
        if let contents = ann.contents,
           contents.contains("\"imageDataB64\"") {
            return true
        }
        return false
    }
    
    struct SignaturePlacement: Identifiable, Equatable {
        let id = UUID()
        var center: CGPoint
        var widthRatio: CGFloat
        var rotation: CGFloat
        var color: SignatureColor
        var aspectRatio: CGFloat
        let signatureImage: UIImage
        let imageHash: Int
        
        init(center: CGPoint, widthRatio: CGFloat, rotation: CGFloat,
             color: SignatureColor, aspectRatio: CGFloat, signatureImage: UIImage) {
            self.center = center
            self.widthRatio = widthRatio
            self.rotation = rotation
            self.color = color
            self.aspectRatio = aspectRatio
            self.signatureImage = signatureImage
            self.imageHash = signatureImage.pngData()?.hashValue ?? 0
        }
        
        static func == (lhs: SignaturePlacement, rhs: SignaturePlacement) -> Bool {
            lhs.id == rhs.id &&
            lhs.center == rhs.center &&
            lhs.widthRatio == rhs.widthRatio &&
            lhs.rotation == rhs.rotation &&
            lhs.color == rhs.color &&
            lhs.aspectRatio == rhs.aspectRatio &&
            lhs.imageHash == rhs.imageHash
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
                .interactiveDismissDisabled(true)
        }
                .sheet(isPresented: $showSignatureCanvas) {
            SignatureCanvasView(
                onSave: {
                    // ✅ If editing, update the signature's imageID in the document
                    if let editingID = editingSignatureID,
                       let activeID = activeSignatureID,
                       let activeSignature = signatures[currentPageIndex]?.first(where: { $0.id == activeID }),
                       activeSignature.imageID == editingID.uuidString,
                       let newImageID = signatureService.currentSignatureID?.uuidString {
                        // Update the signature model's imageID to point to the new signature image
                        editorProxy.updateSignatureImageID(signatureID: activeID, newImageID: newImageID)
                    } else if signatureService.hasSignature {
                        // New signature created - add it to document
                        let imageID = signatureService.currentSignatureID?.uuidString
                        editorProxy.addNewSignature(imageID: imageID)
                    }
                    editingSignatureID = nil // Clear editing state
                },
                existingSignatureID: editingSignatureID
            )
                }
                .sheet(isPresented: $showSignaturePreview) {
                    SignaturePreviewView(onEdit: {
                        showSignaturePreview = false
                        showSignatureCanvas = true
                    })
                }
        .sheet(isPresented: $showOCROverlay) {
            OCRResultView(text: ocrText)
                }
                .confirmationDialog("Signature", isPresented: $showSignatureOptions) {
            signatureOptionsDialog
        }
        .confirmationDialog("Change Color", isPresented: $showColorPicker) {
            colorPickerDialog
        }
        .alert("Multiple Signatures Detected", isPresented: $showSignatureWarning) {
                    Button("Cancel", role: .cancel) {}
            Button("Save Anyway") {
                _ = editorProxy.saveToDisk(url: document.fileURL)
                dismiss()
            }
        } message: {
            Text("This document contains different signature images. Are you sure you want to proceed?")
        }
        .confirmationDialog("Unsaved Changes", isPresented: $showExitPrompt) {
            unsavedChangesDialog
        } message: {
            Text("You have unsaved signature changes. Save or discard before exiting.")
        }
        .confirmationDialog("Different signatures detected", isPresented: $showDocumentSignatureWarning) {
            documentSignatureWarningDialog
        } message: {
            Text("This document contains different signature images across pages. Do you want to continue sharing?")
                }
                .onAppear {
                    loadPDF()
                }
                .onChange(of: ocrCoordinator.resultText) { newValue in
                    if let text = newValue {
                        ocrText = text
                        showOCROverlay = true
                        ocrCoordinator.resultText = nil
                    }
                }
                .onChange(of: ocrCoordinator.errorMessage) { newValue in
                    if let errorMsg = newValue, !errorMsg.isEmpty {
                        ocrText = "Error extracting text: \(errorMsg)"
                        showOCROverlay = true
                        ocrCoordinator.errorMessage = nil
                    }
                }
                .sheet(isPresented: $showPaywall) {
                    PaywallView(context: .export)
                        .onDisappear {
                            // When paywall dismisses, check if purchase was successful and retry export
                            if storeManager.hasPurchased {
                                retryPendingExport()
                            }
                        }
                }
                .onChange(of: storeManager.hasPurchased) { hasPurchased in
                    // If purchase happens while paywall is open, auto-dismiss and retry
                    if hasPurchased && showPaywall {
                        showPaywall = false
                        // Small delay to ensure paywall dismisses first
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            retryPendingExport()
                        }
                    }
                }
    }
    
    // MARK: - Dialog Content
    
    @ViewBuilder
    private var signatureOptionsDialog: some View {
        if signatureService.hasSignature {
            Button("Insert Signature") {
                let imageID = signatureService.currentSignatureID?.uuidString
                editorProxy.addNewSignature(imageID: imageID)
            }
            Button("Preview Signature") { showSignaturePreview = true }
            Button("Edit Signature") {
                // ✅ Edit the currently selected signature in the document
                if let activeID = activeSignatureID,
                   let activeSignature = signatures[currentPageIndex]?.first(where: { $0.id == activeID }),
                   let imageUUID = UUID(uuidString: activeSignature.imageID),
                   let signature = signatureService.signatureHistory.first(where: { $0.id == imageUUID }) {
                    // Open canvas with existing signature to edit
                    editingSignatureID = signature.id
                    showSignatureCanvas = true
                } else {
                    // No signature selected or signature not found - just open canvas
                    editingSignatureID = nil
                    showSignatureCanvas = true
                }
            }
        } else {
            Button("Create Signature") { showSignatureCanvas = true }
        }
        Button("Cancel", role: .cancel) {}
    }
    
    @ViewBuilder
    private var colorPickerDialog: some View {
        ForEach(SignatureColor.allCases, id: \.self) { color in
            Button(color.rawValue.capitalized) {
                editorProxy.changeActiveSignatureColor(color)
            }
        }
        Button("Cancel", role: .cancel) {}
    }
    
    @ViewBuilder
    private var unsavedChangesDialog: some View {
        Button("Save") {
            _ = editorProxy.saveToDisk(url: document.fileURL)
            editorProxy.selectSignature(nil)
            hasPendingChanges = false
            dismiss()
        }
        Button("Discard", role: .destructive) {
            loadPDF()
            dismiss()
        }
        Button("Cancel", role: .cancel) {}
    }
    
    @ViewBuilder
    private var documentSignatureWarningDialog: some View {
        Button("Share Anyway") {
            let action = pendingShareAction
            pendingShareAction = nil
            showDocumentSignatureWarning = false
            action?()
        }
        Button("Cancel", role: .cancel) {
            pendingShareAction = nil
            showDocumentSignatureWarning = false
        }
    }
    
    // MARK: - Content Body
    
    @ViewBuilder
    private var contentBody: some View {
            ZStack {
            viewerContent
            if ocrCoordinator.isProcessing {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Processing page \(currentPageIndex + 1)...")
                            .font(.caption).bold()
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
    
    @ViewBuilder
    private var viewerContent: some View {
                if let pdfDocument = pdfDocument {
                    VStack(spacing: 0) {
                GeometryReader { geometry in
                        ZStack {
                        PDFEditorRepresentable(
                                        pdfDocument: pdfDocument,
                            document: document,  // For JSON-based signature persistence
                            signatures: $signatures,
                            currentPageIndex: $currentPageIndex,
                            activeSignatureID: $activeSignatureID,
                            hasPendingChanges: $hasPendingChanges,
                            controllerProxy: editorProxy,
                            onPageChange: { newIndex in
                                editorProxy.selectSignature(nil)
                                currentPageIndex = newIndex
                            },
                            onSignatureChange: { newSignatures in
                                signatures = newSignatures
                            }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                        .overlay(
                            Group {
                                if let activeID = activeSignatureID,
                                   let activeSignature = signatures[currentPageIndex]?.first(where: { $0.id == activeID }),
                                   let screenRect = editorProxy.getActiveSignatureScreenRect(),
                                   screenRect.width > 0 && screenRect.height > 0,
                                   screenRect.midX.isFinite && screenRect.midY.isFinite {
                                    
                                    let rectCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)
                                    let toolbarOffset: CGFloat = 80
                                    
                                    // Calculate toolbar position (above selection box)
                                    let toolbarY = screenRect.minY - toolbarOffset
                                    let toolbarPosition = CGPoint(x: rectCenter.x, y: toolbarY)
                                    
                                    // ✅ Calculate rotation handle offset: positioned halfway between toolbar and selection box top
                                    // Toolbar is at: rectCenter.y - (screenRect.height/2) - toolbarOffset
                                    // Selection box top is at: rectCenter.y - (screenRect.height/2)
                                    // Middle point: (toolbarY + selectionBoxTopY) / 2
                                    let selectionBoxTopY = rectCenter.y - screenRect.height / 2
                                    let middleY = (toolbarY + selectionBoxTopY) / 2
                                    // Offset from selection box top to middle point
                                    let rotationHandleOffset = middleY - selectionBoxTopY
        
        ZStack {
                                        FloatingToolbarView(
                                            position: toolbarPosition,
                                            onMove: { delta in
                                                editorProxy.moveActiveSignature(by: delta)
                                            },
                                            onMoveEnd: {
                                                editorProxy.endMoveSignature()
                                            },
                                            onColor: { showColorPicker = true },
                                            onDelete: { editorProxy.deleteActiveSignature() },
                                            onDuplicate: { editorProxy.duplicateActiveSignature() },
                                            onCopy: {},
                                            onPaste: {},
                                            canPaste: false
                                        )
                                        .zIndex(2000)
                                        .id("toolbar-\(activeID.uuidString)")
                                        
                                        // ✅ Selection box with rotation handle INSIDE (rotates together like main branch)
                                        SelectionBoxView(
                                            position: rectCenter,
                                            size: screenRect.size,
                                            rotation: activeSignature.rotation,
                                            rotationHandleOffset: rotationHandleOffset, // ✅ Position handle between toolbar and box
                                            onMove: { delta in
                                                editorProxy.moveActiveSignature(by: delta)
                                            },
                                            onResize: { scaleFactor in
                                                editorProxy.resizeActiveSignature(by: scaleFactor)
                                            },
                                            onRotate: { angle in
                                                editorProxy.rotateActiveSignature(by: angle)
                                            },
                                            onMoveEnd: {
                                                editorProxy.endMoveSignature()
                                            },
                                            onResizeEnd: {
                                                editorProxy.endResizeSignature()
                                            },
                                            onRotateEnd: {
                                                editorProxy.endRotateSignature()
                                            }
                                        )
                                        // ✅ CRITICAL: Disable implicit animation to prevent jittering during PDF redraws
                                        .transaction { transaction in
                                            transaction.animation = nil
                                        }
                                        .zIndex(1500)
                                        .id("selection-\(activeID.uuidString)-\(currentPageIndex)-\(selectionBoxRefreshID)")
                                    }
                                }
                            }
                        )
                    }
                }
                paginationBar(for: pdfDocument)
            }
        } else {
            ProgressView()
        }
    }
    
    // MARK: - Helper Methods
    
    private func getSignatureImage(for signature: SignatureModel) -> UIImage? {
        if let uuid = UUID(uuidString: signature.imageID),
           let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
            return savedSignature.image
        }
        return signatureService.signatureImage
    }
    
    private func applyColor(to image: UIImage, color: UIColor) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            context.cgContext.setBlendMode(.destinationIn)
            context.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if hasPendingChanges {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                Button(action: { editorProxy.undo() }) {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                .disabled(!editorProxy.canUndo)
                        
                Button(action: { editorProxy.redo() }) {
                            Image(systemName: "arrow.uturn.forward.circle")
                        }
                .disabled(!editorProxy.canRedo)
                    }
                    
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: {
                    let imageID = signatureService.currentSignatureID?.uuidString
                    editorProxy.addNewSignature(imageID: imageID)
                }) {
                            Image(systemName: "plus.circle")
                        }
                        Button("Save") {
                    _ = editorProxy.saveToDisk(url: document.fileURL)
                    editorProxy.selectSignature(nil)
                    hasPendingChanges = false
                        }
                        .fontWeight(.semibold)
                
                Button("Done") {
                    showExitPrompt = true
                }
                    }
                } else {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                    _ = editorProxy.saveToDisk(url: document.fileURL)
                        dismiss()
                    }
                }
                
            if pdfDocument?.pageCount ?? 0 > 1 {
                    ToolbarItem(placement: .principal) {
                    Text("\(currentPageIndex + 1) / \(pdfDocument?.pageCount ?? 0)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { performOCR() } label: { Image(systemName: "text.viewfinder") }
                        .disabled(ocrCoordinator.isProcessing)
                    
                    Button { showSignatureOptions = true } label: { Image(systemName: "signature") }
                    
                    Menu {
                        Section("Export Options") {
                        Button { secureAndShare() } label: {
                            Label("Share Secured PDF", systemImage: "square.and.arrow.up")
                        }
                        // Only show Flattened PDF if document has signatures
                        if hasSignaturesInDocument {
                            Button { secureAndShareFlattened() } label: {
                                Label("Share Flattened PDF", systemImage: "square.and.arrow.up.on.square.fill")
                            }
                        }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
            }
        }
    }
    
// MARK: - Rotation Handle View (Fixed Position)

struct RotationHandleView: View {
    let position: CGPoint
    let rotation: CGFloat
    // ✅ Need the center point of the signature to calculate rotation angle
    let signatureCenter: CGPoint
    let onRotate: (CGFloat) -> Void
    let onRotateEnd: () -> Void
    
    @State private var lastRotationAngle: CGFloat = 0
    
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Color.gray.opacity(0.8))
            .clipShape(Circle())
            .position(position)
            // ✅ Don't rotate icon here - parent group handles rotation
            // Only apply rotation if not part of a rotated group (for backward compatibility)
            .rotationEffect(.degrees(rotation))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Calculate angle from signature center to current drag position
                        // Note: value.location is in screen coordinates, signatureCenter is also in screen coordinates
                        let currentAngle = atan2(value.location.y - signatureCenter.y, value.location.x - signatureCenter.x) * 180 / .pi
                        let startAngle = atan2(value.startLocation.y - signatureCenter.y, value.startLocation.x - signatureCenter.x) * 180 / .pi
                        
                        if lastRotationAngle == 0 {
                            lastRotationAngle = startAngle
                            return // Don't rotate on first touch, just set initial angle
                        }
                        
                        let delta = currentAngle - lastRotationAngle
                        // Normalize delta to -180 to 180 range
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
    
    // MARK: - Pagination Bar
    
    @ViewBuilder
    private func paginationBar(for pdfDocument: PDFDocument) -> some View {
        HStack(spacing: 25) {
            Button {
                currentPageIndex = max(0, currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left").font(.title2)
            }
            .disabled(currentPageIndex == 0)
            
            Text("Page \(currentPageIndex + 1) of \(pdfDocument.pageCount)")
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Button {
                currentPageIndex = min(pdfDocument.pageCount - 1, currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right").font(.title2)
            }
            .disabled(currentPageIndex >= pdfDocument.pageCount - 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Other Methods
    
    private var navigationTitle: String {
        if let pdfDoc = pdfDocument, pdfDoc.pageCount > 1 {
            return "\(document.fileName) (\(currentPageIndex + 1)/\(pdfDoc.pageCount))"
        }
        return document.fileName
    }
    
    private func loadPDF() {
        guard let fileURL = document.fileURL as URL?, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let savedPageIndex = currentPageIndex
        if let newPDF = PDFDocument(url: fileURL), newPDF.pageCount > 0 {
            pdfDocument = newPDF
            currentPageIndex = min(savedPageIndex, newPDF.pageCount - 1)
        }
    }
    
    private func performOCR() {
        guard !ocrCoordinator.isProcessing, let pdfDocument = pdfDocument else {
            ocrText = "Error: No document loaded"
            showOCROverlay = true
            return
        }
        let pageIndexToUse = max(0, min(currentPageIndex, pdfDocument.pageCount - 1))
        guard let page = pdfDocument.page(at: pageIndexToUse) else { return }
        
        let pageRect = page.bounds(for: .mediaBox)
        let maxSize: CGFloat = 3000
        let scale = min(1.0, maxSize / max(pageRect.width, pageRect.height))
        let renderSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { context in
            context.cgContext.translateBy(x: 0, y: renderSize.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        
        guard let cgImage = image.cgImage else { return }
        ocrCoordinator.performOCR(cgImage: cgImage)
    }
    
    private func secureAndShare() {
        // Check if user has purchased
        guard storeManager.hasPurchased else {
            pendingExportType = .secure
            showPaywall = true
            return
        }
        
        if hasMixedSignaturesInDocument() {
            pendingShareAction = { self.performSecureShare() }
            showDocumentSignatureWarning = true
        } else {
            performSecureShare()
        }
    }
    
    private func secureAndShareFlattened() {
        // Check if user has purchased
        guard storeManager.hasPurchased else {
            pendingExportType = .flattened
            showPaywall = true
            return
        }
        
        if hasMixedSignaturesInDocument() {
            pendingShareAction = { self.performFlattenedShare() }
            showDocumentSignatureWarning = true
        } else {
            performFlattenedShare()
        }
    }
    
    // Retry export after successful purchase
    private func retryPendingExport() {
        guard let exportType = pendingExportType else { return }
        pendingExportType = nil
        
        switch exportType {
        case .secure:
            secureAndShare()
        case .flattened:
            secureAndShareFlattened()
        }
    }
    
    private func performSecureShare() {
        guard let pdfDoc = pdfDocument else {
            print("❌ No PDF document to share")
            return
        }
        
        // ✅ Prevent double-taps
        guard !isExporting else { return }
        
        // ✅ Set export lock
        isExporting = true
        
        Task {
            // ✅ Lock lifecycle inside Task - defer runs when Task completes
            defer {
                Task { @MainActor in
                    isExporting = false
                }
            }
            
            // ✅ Snapshot PDF to Data on main thread (one-time cost)
            let baseData = await MainActor.run {
                pdfDoc.dataRepresentation()
            }
            
            guard let baseData = baseData else {
                print("❌ Failed to snapshot PDF")
                return
            }
            
            // ✅ Fix #3: Sanitize filename
            let safeName = document.fileName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            
            // ✅ Create temp file URL
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)_secured.pdf")
            try? FileManager.default.removeItem(at: tempURL)
            
            // ✅ Keep secure export on MainActor (safer with PDFKit)
            let resultURL = await MainActor.run {
                SignatureExportService.shared.exportSecure(
                    inputPDFData: baseData,
                    signatures: signatures,
                    to: tempURL
                )
            }
            
            guard let resultURL = resultURL else {
                print("❌ Failed to create secure export")
                return
            }
            
            // ✅ Back to main thread for UI
            await MainActor.run {
                print("✅ Created secure PDF with \(signatures.values.reduce(0) { $0 + $1.count }) signatures")
                sharePDF(at: resultURL, mode: "secured")
            }
        }
    }
    
    private func performFlattenedShare() {
        guard let pdfDoc = pdfDocument else {
            print("❌ No PDF document to share")
            return
        }
        
        // ✅ Prevent double-taps
        guard !isExporting else { return }
        
        // ✅ Set export lock
        isExporting = true
        
        Task {
            // ✅ Lock lifecycle inside Task - defer runs when Task completes
            defer {
                Task { @MainActor in
                    isExporting = false
                }
            }
            
            // ✅ Snapshot PDF to Data on main thread (one-time cost)
            let baseData = await MainActor.run {
                pdfDoc.dataRepresentation()
            }
            
            guard let baseData = baseData else {
                print("❌ Failed to snapshot PDF")
                return
            }
            
            // ✅ Fix #3: Sanitize filename
            let safeName = document.fileName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            
            // ✅ Create temp file URL
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)_flattened.pdf")
            try? FileManager.default.removeItem(at: tempURL)
            
            // ✅ Pre-fetch signature images on MainActor before background work
            let signatureImages = await MainActor.run {
                var images: [String: UIImage] = [:]
                for (_, pageSignatures) in signatures {
                    for signature in pageSignatures {
                        if let uuid = UUID(uuidString: signature.imageID),
                           let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
                            images[signature.imageID] = savedSignature.image
                        } else if let currentImage = signatureService.signatureImage {
                            images[signature.imageID] = currentImage
                        }
                    }
                }
                return images
            }
            
            // ✅ Heavy work off main thread using snapshot Data
            // Explicitly capture values to avoid Sendable issues
            let capturedBaseData = baseData
            let capturedSignatures = signatures
            let capturedSignatureImages = signatureImages
            let capturedTempURL = tempURL
            
            let resultURL = await Task.detached(priority: .userInitiated) { @Sendable () -> URL? in
                // Call the static method from nonisolated struct - no await needed
                return PDFExportHelper.exportFlattened(
                    inputPDFData: capturedBaseData,
                    signatures: capturedSignatures,
                    signatureImages: capturedSignatureImages,
                    to: capturedTempURL
                )
            }.value
            
            // ✅ Guard against nil (no force unwrap)
            guard let resultURL = resultURL else {
                print("❌ Failed to create flattened export")
                return
            }
            
            // ✅ Back to main thread for UI
            await MainActor.run {
                print("✅ Created flattened PDF with \(signatures.values.reduce(0) { $0 + $1.count }) signatures")
                sharePDF(at: resultURL, mode: "flattened")
            }
        }
    }
    
    // ✅ Update sharePDF to accept URL instead of PDFDocument
    private func sharePDF(at url: URL, mode: String) {
        // Verify file was created
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ Temporary PDF file does not exist")
            return
        }
        
        print("✅ PDF ready at: \(url.path)")
        
        // Present iOS share sheet
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        // For iPad, set popover presentation
        if let popover = activityVC.popoverPresentationController {
            popover.permittedArrowDirections = .any
        }
        
        // Find the topmost view controller to present from
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }
            topController.present(activityVC, animated: true)
            print("✅ Share sheet presented")
        } else {
            print("❌ Could not find view controller to present share sheet")
        }
    }
    
    /// Check if document has any signatures at all
    private var hasSignaturesInDocument: Bool {
        let totalSignatures = signatures.values.reduce(0) { $0 + $1.count }
        return totalSignatures > 0
    }
    
    /// Check if document contains multiple different signature images.
    /// Uses imageID (stable UUID) instead of hashValue (unreliable).
    /// ARCHITECTURE: Checks SignatureModel array (JSON store), not PDF annotations.
    private func hasMixedSignaturesInDocument() -> Bool {
        // Collect all unique imageIDs from all pages
        var uniqueImageIDs: Set<String> = []
        
        for (_, pageSignatures) in signatures {
            for signature in pageSignatures {
                uniqueImageIDs.insert(signature.imageID)
            }
        }
        
        // If more than one unique imageID, user has mixed signatures
        return uniqueImageIDs.count > 1
    }
}
