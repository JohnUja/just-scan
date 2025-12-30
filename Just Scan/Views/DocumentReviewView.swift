//  DocumentReviewView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
@preconcurrency import PDFKit
import UIKit
import CoreImage
@preconcurrency import Vision

struct DocumentReviewView: View {
    let document: Document
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    
    // CRITICAL PERFORMANCE FIX: Static CIContext - created once, reused forever
    fileprivate static let ciContext = CIContext(options: nil)
    
    @State private var pdfDocument: PDFDocument?
    @State private var currentPageIndex = 0
    @State private var showSignatureCanvas = false
    @State private var showSignatureOptions = false
    @State private var showSignaturePreview = false
    @State private var showOCROverlay = false
    @State private var ocrText = ""
    @State private var showFilterOptions = false
    @State private var selectedFilter: FilterType = .blackAndWhite
    
    // Inline signature placement state
    @State private var isPlacingSignature = false
    @State private var signaturePlacements: [Int: [SignaturePlacement]] = [:] // multiple buffered signatures per page
    @State private var activePlacementID: [Int: UUID?] = [:] // which placement is active per page
    @State private var hasPendingChanges: Bool = false
    @State private var showSignatureWarning: Bool = false
    @State private var pendingSavePlacements: [SignaturePlacement]? = nil
    @State private var pendingSavePageIndex: Int? = nil
    @State private var pdfRefreshID = UUID()
    @State private var zoomRefreshID = UUID()  // Forces SwiftUI to recalculate signature positions during zoom
    @State private var pdfViewInstance: PDFView? = nil  // Reference to PDFView for coordinate conversion
    @State private var activeAnnotation: PDFAnnotation? = nil
    @State private var activeAnnotationPageIndex: Int? = nil
    @State private var editingPlacement: SignaturePlacement? = nil // Separate state for saved annotation editing
    @State private var savedAnnotationUndoStack: [Int: [SignaturePlacement]] = [:]
    @State private var savedAnnotationRedoStack: [Int: [SignaturePlacement]] = [:]
    @State private var showExitPrompt: Bool = false
    @State private var showDocumentSignatureWarning: Bool = false
    @State private var pendingShareAction: (() -> Void)? = nil
    @State private var refreshTimer: Timer?
    
    // Undo/redo stacks per page (snapshots of placements)
    @State private var undoStack: [Int: [[SignaturePlacement]]] = [:]
    @State private var redoStack: [Int: [[SignaturePlacement]]] = [:]
    
    @StateObject private var ocrCoordinator = OCRCoordinator()
    
    // Signature placement data structure
    struct SignaturePlacement: Identifiable, Equatable {
        let id = UUID()
        // Normalized center in PDF space (0...1, origin bottom-left)
        var center: CGPoint
        // Width as a fraction of PDF page width
        var widthRatio: CGFloat
        // Rotation in degrees (clockwise, SwiftUI convention)
        var rotation: CGFloat
        var color: SignatureColor
        var aspectRatio: CGFloat
        let signatureImage: UIImage
        
        static func == (lhs: SignaturePlacement, rhs: SignaturePlacement) -> Bool {
            lhs.id == rhs.id &&
            lhs.center == rhs.center &&
            lhs.widthRatio == rhs.widthRatio &&
            lhs.rotation == rhs.rotation &&
            lhs.color == rhs.color &&
            lhs.aspectRatio == rhs.aspectRatio
        }
    }
    
    private func secureAndShare() {
        guard let pdfDocument = pdfDocument else { return }
        
        // Commit ALL pages with buffered signatures before sharing
        // This ensures signatures on all pages are included in the shared PDF
        commitAllPagesInMemory()
        
        let proceedShare: () -> Void = {
        guard let data = pdfDocument.dataRepresentation() else {
            return
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("secured-\(UUID().uuidString).pdf")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            return
        }
        
        DispatchQueue.main.async {
            guard let top = topMostViewController() else { return }
            let activity = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            DispatchQueue.main.async {
                top.present(activity, animated: true)
            }
        }
        }

        if hasMixedSignaturesInDocument(pdfDocument) {
            pendingShareAction = proceedShare
            showDocumentSignatureWarning = true
            return
        }
        
        proceedShare()
    }
    
    // Flattened export-only share (baked)
    private func secureAndShareFlattened() {
        guard let pdfDocument = pdfDocument else { return }
        
        // Commit ALL pages with buffered signatures before sharing
        // This ensures signatures on all pages are included in the flattened PDF
        commitAllPagesInMemory()
        
        // Flatten the current PDF (no wipe/rebuild)
        let proceedFlattenShare: () -> Void = {
        guard let flattened = DocumentService.shared.flattenAndCompress(pdfDocument: pdfDocument) else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("secured-flattened-\(UUID().uuidString).pdf")
        guard flattened.write(to: tempURL) else { return }
        
        DispatchQueue.main.async {
            guard let top = topMostViewController() else { return }
            let activity = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            DispatchQueue.main.async {
                top.present(activity, animated: true)
            }
        }
        }

        if hasMixedSignaturesInDocument(pdfDocument) {
            pendingShareAction = proceedFlattenShare
            showDocumentSignatureWarning = true
            return
        }

        proceedFlattenShare()
    }
    
    private func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let window = scenes.first?.windows.first(where: { $0.isKeyWindow }),
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        if let nav = top as? UINavigationController { top = nav.visibleViewController ?? nav }
        if let tab = top as? UITabBarController { top = tab.selectedViewController ?? tab }
        return top
    }

    // PDFPageTransform removed - now using pdfView.convert for coordinate conversion

    // #region agent log helper
    fileprivate static func debugLog(hypothesisId: String, message: String, data: [String: Any]) {
        let payload: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run-scale-fix",
            "hypothesisId": hypothesisId,
            "location": "DocumentReviewView.swift",
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        // Note: Ensure this IP matches your Mac's IP (e.g. 192.168.x.x)
        var request = URLRequest(url: URL(string: "http://192.168.40.129:7242/ingest/e1b5a635-d792-4adb-a984-1f1e8f6d202d")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        URLSession.shared.dataTask(with: request).resume()
    }
    // #endregion
    
    var body: some View {
        NavigationStack {
            contentBody
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
                .interactiveDismissDisabled(true)
                .sheet(isPresented: $showSignatureCanvas) {
                    SignatureCanvasView(onSave: {
                        if signatureService.hasSignature {
                            appendNewPlacementIfNeeded()
                            isPlacingSignature = true
                        }
                    })
                }
                .sheet(isPresented: $showSignaturePreview) {
                    SignaturePreviewView(onEdit: {
                        showSignaturePreview = false
                        showSignatureCanvas = true
                    })
                }
                .confirmationDialog("Signature", isPresented: $showSignatureOptions) {
                    if signatureService.hasSignature {
                        Button("Insert Signature") {
                            appendNewPlacement()
                        }
                        Button("Preview Signature") { showSignaturePreview = true }
                        Button("Edit Signature") { showSignatureCanvas = true }
                        Button("Delete Signature", role: .destructive) { signatureService.clearSignature() }
                    } else {
                        Button("Create Signature") { showSignatureCanvas = true }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Filter", isPresented: $showFilterOptions) {
                    ForEach(FilterType.allCases, id: \.self) { filter in
                        Button(filter.rawValue) { applyFilter(filter) }
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
                .onChange(of: isPlacingSignature) { placing in
                    // Only append if placing is true AND we're not currently editing a saved annotation
                    if placing && activeAnnotation == nil {
                        appendNewPlacementIfNeeded()
                    }
                }
                .alert("Multiple Signatures Detected", isPresented: $showSignatureWarning) {
                    Button("Cancel", role: .cancel) {
                        pendingSavePlacements = nil
                        pendingSavePageIndex = nil
                    }
                    Button("Save Anyway") {
                        confirmSaveWithDifferentSignatures()
                    }
                } message: {
                    Text("This document contains different signature images. Are you sure you want to proceed?")
                }
                .confirmationDialog("Unsaved Changes", isPresented: $showExitPrompt) {
                    Button("Save") {
                        // Save all pages with buffered signatures
                        finalCommitToPDF()
                        // Ensure annotation is visible again when editing ends
                        if let annotation = activeAnnotation {
                            annotation.shouldDisplay = true
                        }
                        activeAnnotation = nil
                        activeAnnotationPageIndex = nil
                        editingPlacement = nil
                        pdfViewInstance?.setNeedsDisplay()
                        dismiss()
                    }
                    Button("Discard", role: .destructive) {
                        discardChangesAndReload()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You have unsaved signature changes. Save or discard before exiting.")
                }
                .confirmationDialog("Different signatures detected", isPresented: $showDocumentSignatureWarning) {
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
                } message: {
                    Text("This document contains different signature images across pages. Do you want to continue sharing?")
                }
        }
    }
    
    // MARK: - View Segments (split for type-checker)
    
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
            ocrOverlayView
        }
    }
    
    @ViewBuilder
    private var viewerContent: some View {
                if let pdfDocument = pdfDocument {
                    VStack(spacing: 0) {
                        ZStack {
                            // 1. BOTTOM LAYER: The PDF Document
                            pdfView(pdfDocument)
                                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                                .allowsHitTesting(true)
                            
                            // 2. MIDDLE LAYER: Detection for SAVED signatures
                            // We only enable this hit-testing if we aren't currently editing one
                            SavedSignatureOverlay(
                                pdfDocument: pdfDocument,
                                pageIndex: currentPageIndex,
                                pdfViewInstance: pdfViewInstance,
                                selectedSignature: .constant(nil),
                                currentlyEditingAnnotation: activeAnnotation,
                                onDelete: { _ in },
                                onEdit: { annotation in
                                    // commit current edits in memory before switching
                                    commitActiveEditInMemory()
                                    beginEditing(annotation: annotation, pageIndex: currentPageIndex)
                                }
                            )
                            .allowsHitTesting(activeAnnotation == nil && (signaturePlacements[currentPageIndex]?.isEmpty ?? true))
                            
                            // 3. TOP LAYER: The active signature sticker and handles
                            signatureOverlay(pdfDocument: pdfDocument)
                                .id(zoomRefreshID)  // ROOT FIX: Forces glue-to-paper during zoom
                        }
                
                paginationBar(for: pdfDocument)
            }
        } else {
            ProgressView()
        }
    }
    
    @ViewBuilder
    private func pdfView(_ pdfDocument: PDFDocument) -> some View {
        PDFViewRepresentable(
            pdfDocument: pdfDocument,
            pageIndex: $currentPageIndex,
            pdfViewInstance: $pdfViewInstance,
            refreshTrigger: $zoomRefreshID,  // Pass the zoom refresh trigger
            disableTapGestures: false // Always allow PDF taps
        )
        .ignoresSafeArea()
    }
                            
    @ViewBuilder
    private func signatureOverlay(pdfDocument: PDFDocument) -> some View {
        let placements = signaturePlacements[currentPageIndex] ?? []
        let activeID = activePlacementID[currentPageIndex] ?? nil
        
        ZStack {
            // Show selection/handles overlay for saved signature being edited (no image overlay)
            // This should be shown INSTEAD of iterating through placements
            if let activeAnnotation = activeAnnotation,
               activeAnnotationPageIndex == currentPageIndex,
               let placement = editingPlacement {
                // For saved signature editing: use unified overlay
                if let pdfView = pdfViewInstance {
                    UnifiedSignatureOverlay(
                    pageIndex: currentPageIndex,
                    pdfDocument: pdfDocument,
                        pdfView: pdfView,
                    placement: Binding(
                        get: { placement },
                        set: { newValue in
                            editingPlacement = newValue
                            // Immediately apply to annotation
                            if let page = pdfDocument.page(at: currentPageIndex),
                                   let annotation = self.activeAnnotation {
                                    _ = applyPlacement(newValue, to: annotation, on: page)
                                hasPendingChanges = true
                                    // Throttle PDF refresh to avoid lag during drag
                                    schedulePDFRefresh()
                            }
                        }
                    ),
                        isActive: true,
                    activeAnnotation: self.activeAnnotation,  // Pass annotation for lifecycle hooks
                    onDelete: {
                        // Delete the annotation directly
                        if let page = pdfDocument.page(at: currentPageIndex),
                           let annotation = self.activeAnnotation {
                            // Ensure annotation is visible before deletion (safety)
                            annotation.shouldDisplay = true
                            page.removeAnnotation(annotation)
                        }
                        self.activeAnnotation = nil
                        self.activeAnnotationPageIndex = nil
                        self.editingPlacement = nil
                        isPlacingSignature = false
                        hasPendingChanges = true
                        savedAnnotationUndoStack[currentPageIndex] = []
                        savedAnnotationRedoStack[currentPageIndex] = []
                        pdfViewInstance?.setNeedsDisplay()
                    },
                        onGestureStart: {
                            // Hide the PDF annotation immediately when editing starts to prevent "double vision"
                            if let annotation = self.activeAnnotation {
                                annotation.shouldDisplay = false
                                pdfViewInstance?.setNeedsDisplay()
                            }
                            registerSavedAnnotationUndoSnapshot(for: currentPageIndex)
                        },
                        onDuplicate: {
                            // Duplicate the current saved signature
                            guard let page = pdfDocument.page(at: currentPageIndex),
                                  let currentAnn = self.activeAnnotation,
                                  let placement = self.editingPlacement else { return }
                            
                            // 1. UNHIDE the original before we stop editing it
                            currentAnn.shouldDisplay = true
                            
                            // 2. Create duplicate with offset so it's not hidden
                            var duplicatePlacement = placement
                            duplicatePlacement.center = CGPoint(
                                x: min(0.95, placement.center.x + 0.05),
                                y: max(0.05, placement.center.y - 0.05)
                            )
                            
                            if let duplicateAnnotation = makeAnnotation(from: duplicatePlacement, on: page) {
                                page.addAnnotation(duplicateAnnotation)
                                
                                // 3. Switch focus to the new one
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    self.activeAnnotation = duplicateAnnotation
                                    self.activeAnnotationPageIndex = currentPageIndex
                                    self.editingPlacement = duplicatePlacement
                                }
                                
                                // 4. HIDE the NEW one because it's now the "Active" one being edited
                                duplicateAnnotation.shouldDisplay = false
                                
                                registerSavedAnnotationUndoSnapshot(for: currentPageIndex, placement: duplicatePlacement)
                                savedAnnotationRedoStack[currentPageIndex] = []
                                hasPendingChanges = true
                                pdfViewInstance?.setNeedsDisplay()
                            }
                        },
                        onDragStart: {
                            // Hide the annotation during drag for smooth ghost effect
                            if let annotation = self.activeAnnotation {
                                annotation.shouldDisplay = false
                                pdfViewInstance?.setNeedsDisplay()
                            }
                        },
                        onDragEnd: {
                            // Show the annotation again after drag
                            if let annotation = self.activeAnnotation {
                                annotation.shouldDisplay = true
                                pdfViewInstance?.setNeedsDisplay()
                            }
                        }
                    )
                    .onDisappear {
                        // SAFETY: If the overlay goes away, the real PDF annotation MUST show up
                        if let annotation = self.activeAnnotation {
                            annotation.shouldDisplay = true
                            pdfViewInstance?.setNeedsDisplay()
                        }
                    }
                }
            } else {
                // Only show overlays for NEW unsaved signatures (not editing saved)
                if let pdfView = pdfViewInstance {
                ForEach(placements, id: \.id) { placement in
                    let isActive = placement.id == activeID
                    let index = placements.firstIndex(where: { $0.id == placement.id }) ?? 0
                    let z = Double((placements.count - 1) - index) // older on top
                    
                        UnifiedSignatureOverlay(
                            pageIndex: currentPageIndex,
                            pdfDocument: pdfDocument,
                            pdfView: pdfView,
                            placement: signatureBinding(pageIndex: currentPageIndex, placementID: placement.id),
                            isActive: isActive,
                            activeAnnotation: nil,  // Unsaved signatures don't have annotations yet
                            onDelete: { deletePlacement(id: placement.id); hasPendingChanges = true },
                            onGestureStart: { registerUndoSnapshot(for: currentPageIndex); hasPendingChanges = true },
                            onDuplicate: { appendNewPlacement(using: placement.signatureImage); hasPendingChanges = true },
                            onDragStart: nil,
                            onDragEnd: nil
                        )
                        .zIndex(z + (isActive ? 1 : 0))
                        .onTapGesture {
                            if !isActive {
                            activePlacementID[currentPageIndex] = placement.id
                            isPlacingSignature = true
                            }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(true) // Always allow hit-testing
    }
    @ViewBuilder
    private func paginationView(for pdfDocument: PDFDocument) -> some View {
                        if pdfDocument.pageCount > 1 {
                            HStack {
                                Spacer()
                                Text("Page \(currentPageIndex + 1) of \(pdfDocument.pageCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 8)
                                Spacer()
                            }
                            .background(Color(.systemBackground))
                        }
                }
                
    @ViewBuilder
    private var ocrOverlayView: some View {
                if ocrCoordinator.isProcessing {
                    Color.black.opacity(0.7).ignoresSafeArea()
                    VStack {
                        ProgressView().scaleEffect(1.5).tint(.white)
                        Text("Extracting text...").foregroundColor(.white).padding(.top)
                    }
                }
            }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if hasPendingChanges {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button(action: { undoAction(for: currentPageIndex) }) {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                .disabled((undoStack[currentPageIndex]?.isEmpty ?? true) && (savedAnnotationUndoStack[currentPageIndex]?.isEmpty ?? true))
                        
                        Button(action: { redoAction(for: currentPageIndex) }) {
                            Image(systemName: "arrow.uturn.forward.circle")
                        }
                .disabled((redoStack[currentPageIndex]?.isEmpty ?? true) && (savedAnnotationRedoStack[currentPageIndex]?.isEmpty ?? true))
                    }
                    
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button(action: { appendNewPlacement() }) {
                            Image(systemName: "plus.circle")
                        }
                        Button("Save") {
                    // Save all pages with buffered signatures
                    finalCommitToPDF()
                        }
                        .fontWeight(.semibold)
                
                Button("Done") {
                    showExitPrompt = true
                }
                    }
                } else {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        commitActiveEditInMemory()
                        // Ensure annotation is visible again when editing ends
                        if let annotation = activeAnnotation {
                            annotation.shouldDisplay = true
                        }
                        activeAnnotation = nil
                        activeAnnotationPageIndex = nil
                        editingPlacement = nil
                        pdfViewInstance?.setNeedsDisplay()
                        dismiss()
                    }
                }
                
                if let pdfDoc = pdfDocument, pdfDoc.pageCount > 1 {
                    ToolbarItem(placement: .principal) {
                        Text("\(currentPageIndex + 1) / \(pdfDoc.pageCount)")
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
                            Button {
                                secureAndShare()
                            } label: {
                                Label("Share Secured PDF (locked)", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                secureAndShareFlattened()
                            } label: {
                                Label("Share Flattened PDF", systemImage: "square.and.arrow.up.on.square.fill")
                            }
                        }
                        
                        Section("Document Tools") {
                            Button("Filters", systemImage: "slider.horizontal.3") {
                                showFilterOptions = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
            }
        }
    }
    
    // MARK: - Bottom Pagination Bar
    @ViewBuilder
    private func paginationBar(for pdfDocument: PDFDocument) -> some View {
        HStack(spacing: 25) {
            Button {
                // Commit any edits before changing page
                if activeAnnotation != nil && activeAnnotationPageIndex == currentPageIndex {
                    commitActiveEditInMemory()
                }
                currentPageIndex = max(0, currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2)
            }
            .disabled(currentPageIndex == 0)
            
            Text("Page \(currentPageIndex + 1) of \(pdfDocument.pageCount)")
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Button {
                // Commit any edits before changing page
                if activeAnnotation != nil && activeAnnotationPageIndex == currentPageIndex {
                    commitActiveEditInMemory()
                }
                currentPageIndex = min(pdfDocument.pageCount - 1, currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title2)
            }
            .disabled(currentPageIndex >= pdfDocument.pageCount - 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Logic Helpers
    
    
    private func signatureBinding(pageIndex: Int, placementID: UUID) -> Binding<SignaturePlacement> {
        Binding(
            get: {
                let list = signaturePlacements[pageIndex] ?? []
                // Only return existing placement, don't create fallback
                return list.first(where: { $0.id == placementID }) ??
                SignaturePlacement(
                    center: .init(x: 0.5, y: 0.5),
                    widthRatio: 0.3,
                    rotation: 0,
                    color: .black,
                    aspectRatio: 2.0,
                    signatureImage: signatureService.signatureImage ?? UIImage()
                )
            },
            set: { newValue in
                var list = signaturePlacements[pageIndex] ?? []
                // Only mutate existing placement, don't append
                if let idx = list.firstIndex(where: { $0.id == placementID }) {
                    list[idx] = newValue
                    signaturePlacements[pageIndex] = list
                    redoStack[pageIndex] = []
                    hasPendingChanges = true
                }
                // Note: This binding is only for unsaved overlays, not saved annotation editing
                // Saved annotation editing uses editingPlacement binding directly
            }
        )
    }
    
    private func shouldWarnAboutDifferentSignatures(placements: [SignaturePlacement], page: PDFPage, pageIndex: Int) -> Bool {
        var signatureHashes: Set<String> = []
        
        for annotation in page.annotations where annotation.userName == "Signature" {
            if let data = signatureData(for: annotation) {
                signatureHashes.insert(data.hashValue.description)
            }
        }
        
        for placement in placements {
            if let data = placement.signatureImage.pngData() {
                signatureHashes.insert(data.hashValue.description)
            }
        }
        
        if signatureHashes.count > 1 {
            pendingSavePlacements = placements
            pendingSavePageIndex = pageIndex
            showSignatureWarning = true
            return true
        }
        return false
    }
    
    private func hasMixedSignaturesInDocument(_ pdfDocument: PDFDocument) -> Bool {
        var signatureHashes: Set<String> = []
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.userName == "Signature" {
                if let data = signatureData(for: annotation) {
                    signatureHashes.insert(data.hashValue.description)
                    if signatureHashes.count > 1 { return true }
                }
            }
        }
        return false
    }
    
    private func signatureData(for annotation: PDFAnnotation) -> Data? {
        if let stamp = annotation as? ImageStampAnnotation, let data = stamp.imageSnapshot?.pngData() {
            return data
        }
        if let contents = annotation.contents,
           let data = contents.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let b64 = json["imageDataB64"] as? String,
           let imgData = Data(base64Encoded: b64) {
            return imgData
        }
        return nil
    }
    
    private func confirmSaveWithDifferentSignatures() {
        guard
            let pageIndex = pendingSavePageIndex,
            let placements = pendingSavePlacements,
            let pdfDocument = pdfDocument,
            let page = pdfDocument.page(at: pageIndex)
        else {
            pendingSavePlacements = nil
            pendingSavePageIndex = nil
            showSignatureWarning = false
            return
        }
        
        performSave(placements: placements, pageIndex: pageIndex, page: page)
        pendingSavePlacements = nil
        pendingSavePageIndex = nil
        showSignatureWarning = false
    }
    
    private func placement(from annotation: PDFAnnotation, on page: PDFPage) -> SignaturePlacement? {
        // Only treat annotations explicitly marked as signatures
        guard annotation.userName == "Signature" else { return nil }
        
        let pageRect = page.bounds(for: .mediaBox)
        let bounds = annotation.bounds
        
        var rotation: CGFloat = 0
        var color: SignatureColor = .black
        var aspectRatio: CGFloat = bounds.width > 0 ? bounds.width / bounds.height : 2.0
        var image: UIImage?
        
        if let stamp = annotation as? ImageStampAnnotation {
            rotation = stamp.originalRotation
            color = stamp.originalColor
            aspectRatio = stamp.originalAspectRatio
            image = stamp.imageSnapshot
        }
        
        // Parse contents JSON for stored image/metadata
        if image == nil, let contents = annotation.contents,
           let data = contents.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            if let rot = json["rotation"] as? Double { rotation = CGFloat(rot) }
            if let colorRaw = json["color"] as? String, let c = SignatureColor(rawValue: colorRaw) { color = c }
            if let ar = json["aspectRatio"] as? Double { aspectRatio = CGFloat(ar) }
            if let b64 = json["imageDataB64"] as? String, let imgData = Data(base64Encoded: b64) {
                image = UIImage(data: imgData)
            }
        }
        
        // If we cannot recover the stored image, treat as non-editable
        guard let finalImage = image else { return nil }
        
        let center = CGPoint(
            x: bounds.midX / pageRect.width,
            y: bounds.midY / pageRect.height
        )
        
        return SignaturePlacement(
            center: center,
            widthRatio: bounds.width / pageRect.width,
            rotation: rotation,
            color: color,
            aspectRatio: aspectRatio,
            signatureImage: finalImage
        )
    }
    
    private func beginEditing(annotation: PDFAnnotation, pageIndex: Int) {
        // commit current editing overlay into the active annotation in memory (no disk)
        commitActiveEditInMemory()
        
        guard let pdfDocument = pdfDocument,
              let page = pdfDocument.page(at: pageIndex) else { return }
        
        // Accept any annotation with userName "Signature", not just ImageStampAnnotation
        guard annotation.userName == "Signature" else { return }
        
        // Create a placement from the annotation for editing
        guard let placement = placement(from: annotation, on: page) else { return }
        
        // If the annotation is not our custom type, replace it once with a mutable stamp
        let targetAnnotation: PDFAnnotation
        if let stamp = annotation as? ImageStampAnnotation {
            targetAnnotation = stamp
        } else if let converted = makeAnnotation(from: placement, on: page) {
            page.removeAnnotation(annotation)
            page.addAnnotation(converted)
            targetAnnotation = converted
        } else {
            return
        }
        
        // Set up for in-place editing with parsed placement - DO NOT add to signaturePlacements array
        activeAnnotation = targetAnnotation
        activeAnnotationPageIndex = pageIndex
        editingPlacement = placement // Store separately, not in signaturePlacements
        isPlacingSignature = false
        hasPendingChanges = false // only mark dirty on actual edits
        registerSavedAnnotationUndoSnapshot(for: pageIndex, placement: placement)
        savedAnnotationRedoStack[pageIndex] = []
        redoStack[pageIndex] = []
        pdfViewInstance?.setNeedsDisplay()
    }
    
    
    private func presentShare(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }
    
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
            context.cgContext.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        
        guard let cgImage = image.cgImage else { return }
        ocrCoordinator.performOCR(cgImage: cgImage)
    }
    
    private func applyFilter(_ filterType: FilterType) {
        guard let pdfDocument = pdfDocument else { return }
        let filteredPDF = DocumentService.shared.applyFilter(to: pdfDocument, filterType: filterType)
        if filteredPDF.write(to: document.fileURL) {
            self.pdfDocument = filteredPDF
            selectedFilter = filterType
        }
    }
    
    // Commit all pages in memory (without writing to disk) - used for sharing
    private func commitAllPagesInMemory() {
        guard let pdfDoc = pdfDocument else { return }
        
        // 1. Commit any active in-place edits first
        commitActiveEditInMemory()
        
        // 2. Loop through every page that has buffered signatures
        for (pageIdx, placements) in signaturePlacements {
            guard !placements.isEmpty,
                  let page = pdfDoc.page(at: pageIdx) else { continue }
            
            // Add only the new unsaved overlays as annotations
            for placement in placements {
                if let annotation = makeAnnotation(from: placement, on: page) {
                    page.addAnnotation(annotation)
                }
            }
        }
        
        // 3. Clear the buffers now that they are "Real" annotations (in memory)
        signaturePlacements = [:]
        activePlacementID = [:]
        isPlacingSignature = false
        hasPendingChanges = false
        
        // Note: We do NOT write to disk here - this is for sharing only
        pdfViewInstance?.setNeedsDisplay()
    }
    
    // Final commit: Save all pages with buffered signatures at once and write to disk
    private func finalCommitToPDF() {
        guard let pdfDoc = pdfDocument else { return }
        
        // 1. Unhide any currently active edit so it isn't saved as "invisible"
        if let activeAnn = activeAnnotation {
            activeAnn.shouldDisplay = true
        }
        
        // 2. Loop through every page that has unsaved signatures in the dictionary
        for (pageIdx, placements) in signaturePlacements {
            guard let page = pdfDoc.page(at: pageIdx) else { continue }
            for placement in placements {
                if let annotation = makeAnnotation(from: placement, on: page) {
                    page.addAnnotation(annotation)
                }
            }
        }
        
        // 3. Commit the "Active" in-place edit if there is one
        if let activeAnn = activeAnnotation,
           let pageIdx = activeAnnotationPageIndex,
           let placement = editingPlacement,
           let page = pdfDoc.page(at: pageIdx) {
            _ = applyPlacement(placement, to: activeAnn, on: page)
        }
        
        // 4. CLEAR EVERYTHING - Reset all buffers
        signaturePlacements = [:]
        activePlacementID = [:]
        activeAnnotation = nil
        activeAnnotationPageIndex = nil
        editingPlacement = nil
        isPlacingSignature = false
        hasPendingChanges = false
        
        // 5. WRITE TO DISK
        if let data = pdfDoc.dataRepresentation() {
            try? data.write(to: document.fileURL, options: .atomic)
            NotificationCenter.default.post(name: .init("RefreshDocumentThumbnails"), object: nil)
        }
        
        pdfViewInstance?.setNeedsDisplay()
    }
    
    private func saveSignatureToPage(pageIndex: Int, persistToDisk: Bool = true) {
        guard let pdfDocument = pdfDocument, let page = pdfDocument.page(at: pageIndex) else { return }
        
        // If editing a saved annotation in-place, commit changes to it
        if let activeAnnotation = activeAnnotation,
           activeAnnotationPageIndex == pageIndex,
           let placement = editingPlacement {
            // Mutate the existing annotation in place
            _ = applyPlacement(placement, to: activeAnnotation, on: page)
            
            // Clear editing state
            self.activeAnnotation = nil
            self.activeAnnotationPageIndex = nil
            self.editingPlacement = nil
            isPlacingSignature = false
            hasPendingChanges = false
            savedAnnotationUndoStack[pageIndex] = []
            savedAnnotationRedoStack[pageIndex] = []
            
            // Persist only if requested
            if persistToDisk, let data = pdfDocument.dataRepresentation() {
                try? data.write(to: document.fileURL, options: .atomic)
                NotificationCenter.default.post(name: .init("RefreshDocumentThumbnails"), object: nil)
            }
            pdfViewInstance?.setNeedsDisplay()
            return
        }
        
        // For new unsaved signatures: detect mixed signature images
        let unsaved = signaturePlacements[pageIndex] ?? []
        guard !unsaved.isEmpty else {
            // No unsaved signatures. If there are pending changes (e.g., deletion), persist them.
            if hasPendingChanges {
                if persistToDisk, let data = pdfDocument.dataRepresentation() {
                    try? data.write(to: document.fileURL, options: .atomic)
                    NotificationCenter.default.post(name: .init("RefreshDocumentThumbnails"), object: nil)
                }
                hasPendingChanges = false
                pdfViewInstance?.setNeedsDisplay()
            } else {
            signaturePlacements[pageIndex] = []
            activePlacementID[pageIndex] = nil
            isPlacingSignature = false
            }
            return
        }
        
        var allPlacements: [SignaturePlacement] = []
        for annotation in page.annotations where annotation.userName == "Signature" {
            if let p = placement(from: annotation, on: page) {
                allPlacements.append(p)
            }
        }
        allPlacements.append(contentsOf: unsaved)
        
        if shouldWarnAboutDifferentSignatures(placements: allPlacements, page: page, pageIndex: pageIndex) {
            return
        }
        
        // Add only the new unsaved overlays as annotations; existing annotations remain untouched
        for placement in unsaved {
            if let annotation = makeAnnotation(from: placement, on: page) {
                page.addAnnotation(annotation)
            }
        }
        
        // Save to disk only when requested
        if persistToDisk, let data = pdfDocument.dataRepresentation() {
            try? data.write(to: document.fileURL, options: .atomic)
            NotificationCenter.default.post(name: .init("RefreshDocumentThumbnails"), object: nil)
        }
        
        // Clear overlay state
        signaturePlacements[pageIndex] = []
        activePlacementID[pageIndex] = nil
        isPlacingSignature = false
        hasPendingChanges = false
        pdfViewInstance?.setNeedsDisplay()
    }
    
    private func performSave(placements: [SignaturePlacement], pageIndex: Int, page: PDFPage) {
        guard let pdfDocument = pdfDocument else { return }
        
        // Get existing annotations to avoid duplicates
        let existingAnnotations = page.annotations.filter { $0.userName == "Signature" }
        
        // Add all placements as annotations (only new ones that don't already exist)
        for placement in placements {
            // Check if this placement already exists as an annotation
            let placementExists = existingAnnotations.contains { annotation in
                if let existingPlacement = self.placement(from: annotation, on: page) {
                    // Compare by image data and approximate position
                    let existingData = existingPlacement.signatureImage.pngData()
                    let newData = placement.signatureImage.pngData()
                    return existingData == newData &&
                           abs(existingPlacement.center.x - placement.center.x) < 0.01 &&
                           abs(existingPlacement.center.y - placement.center.y) < 0.01
                }
                return false
            }
            
            // Only add if it doesn't already exist
            if !placementExists {
                if let annotation = makeAnnotation(from: placement, on: page) {
                    page.addAnnotation(annotation)
                }
            }
        }
        
        // Save to disk
        if let data = pdfDocument.dataRepresentation() {
            try? data.write(to: document.fileURL, options: .atomic)
            NotificationCenter.default.post(name: .init("RefreshDocumentThumbnails"), object: nil)
        }
        
        // Clear overlay state
        signaturePlacements[pageIndex] = []
        activePlacementID[pageIndex] = nil
        isPlacingSignature = false
        hasPendingChanges = false
        pdfViewInstance?.setNeedsDisplay()
    }
    
    // Bulk save removed for simplicity; saving happens per page as needed
    
    private func discardChangesAndReload() {
        // Reload from disk to discard in-memory edits
        loadPDF()
        signaturePlacements = [:]
        activePlacementID = [:]
        undoStack = [:]
        redoStack = [:]
        savedAnnotationUndoStack = [:]
        savedAnnotationRedoStack = [:]
        activeAnnotation = nil
        activeAnnotationPageIndex = nil
        editingPlacement = nil
        isPlacingSignature = false
        hasPendingChanges = false
        pdfViewInstance?.setNeedsDisplay()
    }
    
    private func deletePlacement(id: UUID) {
        registerUndoSnapshot(for: currentPageIndex)
        var list = signaturePlacements[currentPageIndex] ?? []
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: idx)
        signaturePlacements[currentPageIndex] = list
        if list.isEmpty {
            activePlacementID[currentPageIndex] = nil
        isPlacingSignature = false
        } else {
            activePlacementID[currentPageIndex] = list.last?.id
        }
        hasPendingChanges = true
        redoStack[currentPageIndex] = []
    }
    
    private func makeAnnotation(from placement: SignaturePlacement, on page: PDFPage) -> ImageStampAnnotation? {
        let pageRect = page.bounds(for: .mediaBox)
        
        let finalImage = placement.color == .black ? placement.signatureImage : applyColorToSignature(placement.signatureImage, color: placement.color)
        
        let pdfWidth = pageRect.width * placement.widthRatio
        let pdfHeight = pdfWidth / placement.aspectRatio
        
        // Calculate bounding box that accounts for rotation to prevent clipping
        let rotationRadians = abs(placement.rotation.truncatingRemainder(dividingBy: 180)) * .pi / 180
        let rotatedWidth = abs(cos(rotationRadians)) * pdfWidth + abs(sin(rotationRadians)) * pdfHeight
        let rotatedHeight = abs(sin(rotationRadians)) * pdfWidth + abs(cos(rotationRadians)) * pdfHeight
        
        // Use the larger dimension to ensure no clipping, with small padding
        let boundsWidth = max(rotatedWidth, pdfWidth) * 1.05 // 5% padding
        let boundsHeight = max(rotatedHeight, pdfHeight) * 1.05
        
        let pdfCenterX = placement.center.x * pageRect.width
        let pdfX = pdfCenterX - (boundsWidth / 2)
        let pdfCenterY = placement.center.y * pageRect.height
        let pdfY = pdfCenterY - (boundsHeight / 2)
        
        let clampedX = max(0, min(pdfX, pageRect.width - boundsWidth))
        let clampedY = max(0, min(pdfY, pageRect.height - boundsHeight))
        let signatureBounds = CGRect(x: clampedX, y: clampedY, width: boundsWidth, height: boundsHeight)
        
        let annotation = ImageStampAnnotation(
            bounds: signatureBounds,
            image: finalImage,
            rotation: placement.rotation,
            color: placement.color,
            aspectRatio: placement.aspectRatio
        )
        annotation.isLocked = true
        annotation.shouldPrint = true
        return annotation
    }
    
    private func applyPlacement(_ placement: SignaturePlacement, to annotation: PDFAnnotation, on page: PDFPage) -> PDFAnnotation? {
        let pageRect = page.bounds(for: .mediaBox)
        let pdfWidth = pageRect.width * placement.widthRatio
        let pdfHeight = pdfWidth / placement.aspectRatio
        
        // Calculate bounding box that accounts for rotation to prevent clipping
        let rotationRadians = abs(placement.rotation.truncatingRemainder(dividingBy: 180)) * .pi / 180
        let rotatedWidth = abs(cos(rotationRadians)) * pdfWidth + abs(sin(rotationRadians)) * pdfHeight
        let rotatedHeight = abs(sin(rotationRadians)) * pdfWidth + abs(cos(rotationRadians)) * pdfHeight
        
        // Use the larger dimension to ensure no clipping, with small padding
        let boundsWidth = max(rotatedWidth, pdfWidth) * 1.05 // 5% padding
        let boundsHeight = max(rotatedHeight, pdfHeight) * 1.05
        
        let pdfCenterX = placement.center.x * pageRect.width
        let pdfX = pdfCenterX - (boundsWidth / 2)
        let pdfCenterY = placement.center.y * pageRect.height
        let pdfY = pdfCenterY - (boundsHeight / 2)
        let clampedX = max(0, min(pdfX, pageRect.width - boundsWidth))
        let clampedY = max(0, min(pdfY, pageRect.height - boundsHeight))
        let signatureBounds = CGRect(x: clampedX, y: clampedY, width: boundsWidth, height: boundsHeight)
        
        // Apply color to signature image
        let finalImage = placement.color == .black ? placement.signatureImage : applyColorToSignature(placement.signatureImage, color: placement.color)
        
        // Mutate annotation in place (no remove/add) when possible
        if let stamp = annotation as? ImageStampAnnotation {
            stamp.bounds = signatureBounds
            stamp.originalRotation = placement.rotation
            stamp.originalColor = placement.color
            stamp.originalAspectRatio = placement.aspectRatio
            stamp.updateImage(finalImage) // This updates the image and triggers re-render
            return stamp
        } else {
            // Replace with our editable annotation so future edits stay in-place
            page.removeAnnotation(annotation)
            if let newAnnotation = makeAnnotation(from: placement, on: page) {
                page.addAnnotation(newAnnotation)
                return newAnnotation
            }
        }
        return nil
    }
    
    private func schedulePDFRefresh() {
        // Cancel any pending refresh
        refreshTimer?.invalidate()
        
        // Schedule refresh after a short delay (debounce) to avoid lag during drag
        // Use Task to ensure main actor execution
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            Task { @MainActor in
                self.pdfViewInstance?.setNeedsDisplay()
            }
        }
    }
    
    private func commitActiveEditInMemory() {
        guard
            let pageIndex = activeAnnotationPageIndex,
            let placement = editingPlacement,
            let pdfDocument = pdfDocument,
            let page = pdfDocument.page(at: pageIndex),
            let annotation = activeAnnotation
        else {
            activeAnnotation = nil
            activeAnnotationPageIndex = nil
            editingPlacement = nil
            return
        }
        
        let pageRect = page.bounds(for: .mediaBox)
        
        // Calculate the new bounds based on the normalized placement
        let pdfWidth = pageRect.width * placement.widthRatio
        let pdfHeight = pdfWidth / placement.aspectRatio
        
        // Calculate bounding box that accounts for rotation to prevent clipping
        let rotationRadians = abs(placement.rotation.truncatingRemainder(dividingBy: 180)) * .pi / 180
        let rotatedWidth = abs(cos(rotationRadians)) * pdfWidth + abs(sin(rotationRadians)) * pdfHeight
        let rotatedHeight = abs(sin(rotationRadians)) * pdfWidth + abs(cos(rotationRadians)) * pdfHeight
        
        // Use the larger dimension to ensure no clipping, with small padding
        let boundsWidth = max(rotatedWidth, pdfWidth) * 1.05 // 5% padding
        let boundsHeight = max(rotatedHeight, pdfHeight) * 1.05
        
        let pdfCenterX = placement.center.x * pageRect.width
        let pdfCenterY = placement.center.y * pageRect.height
        let pdfX = pdfCenterX - (boundsWidth / 2)
        let pdfY = pdfCenterY - (boundsHeight / 2)
        let clampedX = max(0, min(pdfX, pageRect.width - boundsWidth))
        let clampedY = max(0, min(pdfY, pageRect.height - boundsHeight))
        let newBounds = CGRect(x: clampedX, y: clampedY, width: boundsWidth, height: boundsHeight)
        
        // Mutate the annotation directly
        annotation.bounds = newBounds
        
        // If it's our custom ImageStampAnnotation, update its internal properties too
        if let stamp = annotation as? ImageStampAnnotation {
            stamp.originalRotation = placement.rotation
            stamp.originalColor = placement.color
            stamp.originalAspectRatio = placement.aspectRatio
            // Update the actual ink image if the color changed
            let finalImage = placement.color == .black ? placement.signatureImage : applyColorToSignature(placement.signatureImage, color: placement.color)
            stamp.updateImage(finalImage)
        }
        
        // Tell the PDFView to redraw only the affected area (high performance)
        pdfViewInstance?.setNeedsDisplay()
        
        hasPendingChanges = true
        // Don't clear editingPlacement here - it's needed for continued editing
    }
    
    private func appendNewPlacementIfNeeded() {
        // GUARD: Don't append if we're editing a saved annotation
        guard activeAnnotation == nil else { return }
        
        let placements = signaturePlacements[currentPageIndex] ?? []
        if placements.isEmpty {
            appendNewPlacement()
        }
    }
    
    private func appendNewPlacement(using image: UIImage? = nil) {
        let signatureImage = image ?? signatureService.signatureImage
        // GUARD: Need the image AND the pdfViewInstance to do the math
        guard let signatureImage, let pdfView = pdfViewInstance else { return }
        
        // 1. Get the screen center
        let screenCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        
        // 2. Convert that screen point to the actual PDF page coordinates
        if let page = pdfView.currentPage {
            let pdfPoint = pdfView.convert(screenCenter, to: page)
            let pageBounds = page.bounds(for: .mediaBox)
            
            let normX = pdfPoint.x / pageBounds.width
            let normY = pdfPoint.y / pageBounds.height
            
            let aspectRatio = signatureImage.size.height > 0 ? signatureImage.size.width / signatureImage.size.height : 2.0
            
            let newPlacement = SignaturePlacement(
                center: CGPoint(x: normX, y: normY),
            widthRatio: 0.3,
            rotation: 0,
            color: .black,
            aspectRatio: aspectRatio,
            signatureImage: signatureImage
            )
            
            let pIndex = pdfDocument?.index(for: page) ?? currentPageIndex
            registerUndoSnapshot(for: pIndex)
            signaturePlacements[pIndex, default: []].append(newPlacement)
            activePlacementID[pIndex] = newPlacement.id
            redoStack[pIndex] = []
        }
        isPlacingSignature = true
        hasPendingChanges = true
    }
    
    private func registerUndoSnapshot(for pageIndex: Int) {
        let placements = signaturePlacements[pageIndex] ?? []
        var stack = undoStack[pageIndex] ?? []
        if stack.last != placements {
        stack.append(placements)
        undoStack[pageIndex] = stack
        redoStack[pageIndex] = []
        }
    }
    
    private func registerSavedAnnotationUndoSnapshot(for pageIndex: Int, placement: SignaturePlacement? = nil) {
        guard let current = placement ?? editingPlacement else { return }
        var stack = savedAnnotationUndoStack[pageIndex] ?? []
        if stack.last != current {
            stack.append(current)
            savedAnnotationUndoStack[pageIndex] = stack
            savedAnnotationRedoStack[pageIndex] = []
        }
    }
    
    private func applySnapshot(for pageIndex: Int, placements: [SignaturePlacement]) {
        signaturePlacements[pageIndex] = placements
        activePlacementID[pageIndex] = placements.isEmpty ? nil : placements.last?.id
        isPlacingSignature = !placements.isEmpty
    }
    
    private func undoAction(for pageIndex: Int) {
        if let annotation = activeAnnotation,
           let placement = editingPlacement,
           let pdfDocument = pdfDocument,
           let page = pdfDocument.page(at: pageIndex) {
            guard var savedStack = savedAnnotationUndoStack[pageIndex], let previous = savedStack.popLast() else { return }
            let current = placement
            savedAnnotationUndoStack[pageIndex] = savedStack
            savedAnnotationRedoStack[pageIndex, default: []].append(current)
            editingPlacement = previous
            _ = applyPlacement(previous, to: annotation, on: page)
            hasPendingChanges = true
            pdfViewInstance?.setNeedsDisplay()
            return
        }
        
        guard var stack = undoStack[pageIndex], let previous = stack.popLast() else { return }
        let current = signaturePlacements[pageIndex] ?? []
        undoStack[pageIndex] = stack
        redoStack[pageIndex, default: []].append(current)
        applySnapshot(for: pageIndex, placements: previous)
    }
    
    private func redoAction(for pageIndex: Int) {
        if let annotation = activeAnnotation,
           let placement = editingPlacement,
           let pdfDocument = pdfDocument,
           let page = pdfDocument.page(at: pageIndex) {
            guard var stack = savedAnnotationRedoStack[pageIndex], let next = stack.popLast() else { return }
            let current = placement
            savedAnnotationRedoStack[pageIndex] = stack
            savedAnnotationUndoStack[pageIndex, default: []].append(current)
            editingPlacement = next
            _ = applyPlacement(next, to: annotation, on: page)
            hasPendingChanges = true
            pdfViewInstance?.setNeedsDisplay()
            return
        }
        
        guard var stack = redoStack[pageIndex], let next = stack.popLast() else { return }
        let current = signaturePlacements[pageIndex] ?? []
        redoStack[pageIndex] = stack
        undoStack[pageIndex, default: []].append(current)
        applySnapshot(for: pageIndex, placements: next)
    }
    
    private func applyColorToSignature(_ image: UIImage, color: SignatureColor) -> UIImage {
        let rect = CGRect(origin: .zero, size: image.size)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        return renderer.image { context in
            // Draw the original signature (preserves transparency)
            image.draw(in: rect)
            
            // Use 'sourceIn' blend mode to only color non-transparent pixels (the ink)
            context.cgContext.setBlendMode(.sourceIn)
            context.cgContext.setFillColor(color.uiColor.cgColor)
            context.cgContext.fill(rect)
        }
    }
    
    private func flipImageVertically(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: 0, y: size.height)
            cgContext.scaleBy(x: 1.0, y: -1.0)
            cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
    }
    
    // MARK: - Share Sheet
    private struct ActivityView: UIViewControllerRepresentable {
        let activityItems: [Any]
        
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }
        
        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }
}

// MARK: - Safe Collection Access
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Inline Signature Overlay Component
struct InlineSignatureOverlay: View {
    let pageIndex: Int
    let pdfDocument: PDFDocument
    let signatureImage: UIImage
    @Binding var placement: DocumentReviewView.SignaturePlacement
    let isActive: Bool
    let onSave: () -> Void
    let onDelete: () -> Void
    let onDuplicate: (DocumentReviewView.SignaturePlacement) -> Void
    let onGestureStart: () -> Void
    
    @State private var isSelected = true
    @State private var showColorPicker = false
    @State private var isMoveMode = false
    @State private var tempPosition: CGPoint? = nil
    @State private var tempWidthRatio: CGFloat? = nil
    @State private var tempRotation: CGFloat? = nil
    @State private var initialWidthRatio: CGFloat? = nil
    @State private var initialRotation: CGFloat? = nil
    
    var body: some View {
        // DEPRECATED: InlineSignatureOverlay is no longer used - replaced by UnifiedSignatureOverlay
        // This struct is kept for reference but should not be called
        EmptyView()
    }
    
    private func applyColor(_ image: UIImage, color: SignatureColor) -> UIImage {
        let rect = CGRect(origin: .zero, size: image.size)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        return renderer.image { context in
            // Draw the original signature (preserves transparency)
            image.draw(in: rect)
            
            // Use 'sourceIn' blend mode to only color non-transparent pixels (the ink)
            context.cgContext.setBlendMode(.sourceIn)
            context.cgContext.setFillColor(color.uiColor.cgColor)
            context.cgContext.fill(rect)
        }
    }
}

// MARK: - Floating Toolbar
struct FloatingToolbarViewInline: View {
    let position: CGPoint
    let offsetX: CGFloat
    let offsetY: CGFloat
    let displayWidth: CGFloat
    let displayHeight: CGFloat
    let pdfView: PDFView?  // PDFView for coordinate conversion
    let page: PDFPage?      // PDFPage for coordinate conversion
    let onColor: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onMoveStart: () -> Void
    let onMoveChanged: (CGPoint) -> Void
    let onMoveEnded: () -> Void
    @Binding var isMoveMode: Bool
    let currentPosition: CGPoint
    let currentWidthRatio: CGFloat
    let currentAspectRatio: CGFloat
    
    @State private var dragOffset: CGSize = .zero  // Track initial offset to prevent jump
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 16))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(isMoveMode ? Color.blue : Color(white: 0.3, opacity: 0.9))
                .clipShape(Circle())
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let pdfView = pdfView, let page = page else { return }
                            
                            if !isMoveMode {
                                isMoveMode = true
                                onMoveStart()
                                
                                // CALCULATE OFFSET: How far is the finger from the signature center?
                                let startGlobalTouch = CGPoint(
                                    x: position.x + value.startLocation.x - 18,
                                    y: position.y + value.startLocation.y - 18
                                )
                                let startLocInPage = pdfView.convert(startGlobalTouch, to: page)
                                let pageBounds = page.bounds(for: .mediaBox)
                                
                                // Store the difference so we don't "jump"
                                dragOffset = CGSize(
                                    width: (startLocInPage.x / pageBounds.width) - currentPosition.x,
                                    height: (startLocInPage.y / pageBounds.height) - currentPosition.y
                                )
                            }
                            
                            let globalTouch = CGPoint(
                                x: position.x + value.location.x - 18,
                                y: position.y + value.location.y - 18
                            )
                            let loc = pdfView.convert(globalTouch, to: page)
                            let pageBounds = page.bounds(for: .mediaBox)
                            
                            // Apply the position MINUS the initial offset to keep it "under the thumb"
                            let normX = (loc.x / pageBounds.width) - dragOffset.width
                            let normY = (loc.y / pageBounds.height) - dragOffset.height
                            
                            // CALCULATE BOUNDS CLAMPING - Keep signature fully on paper
                            let halfWidthRatio = currentWidthRatio / 2
                            let halfHeightRatio = (currentWidthRatio / currentAspectRatio) / 2
                            
                            onMoveChanged(CGPoint(
                                x: max(halfWidthRatio, min(1.0 - halfWidthRatio, normX)),
                                y: max(halfHeightRatio, min(1.0 - halfHeightRatio, normY))
                            ))
                        }
                        .onEnded { _ in
                            isMoveMode = false
                            dragOffset = .zero  // Reset offset
                            onMoveEnded()
                        }
                )
            
            Button { onColor() } label: {
                Image(systemName: "paintpalette.fill").font(.system(size: 16)).foregroundColor(.white).frame(width: 36, height: 36).background(Color(white: 0.3, opacity: 0.9)).clipShape(Circle())
            }
            Button { onDuplicate() } label: {
                Image(systemName: "square.on.square").font(.system(size: 16)).foregroundColor(.white).frame(width: 36, height: 36).background(Color(white: 0.3, opacity: 0.9)).clipShape(Circle())
            }
            Button { onDelete() } label: {
                Image(systemName: "trash.fill").font(.system(size: 16)).foregroundColor(.white).frame(width: 36, height: 36).background(Color(white: 0.3, opacity: 0.9)).clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .position(position)
    }
}

// MARK: - Saved Signature Overlay
struct SavedSignatureOverlay: View {
    let pdfDocument: PDFDocument
    let pageIndex: Int
    let pdfViewInstance: PDFView?  // PDFView instance for coordinate conversion
    @Binding var selectedSignature: (pageIndex: Int, annotation: PDFAnnotation)?
    let currentlyEditingAnnotation: PDFAnnotation?
    let onDelete: (PDFAnnotation) -> Void
    let onEdit: (PDFAnnotation) -> Void
    
    var body: some View {
        GeometryReader { _ in
            if let page = pdfDocument.page(at: pageIndex),
               let pdfView = pdfViewInstance,
               pdfView.scaleFactor > 0 {
                let signatureAnnotations = page.annotations.filter {
                    $0.userName == "Signature" && $0 !== currentlyEditingAnnotation
                }
                let annotatedItems = signatureAnnotations.map { (ObjectIdentifier($0), $0) }
                
                ForEach(annotatedItems, id: \.0) { _, annotation in
                        let bounds = annotation.bounds
                    let currentScale = pdfView.scaleFactor
                    
                    // Calculate PDF point (center of annotation bounds)
                    let pdfPoint = CGPoint(x: bounds.midX, y: bounds.midY)
                    
                    // Convert to screen coordinates
                    let center = pdfView.convert(pdfPoint, from: page)
                    let visualWidth = bounds.width * currentScale
                    let visualHeight = bounds.height * currentScale
                    
                    // Only show if coordinate is valid
                    if center != .zero {
                    Button {
                        onEdit(annotation)
                    } label: {
                        Color.black.opacity(0.001)
                    }
                    .frame(width: visualWidth + 20, height: visualHeight + 20)
                    .position(center)
                    }
                }
            }
        }
        .allowsHitTesting(true)
    }
}

// MARK: - Unified Signature Overlay (works for both new and saved signatures)
struct UnifiedSignatureOverlay: View {
    let pageIndex: Int
    let pdfDocument: PDFDocument
    let pdfView: PDFView
    @Binding var placement: DocumentReviewView.SignaturePlacement
    let isActive: Bool
    let activeAnnotation: PDFAnnotation?  // Reference to the PDF annotation for lifecycle hooks
    let onDelete: () -> Void
    let onGestureStart: () -> Void
    let onDuplicate: () -> Void
    let onDragStart: (() -> Void)? // Used to hide real annotation
    let onDragEnd: (() -> Void)?   // Used to show real annotation

    @State private var ghostPosition: CGPoint? = nil
    @State private var initialWidthRatio: CGFloat? = nil
    @State private var initialRotation: CGFloat? = nil
    @State private var rotationCenter: CGPoint? = nil  // Lock center during rotation to prevent bouncing
    @State private var showColorPicker = false
    @State private var isMoveMode = false  // State for move mode
    @State private var hasStartedGesture = false  // Prevent onGestureStart from running multiple times per touch

    var body: some View {
        // 1. Ensure the PDF engine is actually ready
        if let page = pdfDocument.page(at: pageIndex),
           pdfView.scaleFactor > 0.1 {
            
            let pageBounds = page.bounds(for: .mediaBox)
            let currentScale = pdfView.scaleFactor
            
            // 2. Determine center (use ghost if dragging)
            let effectiveCenter = ghostPosition ?? placement.center
            let pdfPoint = CGPoint(
                x: effectiveCenter.x * pageBounds.width,
                y: effectiveCenter.y * pageBounds.height
            )
            
            // 3. Convert to Screen (This is the "Magic" fix for zoom)
            let screenPoint = pdfView.convert(pdfPoint, from: page)
            
            // 4. Guard against (0,0) snapping
            if screenPoint != .zero {
                let visualWidth = (pageBounds.width * placement.widthRatio) * currentScale
                let visualHeight = visualWidth / placement.aspectRatio
                
                ZStack {
                    // 1. ALWAYS SHOW IMAGE (Tints based on color selection)
                    let coloredImage = placement.color == .black ? placement.signatureImage : applyColorToImage(placement.signatureImage, color: placement.color)
                    
                    Image(uiImage: coloredImage)
                        .resizable()
                        .frame(width: visualWidth, height: visualHeight)
                        .rotationEffect(.degrees(placement.rotation))
                        .position(screenPoint)
                        .opacity(ghostPosition != nil ? 0.0 : 1.0)  // Hide when ghost moves
                        .allowsHitTesting(false)  // ROOT FIX: Touch falls through to box gesture

                    // 2. GHOST IMAGE (Smooth moving layer)
                    if let ghostPos = ghostPosition {
                        let ghostPdfPoint = CGPoint(
                            x: ghostPos.x * pageBounds.width,
                            y: ghostPos.y * pageBounds.height
                        )
                        let ghostScreenPoint = pdfView.convert(ghostPdfPoint, from: page)
                        
                        Image(uiImage: coloredImage)
                            .resizable()
                            .opacity(0.6)
                            .frame(width: visualWidth, height: visualHeight)
                            .rotationEffect(.degrees(placement.rotation))
                            .position(ghostScreenPoint)
                    }

                    // 3. INTERACTIVE LAYER (Only if active)
                    if isActive {
                        InlineSelectionBoxView(
                            position: screenPoint,
                            size: CGSize(width: visualWidth, height: visualHeight),
                            rotation: placement.rotation,
                            scaleFactor: currentScale,
                            onMove: { _ in }, 
                            onResize: { factor in
                                if initialWidthRatio == nil { initialWidthRatio = placement.widthRatio }
                                let newWidthRatio = max(0.05, min(0.8, initialWidthRatio! * factor))
                                var updated = placement
                                updated.widthRatio = newWidthRatio
                                placement = updated
                            },
                            onResizeEnd: { 
                                initialWidthRatio = nil
                                pdfView.setNeedsDisplay()
                            },
                            onRotate: { angle in
                                if initialRotation == nil { 
                                    initialRotation = placement.rotation
                                    rotationCenter = placement.center  // Lock center at start
                                    onGestureStart()
                                }
                                let newRotation = (initialRotation! + angle).truncatingRemainder(dividingBy: 360)
                                var updated = placement
                                updated.rotation = newRotation < 0 ? newRotation + 360 : newRotation
                                updated.center = rotationCenter ?? placement.center  // Keep center locked
                                placement = updated
                            },
                            onRotateEnd: { 
                                initialRotation = nil
                                rotationCenter = nil  // Release center lock
                                pdfView.setNeedsDisplay()
                            },
                            onGestureStart: onGestureStart
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !hasStartedGesture {
                                        onGestureStart()  // Only runs once per touch!
                                        onDragStart?()  // Hide real annotation
                                        hasStartedGesture = true
                                    }
                                    
                                    let loc = pdfView.convert(value.location, to: page)
                                    
                                    // CALCULATE BOUNDS CLAMPING - Keep signature fully on paper
                                    let halfWidthRatio = placement.widthRatio / 2
                                    let halfHeightRatio = (placement.widthRatio / placement.aspectRatio) / 2
                                    
                                    let normX = max(halfWidthRatio, min(1.0 - halfWidthRatio, loc.x / pageBounds.width))
                                    let normY = max(halfHeightRatio, min(1.0 - halfHeightRatio, loc.y / pageBounds.height))
                                    
                                    self.ghostPosition = CGPoint(x: normX, y: normY)
                                    
                                    // Update placement in real-time for unsaved signatures
                                    if onDragStart == nil {
                                        var updated = placement
                                        updated.center = CGPoint(x: normX, y: normY)
                                        placement = updated
                                    }
                                }
                                .onEnded { _ in
                                    if let final = ghostPosition {
                                        var updated = placement
                                        updated.center = final
                                        placement = updated
                                    }
                                    ghostPosition = nil
                                    hasStartedGesture = false  // Reset for next touch
                                    onDragEnd?()  // Show real annotation
                                    pdfView.setNeedsDisplay()
                                }
                        )
                        
                        // Floating toolbar with clipping safety check
                        FloatingToolbarViewInline(
                            position: CGPoint(
                                x: screenPoint.x,
                                // IF signature is too high (y < 100), put toolbar BELOW (+ visualHeight/2 + 60)
                                y: screenPoint.y < 100 ? screenPoint.y + visualHeight/2 + 60 : screenPoint.y - visualHeight/2 - 60
                            ),
                            offsetX: 0,
                            offsetY: 0,
                            displayWidth: pageBounds.width * currentScale,
                            displayHeight: pageBounds.height * currentScale,
                            pdfView: pdfView,
                            page: page,
                            onColor: { showColorPicker = true },
                            onDelete: onDelete,
                            onDuplicate: onDuplicate,
                            onMoveStart: { onGestureStart() },
                            onMoveChanged: { newPos in
                                self.ghostPosition = newPos
                                // Update placement in real-time for unsaved signatures
                                if onDragStart == nil {
                                    var updated = placement
                                    updated.center = newPos
                                    placement = updated
                                }
                            },
                            onMoveEnded: {
                                if let final = ghostPosition { 
                                    var updated = placement
                                    updated.center = final
                                    placement = updated
                                }
                                ghostPosition = nil
                                pdfView.setNeedsDisplay()
                            },
                            isMoveMode: $isMoveMode,
                            currentPosition: effectiveCenter,
                            currentWidthRatio: placement.widthRatio,
                            currentAspectRatio: placement.aspectRatio
                        )
                    }
                }
                .confirmationDialog("Signature Color", isPresented: $showColorPicker) {
                    ForEach(SignatureColor.allCases, id: \.self) { color in
                        Button(color.rawValue) {
                            var updated = placement
                            updated.color = color
                            placement = updated
                            
                            // For saved annotations, immediately apply to PDF
                            if onDragStart != nil {
                                // This is a saved annotation - trigger parent to update PDF
                                pdfView.setNeedsDisplay()
                            } else {
                                // This is an unsaved signature - just refresh
                                pdfView.setNeedsDisplay()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .onAppear {
                    // Hide real ink when sticker appears
                    if let annotation = activeAnnotation {
                        annotation.shouldDisplay = false
                        pdfView.setNeedsDisplay()
                    }
                }
                .onDisappear {
                    // Reveal real ink when sticker dies
                    if let annotation = activeAnnotation {
                        annotation.shouldDisplay = true
                        pdfView.setNeedsDisplay()
                    }
                }
            }
        }
    }
    
    // Helper function to apply color to signature image
    private func applyColorToImage(_ image: UIImage, color: SignatureColor) -> UIImage {
        let rect = CGRect(origin: .zero, size: image.size)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        return renderer.image { context in
            image.draw(in: rect)
            context.cgContext.setBlendMode(.sourceIn)
            context.cgContext.setFillColor(color.uiColor.cgColor)
            context.cgContext.fill(rect)
        }
    }
}

// MARK: - Saved Signature Selection Overlay (handles only, no image) - DEPRECATED
struct SavedSignatureSelectionOverlay: View {
    let pageIndex: Int
    let pdfDocument: PDFDocument
    let pdfViewInstance: PDFView?  // PDFView instance for coordinate conversion
    @Binding var placement: DocumentReviewView.SignaturePlacement
    let onDelete: () -> Void
    let onGestureStart: () -> Void
    let onRefreshNeeded: () -> Void
    let onDuplicate: () -> Void
    let onDragStart: (() -> Void)?  // Optional callback to hide annotation
    let onDragEnd: (() -> Void)?    // Optional callback to show annotation
    
    @State private var isSelected = true
    @State private var showColorPicker = false
    @State private var tempPosition: CGPoint? = nil
    @State private var tempWidthRatio: CGFloat? = nil
    @State private var tempRotation: CGFloat? = nil
    @State private var initialWidthRatio: CGFloat? = nil
    @State private var initialRotation: CGFloat? = nil
    @State private var isMoveMode = false
    @State private var dragStartCenter: CGPoint? = nil
    @State private var ghostPosition: CGPoint? = nil  // Ghost position for smooth drag
    @State private var isDragging = false  // Track drag state
    
    var body: some View {
        GeometryReader { _ in
            // Ensure engine is ready and zoom is valid (>0) to prevent snapping to (0,0)
            if let page = pdfDocument.page(at: pageIndex),
               let pdfView = pdfViewInstance,
               pdfView.scaleFactor > 0 {
                
                let pageBounds = page.bounds(for: .mediaBox)
                
                // GUARD: Ensure the page and view actually have size to avoid snapping to (0,0)
                guard pageBounds.width > 0, pdfView.frame.width > 0 else {
                    return AnyView(EmptyView())
                }
                
                let currentScale = pdfView.scaleFactor
                let effectiveCenter = ghostPosition ?? (tempPosition ?? placement.center)
                let effectiveWidthRatio = tempWidthRatio ?? placement.widthRatio
                let effectiveRotation = tempRotation ?? placement.rotation
                
                // 1. Calculate PDF points (Bottom-Left origin)
                let pdfPoint = CGPoint(
                    x: effectiveCenter.x * pageBounds.width,
                    y: effectiveCenter.y * pageBounds.height
                )
                
                // 2. NATIVE CONVERSION: Maps PDF data points to Screen Pixels
                let screenPoint = pdfView.convert(pdfPoint, from: page)
                
                // 3. SCALE SIZE: Scales the box visual width by the zoom factor
                let visualWidth = (pageBounds.width * effectiveWidthRatio) * currentScale
                let visualHeight = visualWidth / placement.aspectRatio
                
                // Only draw if the engine returned a valid screen coordinate
                guard screenPoint.x.isFinite && screenPoint.y.isFinite,
                      screenPoint.x >= -10000 && screenPoint.x <= 10000,
                      screenPoint.y >= -10000 && screenPoint.y <= 10000,
                      screenPoint != .zero else {
                    return AnyView(EmptyView())
                }
                
                return AnyView(
                ZStack {
                    // GHOST IMAGE: Only visible during drag for smooth movement
                    if ghostPosition != nil {
                        // Use the same conversion logic as the selection box
                        let ghostPdfPoint = CGPoint(
                            x: ghostPosition!.x * pageBounds.width,
                            y: ghostPosition!.y * pageBounds.height
                        )
                        let ghostScreenPoint = pdfView.convert(ghostPdfPoint, from: page)
                        let ghostVisualWidth = (pageBounds.width * placement.widthRatio) * currentScale
                        let ghostVisualHeight = ghostVisualWidth / placement.aspectRatio
                        
                        // Apply color to ghost image
                        let coloredImage = placement.color == .black ? placement.signatureImage : applyColorToImage(placement.signatureImage, color: placement.color)
                        
                        Image(uiImage: coloredImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: ghostVisualWidth, height: ghostVisualHeight)
                            .rotationEffect(.degrees(effectiveRotation))
                            .opacity(0.6)  // Slightly transparent to show it's "ghost"
                            .position(ghostScreenPoint)
                    }
                    
                    // No image overlay - annotation is drawn by PDFKit
                    // Only show selection box and handles
                    
                    if isSelected {
                        // SELECTION BOX: Now pinned exactly to screenPoint using native conversion
                        InlineSelectionBoxView(
                            position: screenPoint,
                            size: CGSize(width: visualWidth, height: visualHeight),
                            rotation: effectiveRotation,
                            scaleFactor: currentScale,
                            onMove: { _ in },
                            onResize: { scaleFactor in
                                if initialWidthRatio == nil {
                                    initialWidthRatio = placement.widthRatio
                                }
                                let base = initialWidthRatio ?? placement.widthRatio
                                let newWidthRatio = max(0.05, min(0.8, base * scaleFactor))
                                tempWidthRatio = newWidthRatio
                                
                                // Update placement immediately so PDF annotation resizes in real-time
                                var updated = placement
                                updated.widthRatio = newWidthRatio
                                placement = updated  // This triggers the binding setter
                            },
                            onResizeEnd: {
                                if let final = tempWidthRatio {
                                    placement.widthRatio = final
                                }
                                tempWidthRatio = nil
                                initialWidthRatio = nil
                                onRefreshNeeded()
                            },
                            onRotate: { angle in
                                if initialRotation == nil {
                                    initialRotation = effectiveRotation
                                    onGestureStart()
                                }
                                let baseRotation = initialRotation ?? effectiveRotation
                                var newRotation = baseRotation + angle
                                newRotation = newRotation.truncatingRemainder(dividingBy: 360)
                                if newRotation < 0 { newRotation += 360 }
                                tempRotation = newRotation
                                
                                // Update placement immediately so PDF annotation rotates in real-time
                                var updated = placement
                                updated.rotation = newRotation
                                placement = updated  // This triggers the binding setter
                            },
                            onRotateEnd: {
                                if let final = tempRotation {
                                    placement.rotation = final
                                }
                                tempRotation = nil
                                initialRotation = nil
                                onRefreshNeeded()
                            },
                            onGestureStart: { onGestureStart() }
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    // Start drag
                                    if ghostPosition == nil {
                                        onGestureStart()
                                        dragStartCenter = placement.center
                                        isDragging = true
                                        // Tell parent to hide the real annotation
                                        onDragStart?()
                                    }
                                    
                                    // Convert the "Screen" touch to "PDF Page" points
                                    // This handles ALL offsets, scales, and rotations for you
                                    let locationInPage = pdfView.convert(value.location, to: page)
                                    
                                    // Normalize based on actual Page Bounds (not geometry.size)
                                    let normX = locationInPage.x / pageBounds.width
                                    let normY = locationInPage.y / pageBounds.height
                                    
                                    // Clamp to bounds
                                    let normalizedHeight = placement.widthRatio / placement.aspectRatio
                                    let newCenter = CGPoint(
                                        x: max(placement.widthRatio / 2, min(1.0 - placement.widthRatio / 2, normX)),
                                        y: max(normalizedHeight / 2, min(1.0 - normalizedHeight / 2, normY))
                                    )
                                    
                                    // ONLY update ghost - NO PDF refresh here!
                                    ghostPosition = newCenter
                                }
                                .onEnded { _ in
                                    // Commit to real placement
                                    if let finalPos = ghostPosition {
                                        var updated = placement
                                        updated.center = finalPos
                                        placement = updated  // This triggers binding setter ONCE
                                    }
                                    ghostPosition = nil
                                    dragStartCenter = nil
                                    isDragging = false
                                    onDragEnd?()  // Tell parent to show annotation again
                                    // Instead of refreshing the whole PDFView, just tell it to redraw
                                    pdfViewInstance?.setNeedsDisplay()
                                }
                        )
                        
                        // Floating toolbar positioned above the selection box
                        FloatingToolbarViewInline(
                            position: CGPoint(
                                x: screenPoint.x,
                                // IF signature is too high (y < 100), put toolbar BELOW (+ visualHeight/2 + 60)
                                y: screenPoint.y < 100 ? screenPoint.y + visualHeight/2 + 60 : screenPoint.y - visualHeight/2 - 60
                            ),
                            offsetX: 0,  // Not needed with native conversion
                            offsetY: 0,  // Not needed with native conversion
                            displayWidth: pageBounds.width * currentScale,
                            displayHeight: pageBounds.height * currentScale,
                            pdfView: pdfView,
                            page: page,
                            onColor: { showColorPicker = true },
                            onDelete: onDelete,
                            onDuplicate: onDuplicate,
                            onMoveStart: { onGestureStart() },
                            onMoveChanged: { newPos in
                                tempPosition = newPos
                                
                                // Update placement immediately so PDF annotation moves in real-time
                                var updated = placement
                                updated.center = newPos
                                placement = updated  // This triggers the binding setter
                            },
                            onMoveEnded: {
                                if let finalPos = tempPosition {
                                    placement.center = finalPos
                                }
                                tempPosition = nil
                                // Force immediate PDF refresh on gesture end
                                onRefreshNeeded()
                            },
                            isMoveMode: $isMoveMode,
                            currentPosition: effectiveCenter,
                            currentWidthRatio: effectiveWidthRatio,
                            currentAspectRatio: placement.aspectRatio
                        )
                    }
                }
                .confirmationDialog("Signature Color", isPresented: $showColorPicker) {
                    ForEach(SignatureColor.allCases, id: \.self) { color in
                        Button(color.rawValue) {
                            // Force update by creating a new placement struct to trigger binding setter
                            var updated = placement
                            updated.color = color
                            placement = updated
                            // Force immediate PDF refresh for color change (don't throttle)
                            onRefreshNeeded()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                )
            } else {
                // PDFView not ready, show nothing
                return AnyView(EmptyView())
            }
        }
        .allowsHitTesting(true)
    }
    
    // Helper function to apply color to signature image (same logic as DocumentReviewView.applyColorToSignature)
    private func applyColorToImage(_ image: UIImage, color: SignatureColor) -> UIImage {
        let rect = CGRect(origin: .zero, size: image.size)
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        return renderer.image { context in
            // Draw the original signature (preserves transparency)
            image.draw(in: rect)
            
            // Use 'sourceIn' blend mode to only color non-transparent pixels (the ink)
            context.cgContext.setBlendMode(.sourceIn)
            context.cgContext.setFillColor(color.uiColor.cgColor)
            context.cgContext.fill(rect)
        }
    }
}

// MARK: - Inline Selection Box
struct InlineSelectionBoxView: View {
    let position: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let scaleFactor: CGFloat  // PDFView scale factor for handle scaling
    let onMove: (CGSize) -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void
    let onRotate: (CGFloat) -> Void
    let onRotateEnd: () -> Void
    let onGestureStart: () -> Void
    
    // Calculate handle size inversely proportional to zoom (keeps handles constant visual size)
    private var handleSize: CGFloat {
        // Visual Fix: Use 14 as base. Max size 18, Min size 8.
        // This keeps them from ever feeling "Clunky"
        max(8, min(18, 14 / scaleFactor))
    }
    
    // Rotation/resize tracking
    @State private var gesturePivot: CGPoint? = nil
    @State private var startRotation: CGFloat = 0
    @State private var startAngle: CGFloat? = nil
    @State private var resizeStartRotation: CGFloat? = nil
    @State private var resizeStartDX: CGFloat? = nil
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 1.2 / scaleFactor)  // ROOT FIX: Visual thinness
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotation))
                .position(position)
            
            ForEach(0..<4) { index in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(Circle().stroke(Color.white, lineWidth: 0.8 / scaleFactor))  // Sharp white ring
                    .position(rotatedCornerPosition(for: index))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let pivot = position
                                // lock rotation at gesture start
                                if resizeStartRotation == nil {
                                            onGestureStart()
                                    resizeStartRotation = rotation
                                }
                                let radians = -(resizeStartRotation ?? 0) * .pi / 180
                                
                                let dx = value.location.x - pivot.x
                                let dy = value.location.y - pivot.y
                                let localDX = dx * cos(radians) - dy * sin(radians)
                                
                                if resizeStartDX == nil {
                                    let sdx = (value.startLocation.x - pivot.x) * cos(radians) - (value.startLocation.y - pivot.y) * sin(radians)
                                    resizeStartDX = sdx
                                }
                                guard let startDX = resizeStartDX, abs(startDX) > 0.1 else { return }
                                
                                let scaleFactor = localDX / startDX
                                onResize(scaleFactor)
                            }
                            .onEnded { _ in
                                resizeStartRotation = nil
                                resizeStartDX = nil
                                onResizeEnd()
                            }
                    )
            }
            
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: max(12, min(20, 16 / scaleFactor))))
                .foregroundColor(.white)
                .frame(width: handleSize, height: handleSize)
                .background(Color(white: 0.3, opacity: 0.9))
                .clipShape(Circle())
                .position(rotatedRotationHandlePosition)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if gesturePivot == nil {
                                    onGestureStart()
                                gesturePivot = position
                                startRotation = rotation
                                startAngle = angle(from: position, to: value.startLocation)
                                        // #region agent log
                                        DocumentReviewView.debugLog(
                                            hypothesisId: "H8",
                                            message: "selection box gesture start",
                                            data: [
                                        "startAngle": startAngle ?? -999,
                                                "capturedRotation": rotation,
                                                "position": ["x": position.x, "y": position.y],
                                                "size": ["w": size.width, "h": size.height]
                                            ]
                                        )
                                        // #endregion
                            }
                            
                            guard let pivot = gesturePivot, let sAngle = startAngle else { return }
                            
                            let current = angle(from: pivot, to: value.location)
                            let delta = normalizeAngle(current - sAngle)
                            
                        onRotate(delta) // pass delta; parent adds to its captured base
                        }
                        .onEnded { _ in
                            gesturePivot = nil
                            startAngle = nil
                            onRotateEnd()
                        }
                )
        }
    }
    
    private func cornerPosition(for index: Int) -> CGPoint {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        switch index {
        case 0: return CGPoint(x: position.x - halfWidth, y: position.y - halfHeight)
        case 1: return CGPoint(x: position.x + halfWidth, y: position.y - halfHeight)
        case 2: return CGPoint(x: position.x + halfWidth, y: position.y + halfHeight)
        case 3: return CGPoint(x: position.x - halfWidth, y: position.y + halfHeight)
        default: return position
        }
    }
    
    private var rotationHandlePosition: CGPoint {
        CGPoint(x: position.x, y: position.y - size.height / 2 - 20)
    }
    
    private func rotatedPoint(_ point: CGPoint, around center: CGPoint, degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        let translatedX = point.x - center.x
        let translatedY = point.y - center.y
        let rotatedX = translatedX * cos(radians) - translatedY * sin(radians)
        let rotatedY = translatedX * sin(radians) + translatedY * cos(radians)
        return CGPoint(x: rotatedX + center.x, y: rotatedY + center.y)
    }
    
    private func rotatedCornerPosition(for index: Int) -> CGPoint {
        rotatedPoint(cornerPosition(for: index), around: position, degrees: rotation)
    }
    
    private var rotatedRotationHandlePosition: CGPoint {
        rotatedPoint(rotationHandlePosition, around: position, degrees: rotation)
    }

    private func angle(from c: CGPoint, to p: CGPoint) -> CGFloat {
        atan2(p.y - c.y, p.x - c.x) * 180 / .pi
    }

    private func normalizeAngle(_ angle: CGFloat) -> CGFloat {
        var a = angle
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }
}

// MARK: - PDF View Representable (Fixed Braces)
struct PDFViewRepresentable: UIViewRepresentable {
    let pdfDocument: PDFDocument
    @Binding var pageIndex: Int
    @Binding var pdfViewInstance: PDFView?  // Binding to expose PDFView to parent
    @Binding var refreshTrigger: UUID  // Triggers SwiftUI recalculation during zoom
    var disableTapGestures: Bool = false
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        let coordinator = context.coordinator
        
        pdfView.document = pdfDocument
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.autoScales = true
        pdfView.backgroundColor = .systemBackground
        pdfView.isUserInteractionEnabled = true
        pdfView.displaysAsBook = false
        pdfView.displaysPageBreaks = false
        
        pdfView.maxScaleFactor = 5.0
        pdfView.minScaleFactor = 0.1
        
        pdfView.delegate = coordinator
        
        // Disable double-tap to zoom to prevent shape changes
        pdfView.gestureRecognizers?.forEach { recognizer in
            if let tapRecognizer = recognizer as? UITapGestureRecognizer,
               tapRecognizer.numberOfTapsRequired == 2 {
                recognizer.isEnabled = false
            }
        }
        
        coordinator.setupTapGestureHandling(pdfView: pdfView)
        
        // ROOT FIX: Hide the view until it fits perfectly
        pdfView.alpha = 0
        
        // ADD THIS: Redraw every time the user pinches to fix ghost trails
        coordinator.setupZoomObserver(pdfView: pdfView)
        coordinator.pdfViewInstance = pdfView  // Set reference for zoom observer
        
        // Fade in after layout is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            UIView.animate(withDuration: 0.2) {
                pdfView.alpha = 1
            }
            // Set fit scale after fade-in
            let fitScale = pdfView.scaleFactorForSizeToFit
            pdfView.scaleFactor = fitScale
            pdfView.minScaleFactor = fitScale * 0.2
            self.pdfViewInstance = pdfView
        }
        
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        // Only update document if it changed
        if uiView.document != pdfDocument {
            uiView.document = pdfDocument
        }
        
        // Update instance reference
        DispatchQueue.main.async {
            self.pdfViewInstance = uiView
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex, refreshTrigger: $refreshTrigger)
    }
    
    @MainActor
    class Coordinator: NSObject, PDFViewDelegate {
        @Binding var pageIndex: Int
        @Binding var refreshTrigger: UUID
        private var singleTapRecognizers: [UITapGestureRecognizer] = []
        var preservedScale: CGFloat = 0
        var preservedOffset: CGPoint = .zero
        weak var pdfViewInstance: PDFView?  // Reference for the refresh
        
        init(pageIndex: Binding<Int>, refreshTrigger: Binding<UUID>) {
            _pageIndex = pageIndex
            _refreshTrigger = refreshTrigger
        }
        
        @MainActor
        func setupTapGestureHandling(pdfView: PDFView) {
            pdfView.gestureRecognizers?.forEach { recognizer in
                if let tapRecognizer = recognizer as? UITapGestureRecognizer,
                   tapRecognizer.numberOfTapsRequired == 1 {
                    singleTapRecognizers.append(tapRecognizer)
                }
            }
        }
        
        @MainActor
        func setupZoomObserver(pdfView: PDFView) {
            // This is the "Magic Fix" for ghost trails during zoom
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScaleChange),
                name: .PDFViewScaleChanged,
                object: pdfView
            )
        }
        
        @objc func handleScaleChange() {
            // ROOT FIX: Force SwiftUI to re-calculate the sticker positions during zoom
            refreshTrigger = UUID()
        }
        
        @MainActor
        func updateTapGestureHandling(pdfView: PDFView, disable: Bool) {
            singleTapRecognizers.forEach { recognizer in
                recognizer.isEnabled = !disable
            }
            if singleTapRecognizers.isEmpty {
                setupTapGestureHandling(pdfView: pdfView)
            }
        }
        
        @MainActor
        func pdfViewDidChangeVisiblePages(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let index = document.index(for: currentPage)
            if index != NSNotFound {
                self.pageIndex = index
            }
        }
    }
            }
        
