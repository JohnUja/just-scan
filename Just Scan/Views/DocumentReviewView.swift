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
    @State private var zoomRefreshID = UUID()  // Forces SwiftUI to recalculate signature positions during zoom
    @State private var pdfViewInstance: PDFView? = nil  // Reference to PDFView for coordinate conversion
    @State private var activeAnnotation: PDFAnnotation? = nil
    @State private var activeAnnotationPageIndex: Int? = nil
    @State private var editingPlacement: SignaturePlacement? = nil // Separate state for saved annotation editing
    @State private var savedAnnotationUndoStack: [Int: [SignaturePlacement]] = [:]
    @State private var savedAnnotationRedoStack: [Int: [SignaturePlacement]] = [:]
    // ROOT FIX: Selection is UI state, not document state - removed from undo/redo stack
    // (Selection changes should not pollute undo/redo which is for actual edits: move/resize/rotate/delete/add)
    @State private var showExitPrompt: Bool = false
    @State private var showDocumentSignatureWarning: Bool = false
    @State private var pendingShareAction: (() -> Void)? = nil
    @State private var refreshTimer: Timer?
    
    // Undo/redo stacks per page (snapshots of placements)
    @State private var undoStack: [Int: [[SignaturePlacement]]] = [:]
    @State private var redoStack: [Int: [[SignaturePlacement]]] = [:]
    
    @StateObject private var ocrCoordinator = OCRCoordinator()
    
    // ROOT FIX: Use PDFAnnotationKey.name for reliable signature identification (persists across saves)
    private let signatureAnnotationName = "JustScanSignature_v1"
    
    // Helper to identify signature annotations (uses persisted .name key + contents fallback)
    private func isSignatureAnnotation(_ ann: PDFAnnotation) -> Bool {
        // 1) Strongest persisted marker: /NM (PDFAnnotationKey.name)
        if let name = ann.value(forAnnotationKey: .name) as? String,
           name == signatureAnnotationName {
            return true
        }
        
        // 2) Fallback: our JSON marker in /Contents
        if let contents = ann.contents,
           contents.contains("\"imageDataB64\"") {
            return true
        }
        
        return false
    }
    
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
        let imageHash: Int  // CRITICAL FIX: Hash for equality comparison (prevents undo/redo snapshot issues)
        
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
            lhs.imageHash == rhs.imageHash  // CRITICAL FIX: Include image hash in equality
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
                            addNewPlacement()
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
                            addNewPlacement()
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
                .onDisappear {
                    // CRITICAL FIX: Cleanup timer to prevent memory leaks and redraw spam
                    refreshTimer?.invalidate()
                    refreshTimer = nil
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
                        // Exit edit mode cleanly (ensures annotation visibility is restored)
                        setEditingAnnotation(nil, pageIndex: nil)
                        editingPlacement = nil
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
                                // CRITICAL FIX: Tap router must be attached to the PDF layer only.
                                // Attaching it to the parent ZStack causes toolbar taps to also trigger handleTap(),
                                // which can rapidly deselect/reselect and create a runaway update loop.
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            handleTap(locationInView: value.location)
                                        }
                                )

                            // 2. MIDDLE LAYER: Saved signature hit-zones (enables instant switching even while editing)
                            // This fixes the "tap signature A then can't tap signature B until Save" feeling.
                            SavedSignatureOverlay(
                                        pdfDocument: pdfDocument,
                                pageIndex: currentPageIndex,
                                pdfViewInstance: pdfViewInstance,
                                selectedSignature: .constant(nil),
                                currentlyEditingAnnotation: activeAnnotation,
                                onDelete: { _ in },
                                onEdit: { annotation in
                                    // Commit current edit and switch immediately
                                    commitActiveEditInMemory()
                                    setEditingAnnotation(nil, pageIndex: nil)
                                    editingPlacement = nil
                                    beginEditing(annotation: annotation, pageIndex: currentPageIndex)
                                }
                            )
                                        .allowsHitTesting(true)
                            
                            // 3. TOP LAYER: The active signature sticker and handles
                            signatureOverlay(pdfDocument: pdfDocument)
                                // ROOT FIX: Unique ID per page prevents mirroring; zoomRefreshID keeps it glued during zoom
                                .id("page-\(currentPageIndex)-\(zoomRefreshID)")
                                // ROOT FIX: Only block touches when we have active signatures to edit
                                .allowsHitTesting(
                                    activeAnnotation != nil || 
                                    !(signaturePlacements[currentPageIndex]?.isEmpty ?? true)
                                )
                        }
                        // Tap router moved to the PDF layer above (so toolbar taps don't trigger it).
                
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
            // ROOT FIX: Background tap is now handled by tap router gesture on ZStack (removed parameter)
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
                            let oldRotation = editingPlacement?.rotation ?? 0
                            editingPlacement = newValue
                            // Immediately apply to annotation
                            if let page = pdfDocument.page(at: currentPageIndex),
                                   let annotation = self.activeAnnotation {
                                    _ = applyPlacement(newValue, to: annotation, on: page)
                                hasPendingChanges = true
                                    // For rotation changes, update immediately; for position/size, throttle
                                    if abs(newValue.rotation - oldRotation) > 0.1 {
                                        // Rotation changed - update immediately
                                        pdfViewInstance?.setNeedsDisplay()
                                    } else {
                                        // Position/size changed - throttle to avoid lag during drag
                                        schedulePDFRefresh()
                                    }
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
                            // Undo snapshot only; annotation visibility is managed centrally by setEditingAnnotation(...)
                            registerSavedAnnotationUndoSnapshot(for: currentPageIndex)
                        },
                        onDuplicate: {
                            // HARMONY: Use the same master function for duplicates
                            guard let placement = self.editingPlacement else { return }
                            
                            // Exit edit mode (shows original) before duplicating
                            setEditingAnnotation(nil, pageIndex: nil)
                            editingPlacement = nil
                            
                            // 2. Use master function to create duplicate (handles offset automatically)
                            addNewPlacement(from: placement)
                            
                            // 3. Stop editing the original and let the new duplicate become active
                            self.activeAnnotation = nil
                            self.activeAnnotationPageIndex = nil
                            self.editingPlacement = nil
                            
                            pdfViewInstance?.setNeedsDisplay()
                        },
                        onDragStart: nil,
                        onDragEnd: nil,
                        onRotationChange: {
                            // Force immediate bounds recalculation when rotation changes
                            commitActiveEditInMemory()
                        },
                        onSelectInactive: nil
                    )
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
                            onDuplicate: { addNewPlacement(from: placement) },
                            onDragStart: nil,
                            onDragEnd: nil,
                            onRotationChange: nil,  // Unsaved signatures don't need bounds recalculation
                            onSelectInactive: {
                                if !isActive {
                                    activePlacementID[currentPageIndex] = placement.id
                                    isPlacingSignature = true
                                }
                            }
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
                .disabled((undoStack[currentPageIndex]?.isEmpty ?? true) && 
                         (savedAnnotationUndoStack[currentPageIndex]?.isEmpty ?? true))
                        
                        Button(action: { redoAction(for: currentPageIndex) }) {
                            Image(systemName: "arrow.uturn.forward.circle")
                        }
                .disabled((redoStack[currentPageIndex]?.isEmpty ?? true) && 
                         (savedAnnotationRedoStack[currentPageIndex]?.isEmpty ?? true))
                    }
                    
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button(action: { addNewPlacement() }) {
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
                        // Exit edit mode cleanly (ensures annotation visibility is restored)
                        setEditingAnnotation(nil, pageIndex: nil)
                        editingPlacement = nil
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
                    // Leaving the page while editing: restore annotation visibility and exit edit mode
                    setEditingAnnotation(nil, pageIndex: nil)
                    editingPlacement = nil
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
                    // Leaving the page while editing: restore annotation visibility and exit edit mode
                    setEditingAnnotation(nil, pageIndex: nil)
                    editingPlacement = nil
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
                    widthRatio: 0.195,  // 65% of original 0.3
                    rotation: 0,
                    color: .black,
                    aspectRatio: 2.0,
                    signatureImage: signatureService.signatureImage ?? UIImage()
                )  // imageHash computed automatically in init
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
        
        for annotation in page.annotations where isSignatureAnnotation(annotation) {
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
            for annotation in page.annotations where isSignatureAnnotation(annotation) {
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
        // Only treat annotations explicitly marked as signatures (using persisted .name key)
        guard isSignatureAnnotation(annotation) else { return nil }
        
        let pageRect = page.bounds(for: .mediaBox)
        let bounds = annotation.bounds
        
        var rotation: CGFloat = 0
        var color: SignatureColor = .black
        var aspectRatio: CGFloat = bounds.width > 0 ? bounds.width / bounds.height : 2.0
        var widthRatio: CGFloat? = nil
        var image: UIImage?
        
        if let stamp = annotation as? ImageStampAnnotation {
            rotation = stamp.originalRotation
            color = stamp.originalColor
            aspectRatio = stamp.originalAspectRatio
            widthRatio = stamp.originalWidthRatio
            image = stamp.imageSnapshot
        }
        
        // Parse contents JSON for stored image/metadata
        if image == nil, let contents = annotation.contents,
           let data = contents.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            if let rot = json["rotation"] as? Double { rotation = CGFloat(rot) }
            if let colorRaw = json["color"] as? String, let c = SignatureColor(rawValue: colorRaw) { color = c }
            if let ar = json["aspectRatio"] as? Double { aspectRatio = CGFloat(ar) }
            if let wr = json["widthRatio"] as? Double { widthRatio = CGFloat(wr) }
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
            // CRITICAL: Prefer persisted widthRatio to avoid "growing" due to padded/rotated bounds.
            widthRatio: widthRatio ?? (bounds.width / pageRect.width),
            rotation: rotation,
            color: color,
            aspectRatio: aspectRatio,
            signatureImage: finalImage
        )  // imageHash computed automatically in init
    }
    
    private func beginEditing(annotation: PDFAnnotation, pageIndex: Int) {
        // ROOT FIX: Selection changes are NOT recorded in undo/redo (selection is UI state, not document state)
        // Prevent unnecessary updates if the same annotation is tapped again
        if activeAnnotation === annotation && activeAnnotationPageIndex == pageIndex {
            return
        }
        
        // commit current editing overlay into the active annotation in memory (no disk)
        commitActiveEditInMemory()
        
        guard let pdfDocument = pdfDocument,
              let page = pdfDocument.page(at: pageIndex) else { return }
        
        // Accept any annotation marked as signature (using persisted .name key)
        guard isSignatureAnnotation(annotation) else { return }
        
        // If already editing this annotation, do nothing (prevents unnecessary updates)
        if activeAnnotation === annotation && activeAnnotationPageIndex == pageIndex {
            return
        }
        
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
        setEditingAnnotation(targetAnnotation, pageIndex: pageIndex)
        editingPlacement = placement // Store separately, not in signaturePlacements
        isPlacingSignature = false
        hasPendingChanges = false // only mark dirty on actual edits
        registerSavedAnnotationUndoSnapshot(for: pageIndex, placement: placement)
        savedAnnotationRedoStack[pageIndex] = []
        
        // Force immediate UI update to show selection box (immediate edit mode)
        pdfViewInstance?.setNeedsDisplay()
    }
    
    // ROOT FIX: Removed restoreSelection - selection is UI state, not in undo/redo
    
    // ROOT FIX: Centralize annotation visibility toggling to avoid races / double-rendering.
    // - When editing a saved signature: hide the PDFKit annotation and render it via SwiftUI overlay.
    // - When exiting edit mode: show the PDFKit annotation again.
    private func setEditingAnnotation(_ newAnn: PDFAnnotation?, pageIndex: Int?) {
        // Unhide previous
        if let old = activeAnnotation {
            old.shouldDisplay = true
        }
        
        activeAnnotation = newAnn
        activeAnnotationPageIndex = pageIndex
        
        // Hide new (during edit)
        if let new = newAnn {
            new.shouldDisplay = false
        }
        
        pdfViewInstance?.setNeedsDisplay()
    }
    
    // ROOT FIX: Single tap router - handles both selecting signatures and deselecting on empty tap
    private func handleTap(locationInView: CGPoint) {
        guard let pdfView = pdfViewInstance,
              let pdfDoc = pdfDocument,
              let page = pdfDoc.page(at: currentPageIndex) else { return }
        
        // 1) If tap hits a saved signature, select it (even if another is currently selected)
        let signatureAnnotations = page.annotations.filter { isSignatureAnnotation($0) }
        
        // Find the top-most hit (PDFKit draws later annotations on top, so reverse scan)
        if let hit = signatureAnnotations.reversed().first(where: { ann in
            let viewRect = pdfView.convert(ann.bounds, from: page)
            // Add some padding so it's easier to tap
            return viewRect.insetBy(dx: -10, dy: -10).contains(locationInView)
        }) {
            // Switch selection cleanly:
            // 1) Commit current edits
            // 2) Unhide previous annotation (if any)
            // 3) Begin editing the new annotation (which will hide it deterministically)
            commitActiveEditInMemory()
            setEditingAnnotation(nil, pageIndex: nil)
            editingPlacement = nil
            beginEditing(annotation: hit, pageIndex: currentPageIndex)
            return
        }
        
        // 2) Check if tap hits an unsaved overlay (SwiftUI placement)
        if let unsavedPlacements = signaturePlacements[currentPageIndex], !unsavedPlacements.isEmpty {
            let pageBounds = page.bounds(for: .mediaBox)
            let currentScale = pdfView.scaleFactor
            
            // Find the top-most unsaved placement that was hit
            if let hitPlacement = unsavedPlacements.reversed().first(where: { placement in
                let pdfPoint = CGPoint(
                    x: placement.center.x * pageBounds.width,
                    y: placement.center.y * pageBounds.height
                )
                let screenPoint = pdfView.convert(pdfPoint, from: page)
                let safeRatio = max(0.01, placement.aspectRatio)
                let visualWidth = (pageBounds.width * placement.widthRatio) * currentScale
                let visualHeight = visualWidth / safeRatio
                
                // Create a rect around the placement center with padding
                let placementRect = CGRect(
                    x: screenPoint.x - visualWidth / 2 - 10,
                    y: screenPoint.y - visualHeight / 2 - 10,
                    width: visualWidth + 20,
                    height: visualHeight + 20
                )
                return placementRect.contains(locationInView)
            }) {
                // Select the unsaved placement
                activePlacementID[currentPageIndex] = hitPlacement.id
        isPlacingSignature = true
                pdfView.setNeedsDisplay()
                return
            }
        }
        
        // 3) Otherwise: empty tap = deselect
        commitActiveEditInMemory()
        setEditingAnnotation(nil, pageIndex: nil)
        editingPlacement = nil
        activePlacementID[currentPageIndex] = nil
        isPlacingSignature = false
        pdfView.setNeedsDisplay()
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
        
        // CRITICAL FIX: Ensure active annotation is visible for export (prevents signatures disappearing on share)
        if let ann = activeAnnotation {
            ann.shouldDisplay = true
        }
        
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
        for annotation in page.annotations where isSignatureAnnotation(annotation) {
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
        let existingAnnotations = page.annotations.filter { isSignatureAnnotation($0) }
        
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
            // CRITICAL: Store the ORIGINAL image once; color is applied at draw-time from metadata.
            image: placement.signatureImage,
            rotation: placement.rotation,
            color: placement.color,
            aspectRatio: placement.aspectRatio,
            widthRatio: placement.widthRatio
        )
        // ROOT FIX: Mark annotation with persisted name key (survives save/reload)
        annotation.setValue(signatureAnnotationName, forAnnotationKey: .name)
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
        
        // Mutate annotation in place (no remove/add) when possible
        if let stamp = annotation as? ImageStampAnnotation {
            // Update bounds first (critical for rotation)
            stamp.bounds = signatureBounds
            // Update rotation property (this is what ImageStampAnnotation.draw() uses)
            stamp.originalRotation = placement.rotation
            stamp.originalColor = placement.color
            stamp.originalAspectRatio = placement.aspectRatio
            stamp.originalWidthRatio = placement.widthRatio
            // CRITICAL: Do NOT regenerate tinted images here (that is what caused the runaway memory/CPU).
            // Only update the stored image if it actually changed; tint is handled in draw(with:in:).
            stamp.updateImageIfNeeded(placement.signatureImage)
            // Force immediate redraw after rotation change
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
        // NOTE: DocumentReviewView is a struct, so we can't capture [weak self].
        // Instead, weak-capture the PDFView (a class) to avoid retain cycles.
        let pdfView = pdfViewInstance
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak pdfView] _ in
            Task { @MainActor in
                pdfView?.setNeedsDisplay()
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
            stamp.originalWidthRatio = placement.widthRatio
            // CRITICAL: Avoid regenerating tinted images. Keep original image, apply color at draw-time.
            stamp.updateImageIfNeeded(placement.signatureImage)
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
            addNewPlacement()
        }
    }
    
    // HARMONY MASTER FUNCTION: Single source of truth for all signature creation
    // Handles both "New Insert" (parent: nil) and "Duplicate" (parent: existing placement)
    private func addNewPlacement(image: UIImage? = nil, from parent: SignaturePlacement? = nil) {
        // ROOT FIX: Clear any active saved signature editing when inserting a new signature
        // This ensures the new signature is immediately visible
        if let currentAnnotation = activeAnnotation {
            commitActiveEditInMemory()
            // Exit edit mode cleanly (ensures annotation visibility is restored)
            setEditingAnnotation(nil, pageIndex: nil)
            editingPlacement = nil
        }
        
        let signatureImage = image ?? parent?.signatureImage ?? signatureService.signatureImage
        guard let signatureImage else { return }
        
        // If pdfViewInstance is nil, try to get it from the current view state
        // Otherwise, place signature at center of current page
        guard let pdfView = pdfViewInstance, let page = pdfView.currentPage else {
            // Fallback: Add to signaturePlacements without immediate visual feedback
            // This ensures the plus button works even if PDFView isn't ready
        let aspectRatio = signatureImage.size.height > 0 ? signatureImage.size.width / signatureImage.size.height : 2.0
            let newPlacement = SignaturePlacement(
                center: CGPoint(x: 0.5, y: 0.5),  // Center of page
                widthRatio: parent?.widthRatio ?? 0.195,
                rotation: parent?.rotation ?? 0,
                color: parent?.color ?? .black,
                aspectRatio: aspectRatio,
                signatureImage: signatureImage
            )  // imageHash computed automatically in init
        registerUndoSnapshot(for: currentPageIndex)
            signaturePlacements[currentPageIndex, default: []].append(newPlacement)
            activePlacementID[currentPageIndex] = newPlacement.id
            redoStack[currentPageIndex] = []
            hasPendingChanges = true
            isPlacingSignature = true
            zoomRefreshID = UUID()
            return
        }

        let pageBounds = page.bounds(for: .mediaBox)
        var finalCenter: CGPoint
        
        if let parent = parent {
            // CASE: DUPLICATE (Apply smaller offset so they don't stack)
            let offsetX = min(0.08, 1.0 - parent.center.x - parent.widthRatio/2 - 0.05)
            let offsetY = min(0.08, parent.center.y - parent.widthRatio/parent.aspectRatio/2 - 0.05)
            finalCenter = CGPoint(
                x: min(0.95, parent.center.x + max(0.05, offsetX)),
                y: max(0.05, parent.center.y - max(0.05, offsetY))
            )
        } else {
            // CASE: NEW INSERT (Convert screen center to PDF coordinates)
            let screenCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            let pdfPoint = pdfView.convert(screenCenter, to: page)
            finalCenter = CGPoint(
                x: pdfPoint.x / pageBounds.width,
                y: pdfPoint.y / pageBounds.height
            )
        }

        let aspectRatio = signatureImage.size.height > 0 ? signatureImage.size.width / signatureImage.size.height : 2.0
        
        let newPlacement = SignaturePlacement(
            center: finalCenter,
            widthRatio: parent?.widthRatio ?? 0.195,  // 65% of original 0.3
            rotation: parent?.rotation ?? 0,
            color: parent?.color ?? .black,
            aspectRatio: aspectRatio,
            signatureImage: signatureImage
        )  // imageHash computed automatically in init
        
        let pIndex = pdfDocument?.index(for: page) ?? currentPageIndex
        registerUndoSnapshot(for: pIndex)
        signaturePlacements[pIndex, default: []].append(newPlacement)
        activePlacementID[pIndex] = newPlacement.id
        redoStack[pIndex] = []
        hasPendingChanges = true
        isPlacingSignature = true
        
        // ROOT FIX: Force immediate UI refresh so signature appears instantly, not after save
        zoomRefreshID = UUID()
    }
    
    // DEPRECATED: Legacy wrapper - use addNewPlacement() directly
    // Keeping for backward compatibility but should be removed
    private func appendNewPlacement(using image: UIImage? = nil) {
        addNewPlacement(image: image, from: nil)
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
        // ROOT FIX: Selection changes are NOT in undo/redo (selection is UI state, not document state)
        // Undo/redo only handles actual edits: move/resize/rotate/delete/add
        
        // Check for annotation edits
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
        
        // Finally check for unsaved signature changes
        guard var stack = undoStack[pageIndex], let previous = stack.popLast() else { return }
        let current = signaturePlacements[pageIndex] ?? []
        undoStack[pageIndex] = stack
        redoStack[pageIndex, default: []].append(current)
        applySnapshot(for: pageIndex, placements: previous)
        hasPendingChanges = true
    }
    
    private func redoAction(for pageIndex: Int) {
        // ROOT FIX: Selection changes are NOT in undo/redo (selection is UI state, not document state)
        // Undo/redo only handles actual edits: move/resize/rotate/delete/add
        
        // Check for annotation edits
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
        
        // Finally check for unsaved signature changes
        guard var stack = redoStack[pageIndex], let next = stack.popLast() else { return }
        let current = signaturePlacements[pageIndex] ?? []
        redoStack[pageIndex] = stack
        undoStack[pageIndex, default: []].append(current)
        applySnapshot(for: pageIndex, placements: next)
        hasPendingChanges = true
    }
    
    // NOTE: Color is now applied at render-time (SwiftUI template tint + PDFAnnotation draw-time tint).
    // Keeping this removed helper out prevents accidental reintroduction of heavy image regeneration.
    
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
    
    // ROOT FIX: Use persisted .name key + contents marker to identify signatures
    private func isSignature(_ ann: PDFAnnotation) -> Bool {
        // 1) Strongest persisted marker: /NM (PDFAnnotationKey.name)
        if let name = ann.value(forAnnotationKey: .name) as? String,
           name == "JustScanSignature_v1" {
            return true
        }
        // 2) Fallback: our JSON marker in /Contents
        if let contents = ann.contents, contents.contains("\"imageDataB64\"") {
            return true
        }
        return false
    }
    
    var body: some View {
        GeometryReader { _ in
            if let page = pdfDocument.page(at: pageIndex),
               let pdfView = pdfViewInstance,
               pdfView.scaleFactor > 0 {
                let signatureAnnotations = page.annotations.filter {
                    isSignature($0) && $0 !== currentlyEditingAnnotation
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
    let activeAnnotation: PDFAnnotation?
    let onDelete: () -> Void
    let onGestureStart: () -> Void
    let onDuplicate: () -> Void
    let onDragStart: (() -> Void)?
    let onDragEnd: (() -> Void)?
    let onRotationChange: (() -> Void)?  // Callback for rotation changes to update bounds
    let onSelectInactive: (() -> Void)?  // Tap-to-select for inactive overlays (unsaved duplicates)

    @State private var ghostPosition: CGPoint? = nil
    @State private var initialWidthRatio: CGFloat? = nil
    @State private var initialRotation: CGFloat? = nil
    @State private var rotationCenter: CGPoint? = nil
    @State private var showColorPicker = false
    @State private var isMoveMode = false
    @State private var hasStartedGesture = false
    
    // ROOT FIX: Use @ViewBuilder to allow complex logic without manual 'return' statements
    @ViewBuilder
    var body: some View {
        if let page = pdfDocument.page(at: pageIndex), pdfView.scaleFactor > 0.1 {
            let pageBounds = page.bounds(for: .mediaBox)
            let currentScale = pdfView.scaleFactor
            let effectiveCenter = ghostPosition ?? placement.center
            let pdfPoint = CGPoint(
                x: effectiveCenter.x * pageBounds.width,
                y: effectiveCenter.y * pageBounds.height
            )
            let screenPoint = pdfView.convert(pdfPoint, from: page)

            // Safety guard for invalid coordinates
            if screenPoint.x.isFinite && screenPoint.y.isFinite && screenPoint != .zero {
                let safeRatio = max(0.01, placement.aspectRatio)
                let visualWidth = (pageBounds.width * placement.widthRatio) * currentScale
                let visualHeight = visualWidth / safeRatio

                contentStack(screenPoint: screenPoint, visualWidth: visualWidth, visualHeight: visualHeight, page: page, pageBounds: pageBounds)
            }
        }
    }

    @ViewBuilder
    private func contentStack(screenPoint: CGPoint, visualWidth: CGFloat, visualHeight: CGFloat, page: PDFPage, pageBounds: CGRect) -> some View {
                ZStack {
            // 1. Signature Image
            signatureImageLayer(visualWidth: visualWidth, visualHeight: visualHeight, screenPoint: screenPoint)
            
            // 2. Ghost Layer during drag
            if let ghostPos = ghostPosition {
                ghostImageLayer(ghostPos: ghostPos, pageBounds: pageBounds, visualWidth: visualWidth, visualHeight: visualHeight)
            }

            // 3. Interactive Handles and Toolbar
            if isActive {
                interactiveLayer(screenPoint: screenPoint, visualWidth: visualWidth, visualHeight: visualHeight, page: page, pageBounds: pageBounds)
            } else {
                // Inactive overlays were not selectable because the image layer disables hit-testing.
                // Provide an explicit hit target so taps can switch selection between unsaved duplicates.
                Color.clear
                    .frame(width: visualWidth + 24, height: visualHeight + 24)
                    .rotationEffect(.degrees(rotation))
                    .position(screenPoint)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectInactive?() }
            }
        }
    }

    // --- SUB-VIEWS TO PREVENT COMPILER TIMEOUT ---

    private func signatureImageLayer(visualWidth: CGFloat, visualHeight: CGFloat, screenPoint: CGPoint) -> some View {
        // CRITICAL: Avoid regenerating tinted UIImages during editing (causes CPU/memory spikes).
        // Use template tint for non-black.
        Group {
            if placement.color == .black {
                Image(uiImage: placement.signatureImage)
                    .resizable()
            } else {
                Image(uiImage: placement.signatureImage)
                    .renderingMode(.template)
                    .resizable()
                    .foregroundColor(Color(placement.color.uiColor))
            }
        }
        .frame(width: visualWidth, height: visualHeight)
        .rotationEffect(.degrees(placement.rotation))
        .position(screenPoint)
        .opacity(ghostPosition != nil ? 0.0 : 1.0)
        .allowsHitTesting(false)
    }

    private func ghostImageLayer(ghostPos: CGPoint, pageBounds: CGRect, visualWidth: CGFloat, visualHeight: CGFloat) -> some View {
        let ghostPdfPoint = CGPoint(x: ghostPos.x * pageBounds.width, y: ghostPos.y * pageBounds.height)
        guard let ghostPage = pdfDocument.page(at: pageIndex) ?? pdfDocument.page(at: 0) else {
            return AnyView(EmptyView())
        }
        let ghostScreenPoint = pdfView.convert(ghostPdfPoint, from: ghostPage)

        // CRITICAL: Avoid regenerating tinted UIImages during drag; template tint instead.
        return AnyView(
        Group {
            if placement.color == .black {
                Image(uiImage: placement.signatureImage)
                    .resizable()
            } else {
                Image(uiImage: placement.signatureImage)
                    .renderingMode(.template)
                    .resizable()
                    .foregroundColor(Color(placement.color.uiColor))
            }
        }
        .opacity(0.6)
        .frame(width: visualWidth, height: visualHeight)
        .rotationEffect(.degrees(placement.rotation))
        .position(ghostScreenPoint)
        )
    }

    @ViewBuilder
    private func interactiveLayer(screenPoint: CGPoint, visualWidth: CGFloat, visualHeight: CGFloat, page: PDFPage, pageBounds: CGRect) -> some View {
                        InlineSelectionBoxView(
            position: screenPoint,
            size: CGSize(width: visualWidth, height: visualHeight),
            rotation: placement.rotation,
            scaleFactor: pdfView.scaleFactor,
                            onMove: { _ in },
            onResize: { factor in
                let baseRatio = initialWidthRatio ?? placement.widthRatio
                if initialWidthRatio == nil { initialWidthRatio = baseRatio }
                placement.widthRatio = max(0.05, min(0.8, baseRatio * factor))
            },
            onResizeEnd: { initialWidthRatio = nil; pdfView.setNeedsDisplay() },
                            onRotate: { angle in
                                if initialRotation == nil {
                    initialRotation = placement.rotation
                    rotationCenter = placement.center
                    onGestureStart()
                }
                let newRotation = (initialRotation! + angle).truncatingRemainder(dividingBy: 360)
                let finalRotation = newRotation < 0 ? newRotation + 360 : newRotation
                // Update placement to trigger binding setter
                var updated = placement
                updated.rotation = finalRotation
                updated.center = rotationCenter ?? placement.center
                placement = updated
                // Force immediate update of annotation bounds when rotating (bypasses throttling)
                onRotationChange?()
                            },
                            onRotateEnd: {
                                initialRotation = nil
                rotationCenter = nil
                // Final commit to ensure rotation is saved
                onRotationChange?()
                pdfView.setNeedsDisplay()
            },
            onGestureStart: onGestureStart
        )
        .contentShape(Rectangle())  // ROOT FIX: Makes entire box area draggable, not just border
        .gesture(
            DragGesture(minimumDistance: 10)  // ROOT FIX: Require 10pt movement before drag starts (prevents tap from moving signature)
                .onChanged { value in
                    if !hasStartedGesture {
                        onGestureStart(); onDragStart?(); hasStartedGesture = true
                    }
                    let loc = pdfView.convert(value.location, to: page)
                    let halfW = placement.widthRatio / 2
                    let halfH = (placement.widthRatio / max(0.1, placement.aspectRatio)) / 2
                    self.ghostPosition = CGPoint(
                        x: max(halfW, min(1.0 - halfW, loc.x / pageBounds.width)),
                        y: max(halfH, min(1.0 - halfH, loc.y / pageBounds.height))
                    )
                }
                .onEnded { _ in
                    if let final = ghostPosition { placement.center = final }
                    ghostPosition = nil; hasStartedGesture = false; onDragEnd?(); pdfView.setNeedsDisplay()
                }
        )
        
        FloatingToolbarViewInline(
            position: CGPoint(x: screenPoint.x, y: screenPoint.y < 100 ? screenPoint.y + visualHeight/2 + 60 : screenPoint.y - visualHeight/2 - 60),
            offsetX: 0, offsetY: 0, displayWidth: pageBounds.width * pdfView.scaleFactor, displayHeight: pageBounds.height * pdfView.scaleFactor, pdfView: pdfView, page: page,
            onColor: { showColorPicker = true }, onDelete: onDelete, onDuplicate: onDuplicate,
            onMoveStart: { onGestureStart() },
            onMoveChanged: { newPos in self.ghostPosition = newPos; placement.center = newPos },
            onMoveEnded: { ghostPosition = nil; pdfView.setNeedsDisplay() },
            isMoveMode: $isMoveMode, currentPosition: ghostPosition ?? placement.center,
            currentWidthRatio: placement.widthRatio, currentAspectRatio: placement.aspectRatio
        )
        .confirmationDialog("Color", isPresented: $showColorPicker) {
                    ForEach(SignatureColor.allCases, id: \.self) { color in
                Button(color.rawValue) { placement.color = color; pdfView.setNeedsDisplay() }
            }
        }
    }

    // NOTE: Color is now applied at render-time (SwiftUI template tint + PDFAnnotation draw-time tint).
    // Keeping this removed helper out prevents accidental reintroduction of heavy image regeneration.
}

// MARK: - Inline Selection Box
struct InlineSelectionBoxView: View {
    let position: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let scaleFactor: CGFloat
    let onMove: (CGSize) -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void
    let onRotate: (CGFloat) -> Void
    let onRotateEnd: () -> Void
    let onGestureStart: () -> Void
    
    @State private var gesturePivot: CGPoint? = nil
    @State private var startRotation: CGFloat = 0
    @State private var startAngle: CGFloat? = nil
    @State private var resizeStartRotation: CGFloat? = nil
    @State private var resizeStartDX: CGFloat? = nil

    private var safeScale: CGFloat { max(0.1, scaleFactor) }
    private var handleSize: CGFloat { max(10, min(18, 12 / safeScale)) }
    // UI request: yellow outline + yellow handles (same thickness)
    private var selectionColor: Color { .yellow }
    
    var body: some View {
        ZStack {
            // 1. The Border - Clean, thin, blue
            Rectangle()
                // Thinner per request (still scaled by zoom)
                .stroke(selectionColor, lineWidth: 0.7 / safeScale)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotation))
                .position(position)
            
            // The corner handles (Separated to fix compiler crash)
            handlesLayer
            
            // The rotation handle
            rotationHandleIcon
        }
    }

    private var handlesLayer: some View {
            ForEach(0..<4) { index in
                Circle()
                .fill(selectionColor)
                .frame(width: handleSize, height: handleSize)
                    .position(rotatedCornerPosition(for: index))
                .gesture(cornerDragGesture)
        }
    }

    private var cornerDragGesture: some Gesture {
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if resizeStartRotation == nil {
                                            onGestureStart()
                                    resizeStartRotation = rotation
                                }
                                let radians = -(resizeStartRotation ?? 0) * .pi / 180
                let dx = value.location.x - position.x
                let dy = value.location.y - position.y
                                let localDX = dx * cos(radians) - dy * sin(radians)
                                if resizeStartDX == nil {
                    resizeStartDX = (value.startLocation.x - position.x) * cos(radians) - (value.startLocation.y - position.y) * sin(radians)
                                }
                                guard let startDX = resizeStartDX, abs(startDX) > 0.1 else { return }
                onResize(localDX / startDX)
                            }
                            .onEnded { _ in
                resizeStartRotation = nil; resizeStartDX = nil; onResizeEnd()
                            }
            }
            
    private var rotationHandleIcon: some View {
            Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: max(10, min(16, 12 / safeScale))))
                .foregroundColor(.white)
            .frame(width: handleSize + 4, height: handleSize + 4)
            .background(selectionColor.opacity(0.9))
                .clipShape(Circle())
                .position(rotatedRotationHandlePosition)
            .gesture(rotationGesture)
    }

    private var rotationGesture: some Gesture {
                    DragGesture()
                        .onChanged { value in
                            if gesturePivot == nil {
                                    onGestureStart()
                                gesturePivot = position
                    startAngle = atan2(value.startLocation.y - position.y, value.startLocation.x - position.x) * 180 / .pi
                }
                let currentAngle = atan2(value.location.y - position.y, value.location.x - position.x) * 180 / .pi
                var delta = currentAngle - (startAngle ?? 0)
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                onRotate(delta)
                        }
                        .onEnded { _ in
                gesturePivot = nil; startAngle = nil; onRotateEnd()
            }
    }

    // Helper functions
    private func rotatedCornerPosition(for index: Int) -> CGPoint {
        let halfW = size.width / 2; let halfH = size.height / 2
        let p: CGPoint
        switch index {
        case 0: p = CGPoint(x: position.x - halfW, y: position.y - halfH)
        case 1: p = CGPoint(x: position.x + halfW, y: position.y - halfH)
        case 2: p = CGPoint(x: position.x + halfW, y: position.y + halfH)
        default: p = CGPoint(x: position.x - halfW, y: position.y + halfH)
        }
        return rotate(p, around: position, by: rotation)
    }
    
    private var rotatedRotationHandlePosition: CGPoint {
        rotate(CGPoint(x: position.x, y: position.y - size.height / 2 - 20), around: position, by: rotation)
    }

    private func rotate(_ point: CGPoint, around center: CGPoint, by degrees: CGFloat) -> CGPoint {
        let rad = degrees * .pi / 180
        let tx = point.x - center.x; let ty = point.y - center.y
        return CGPoint(x: tx * cos(rad) - ty * sin(rad) + center.x, y: tx * sin(rad) + ty * cos(rad) + center.y)
    }
}

// MARK: - PDF View Representable (Fixed Braces)
struct PDFViewRepresentable: UIViewRepresentable {
    let pdfDocument: PDFDocument
    @Binding var pageIndex: Int
    @Binding var pdfViewInstance: PDFView?  // Binding to expose PDFView to parent
    @Binding var refreshTrigger: UUID  // Triggers SwiftUI recalculation during zoom
    var disableTapGestures: Bool = false
    // ROOT FIX: Background tap is now handled by tap router gesture on ZStack (removed parameter)
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        let coordinator = context.coordinator
        
        pdfView.document = pdfDocument
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.autoScales = true
        pdfView.backgroundColor = .systemBackground
        pdfView.isUserInteractionEnabled = true // Must be true for gestures to pass through
        pdfView.displaysAsBook = false
        pdfView.displaysPageBreaks = false
        
        // ROOT FIX: THE "STATIC FLOOR" - Disable native selection engine completely
        // Note: isSelectable is macOS-only, so we disable via gesture recognizers and delegate methods
        
        // ROOT FIX: Lock zoom - disable completely (min = max = fitScale locks it)
        // Will be set to fitScale in async block below
        
        pdfView.delegate = coordinator
        
        // Disable double-tap to zoom
        pdfView.gestureRecognizers?.forEach { recognizer in
            if let tapRecognizer = recognizer as? UITapGestureRecognizer,
               tapRecognizer.numberOfTapsRequired == 2 {
                recognizer.isEnabled = false
            }
            // ROOT FIX: Disable pinch gesture completely
            if recognizer is UIPinchGestureRecognizer {
                recognizer.isEnabled = false
            }
        }
        
        // ROOT FIX: HARD LOCKDOWN OF GESTURE RECOGNIZERS
        // Kill the Long Press (Magnifying glass / Copy Menu)
        pdfView.gestureRecognizers?.forEach { recognizer in
            // Kill the Long Press (Magnifying glass / Copy Menu)
            if recognizer is UILongPressGestureRecognizer {
                recognizer.isEnabled = false
            }
            
            // Kill the native Drag-to-Select (Text selection handles)
            if let pan = recognizer as? UIPanGestureRecognizer, pan.numberOfTouches == 1 {
                recognizer.isEnabled = false
            }
        }
        
        // Disable text selection by preventing menu controllers
        // This prevents the copy/paste menu from appearing
        if #available(iOS 13.0, *) {
            pdfView.isOpaque = false
        }
        
        coordinator.setupTapGestureHandling(pdfView: pdfView)
        
        // ROOT FIX: Background tap is now handled by tap router gesture on ZStack (removed recognizer here)
        
        // ROOT FIX: Hide the view until it fits perfectly
        pdfView.alpha = 0
        
        // REMOVED: No zoom observer needed since zoom is completely disabled
        coordinator.pdfViewInstance = pdfView
        
        // ROOT FIX: Lock to fit scale and never allow changes (zoom disabled)
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            if fitScale > 0 {
                pdfView.scaleFactor = fitScale
                // Lock it - same min and max prevents any zoom
            pdfView.minScaleFactor = fitScale
            pdfView.maxScaleFactor = fitScale
        }
        
            // ROOT FIX: Final lockdown after view is ready
            // Text selection is disabled via gesture recognizers and delegate methods (isSelectable is macOS-only)
            
            // Hide any existing menu controllers (copy/paste menu)
            UIMenuController.shared.hideMenu()
            UIMenuController.shared.isMenuVisible = false
            
            // Disable all long press gestures again (in case PDFKit adds more)
        pdfView.gestureRecognizers?.forEach { recognizer in
                if recognizer is UILongPressGestureRecognizer {
                recognizer.isEnabled = false
            }
        }
        
            self.pdfViewInstance = pdfView
            UIView.animate(withDuration: 0.2, delay: 0.1) {
                pdfView.alpha = 1
            }
        }
        
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        // Only update document if it changed
        if uiView.document != pdfDocument {
            uiView.document = pdfDocument
        }
        
        // ROOT FIX: Ensure PDFView shows the correct page when pageIndex changes
        // This prevents page duplication bug where content from one page appears on another
        if let targetPage = pdfDocument.page(at: pageIndex),
           uiView.currentPage != targetPage {
            // Only change page if it's actually different to avoid unnecessary updates
                uiView.go(to: targetPage)
            }
        
        // ROOT FIX: Re-lock zoom after page changes (prevent any drift)
        let fitScale = uiView.scaleFactorForSizeToFit
        if fitScale > 0 {
            uiView.scaleFactor = fitScale
            uiView.minScaleFactor = fitScale
            uiView.maxScaleFactor = fitScale
        }
        
        // ROOT FIX: Maintain "static floor" - selection disabled via gesture recognizers and delegate
        // (isSelectable is macOS-only, not available on iOS)
        
        // Direct assignment - updateUIView is already called on main thread
        self.pdfViewInstance = uiView
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
        // ROOT FIX: Background tap is now handled by tap router gesture on ZStack (removed property)
        
        init(pageIndex: Binding<Int>, refreshTrigger: Binding<UUID>) {
            _pageIndex = pageIndex
            _refreshTrigger = refreshTrigger
        }
        
        // CURSOR FIX: Cleanup observer to prevent memory leaks
        deinit {
            NotificationCenter.default.removeObserver(self)
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
        func updateTapGestureHandling(pdfView: PDFView, disable: Bool) {
            singleTapRecognizers.forEach { recognizer in
                recognizer.isEnabled = !disable
            }
            if singleTapRecognizers.isEmpty {
                setupTapGestureHandling(pdfView: pdfView)
            }
        }
        
        // ROOT FIX: Handle background tap for deselection
        // ROOT FIX: Background tap is now handled by tap router gesture on ZStack (removed method)
        
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
        
        // ROOT FIX: Prevent text selection by returning nil for selection
        @MainActor
        func pdfView(_ pdfView: PDFView, willSelect selection: PDFSelection, on page: PDFPage) -> PDFSelection? {
            // Return nil to prevent any text selection
            return nil
        }
        
        // ROOT FIX: Prevent menu actions (copy, etc.) from appearing
        @MainActor
        func pdfView(_ pdfView: PDFView, performAction action: Selector, for sender: Any?) -> Bool {
            // Block all menu actions (copy, select all, etc.)
            return false
        }
    }
            }
        
