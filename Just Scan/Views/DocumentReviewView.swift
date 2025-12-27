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
    @State private var activeAnnotation: ImageStampAnnotation? = nil
    @State private var activeAnnotationPageIndex: Int? = nil
    
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
        
        // Commit pending edits on all pages before sharing (write and clear overlays)
        for pageIndex in 0..<(pdfDocument.pageCount) {
            saveSignatureToPage(pageIndex: pageIndex)
        }
        
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
    
    // Flattened export-only share (baked)
    private func secureAndShareFlattened() {
        guard let pdfDocument = pdfDocument else { return }
        
        // Commit pending edits on all pages before exporting
        for pageIndex in 0..<(pdfDocument.pageCount) {
            saveSignatureToPage(pageIndex: pageIndex)
        }
        
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

    struct PDFPageTransform {
        let pageRect: CGRect
        let viewSize: CGSize
        let scale: CGFloat
        let displaySize: CGSize
        let offset: CGPoint
        
        init(page: PDFPage, viewSize: CGSize) {
            self.pageRect = page.bounds(for: .mediaBox)
            self.viewSize = viewSize
            let sx = viewSize.width / pageRect.width
            let sy = viewSize.height / pageRect.height
            self.scale = min(sx, sy)
            self.displaySize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            self.offset = CGPoint(
                x: (viewSize.width - displaySize.width) / 2,
                y: (viewSize.height - displaySize.height) / 2
            )
        }
        
        func viewPoint(from normalized: CGPoint) -> CGPoint {
            CGPoint(
                x: offset.x + normalized.x * pageRect.width * scale,
                y: offset.y + (1 - normalized.y) * pageRect.height * scale
            )
        }
        
        func viewSize(widthRatio: CGFloat, aspectRatio: CGFloat) -> CGSize {
            let w = pageRect.width * widthRatio * scale
            return CGSize(width: w, height: w / aspectRatio)
        }
    }

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
                    if placing {
                        appendNewPlacementIfNeeded()
                    }
                }
                .onDisappear {
        if let pdfDocument = pdfDocument {
            for pageIndex in 0..<pdfDocument.pageCount {
                saveSignatureToPage(pageIndex: pageIndex)
            }
        }
                    signaturePlacements = [:]
                    activePlacementID = [:]
                    activeAnnotation = nil
                    activeAnnotationPageIndex = nil
                    isPlacingSignature = false
                    hasPendingChanges = false
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
                            // Let PDF scroll in view mode; block when actively placing
                            pdfView(pdfDocument)
                                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                                .allowsHitTesting(!isPlacingSignature)
                            
                            // Tap layer for saved PDF annotations (always available)
                            SavedSignatureOverlay(
                                        pdfDocument: pdfDocument,
                                pageIndex: currentPageIndex,
                                selectedSignature: .constant(nil),
                                currentlyEditingAnnotation: activeAnnotation,
                                onDelete: { _ in },
                                onEdit: { annotation in
                                    // commit current edits in memory before switching
                                    commitActiveEditInMemory()
                                    beginEditing(annotation: annotation, pageIndex: currentPageIndex)
                                }
                            )
                                        .allowsHitTesting(true)
                            
                            // Unified signature overlay (active + background)
                            signatureOverlay(pdfDocument: pdfDocument)
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
            disableTapGestures: !isPlacingSignature
        )
        .ignoresSafeArea()
        .id(pdfRefreshID)
    }
                            
    @ViewBuilder
    private func signatureOverlay(pdfDocument: PDFDocument) -> some View {
        let placements = signaturePlacements[currentPageIndex] ?? []
        let activeID = activePlacementID[currentPageIndex] ?? nil
        
        ZStack {
            ForEach(placements, id: \.id) { placement in
                let isActive = placement.id == activeID
                let index = placements.firstIndex(where: { $0.id == placement.id }) ?? 0
                let z = Double((placements.count - 1) - index) // older on top
                
                if isActive {
                    InlineSignatureOverlay(
                        pageIndex: currentPageIndex,
                        pdfDocument: pdfDocument,
                        signatureImage: placement.signatureImage,
                        placement: signatureBinding(pageIndex: currentPageIndex, placementID: placement.id),
                        isActive: true,
                        onSave: { saveSignatureToPage(pageIndex: currentPageIndex) },
                        onDelete: { deletePlacement(id: placement.id); hasPendingChanges = true },
                        onDuplicate: { p in appendNewPlacement(using: p.signatureImage); hasPendingChanges = true },
                        onGestureStart: { registerUndoSnapshot(for: currentPageIndex); hasPendingChanges = true }
                    )
                    .zIndex(z + 1) // keep active slightly above its base order
                } else {
                    UnsavedSignatureOverlay(
                        pageIndex: currentPageIndex,
                        pdfDocument: pdfDocument,
                        signatureImage: placement.signatureImage,
                        placement: placement,
                        showImage: false // hide overlay image for saved/editing signatures
                    )
                    .zIndex(z)
                    .onTapGesture {
                        activePlacementID[currentPageIndex] = placement.id
                        isPlacingSignature = true
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!placements.isEmpty)
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
                        .disabled((undoStack[currentPageIndex]?.isEmpty ?? true))
                        
                        Button(action: { redoAction(for: currentPageIndex) }) {
                            Image(systemName: "arrow.uturn.forward.circle")
                        }
                        .disabled((redoStack[currentPageIndex]?.isEmpty ?? true))
                    }
                    
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button(action: { appendNewPlacement() }) {
                            Image(systemName: "plus.circle")
                        }
                        Button("Save") {
                            saveSignatureToPage(pageIndex: currentPageIndex)
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
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
                if let idx = list.firstIndex(where: { $0.id == placementID }) {
                    list[idx] = newValue
                    signaturePlacements[pageIndex] = list
                    redoStack[pageIndex] = []
                    
                    // If editing an existing annotation in place, update it
                    if let pdfDocument = pdfDocument,
                       let page = pdfDocument.page(at: pageIndex),
                       let stamp = activeAnnotation,
                       activeAnnotationPageIndex == pageIndex,
                       placementID == activePlacementID[pageIndex] {
                        applyPlacement(newValue, to: stamp, on: page)
                    }
                }
            }
        )
    }
    
    private func shouldWarnAboutDifferentSignatures(placements: [SignaturePlacement], page: PDFPage, pageIndex: Int) -> Bool {
        var signatureHashes: Set<String> = []
        
        for annotation in page.annotations where annotation.userName == "Signature" {
            if let stamp = annotation as? ImageStampAnnotation,
               let data = stamp.imageSnapshot?.pngData() {
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
        
        // Fallback: parse contents JSON for base64 image
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
              let _ = pdfDocument.page(at: pageIndex),
              let stamp = annotation as? ImageStampAnnotation else { return }
        
        activeAnnotation = stamp
        activeAnnotationPageIndex = pageIndex
        isPlacingSignature = true
        hasPendingChanges = false
        redoStack[pageIndex] = []
        
        signaturePlacements[pageIndex] = []
        activePlacementID[pageIndex] = nil
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
    
    private func saveSignatureToPage(pageIndex: Int) {
        guard let pdfDocument = pdfDocument, let page = pdfDocument.page(at: pageIndex) else { return }
        
        // Detect mixed signature images across existing + unsaved
        var allPlacements: [SignaturePlacement] = []
        for annotation in page.annotations where annotation.userName == "Signature" {
            if let active = activeAnnotation, annotation === active { continue }
            if let p = placement(from: annotation, on: page) {
                allPlacements.append(p)
            }
        }
        let unsaved = signaturePlacements[pageIndex] ?? []
        allPlacements.append(contentsOf: unsaved)
        
        if shouldWarnAboutDifferentSignatures(placements: allPlacements, page: page, pageIndex: pageIndex) {
            return
        }
        
        // Add only the new overlays; existing annotations remain in place
        for placement in unsaved {
            if let annotation = makeAnnotation(from: placement, on: page) {
                page.addAnnotation(annotation)
            }
        }
        
        if let data = pdfDocument.dataRepresentation() {
            try? data.write(to: document.fileURL, options: .atomic)
            NotificationCenter.default.post(name: .init("RefreshDocumentThumbnails"), object: nil)
        }
        
        signaturePlacements[pageIndex] = []
        activePlacementID[pageIndex] = nil
        activeAnnotation = nil
        activeAnnotationPageIndex = nil
        isPlacingSignature = false
        hasPendingChanges = false
        pdfRefreshID = UUID()
    }
    
    private func performSave(placements: [SignaturePlacement], pageIndex: Int, page: PDFPage) {
        guard let pdfDocument = pdfDocument else { return }
        
        // Deprecated: no longer used for incremental saves
    }
    
    // Bulk save removed for simplicity; saving happens per page as needed
    
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
        let pdfCenterX = placement.center.x * pageRect.width
        let pdfX = pdfCenterX - (pdfWidth / 2)
        let pdfCenterY = placement.center.y * pageRect.height
        let pdfY = pdfCenterY - (pdfHeight / 2)
        
        let clampedX = max(0, min(pdfX, pageRect.width - pdfWidth))
        let clampedY = max(0, min(pdfY, pageRect.height - pdfHeight))
        let signatureBounds = CGRect(x: clampedX, y: clampedY, width: pdfWidth, height: pdfHeight)
        
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
    
    private func applyPlacement(_ placement: SignaturePlacement, to annotation: ImageStampAnnotation, on page: PDFPage) {
        let pageRect = page.bounds(for: .mediaBox)
        let pdfWidth = pageRect.width * placement.widthRatio
        let pdfHeight = pdfWidth / placement.aspectRatio
        let pdfCenterX = placement.center.x * pageRect.width
        let pdfX = pdfCenterX - (pdfWidth / 2)
        let pdfCenterY = placement.center.y * pageRect.height
        let pdfY = pdfCenterY - (pdfHeight / 2)
        let clampedX = max(0, min(pdfX, pageRect.width - pdfWidth))
        let clampedY = max(0, min(pdfY, pageRect.height - pdfHeight))
        let signatureBounds = CGRect(x: clampedX, y: clampedY, width: pdfWidth, height: pdfHeight)
        
        let finalImage = placement.color == .black ? placement.signatureImage : applyColorToSignature(placement.signatureImage, color: placement.color)
        
        annotation.bounds = signatureBounds
        annotation.originalRotation = placement.rotation
        annotation.originalColor = placement.color
        annotation.originalAspectRatio = placement.aspectRatio
        annotation.updateImage(finalImage)
    }
    
    private func commitActiveEditInMemory() {
        guard
            let pageIndex = activeAnnotationPageIndex,
            let placementID = activePlacementID[pageIndex] ?? signaturePlacements[pageIndex]?.first?.id,
            let placement = signaturePlacements[pageIndex]?.first(where: { $0.id == placementID }),
            let pdfDocument = pdfDocument,
            let page = pdfDocument.page(at: pageIndex),
            let stamp = activeAnnotation
        else {
            activeAnnotation = nil
            activeAnnotationPageIndex = nil
            return
        }
        
        applyPlacement(placement, to: stamp, on: page)
        signaturePlacements[pageIndex] = []
        activePlacementID[pageIndex] = nil
        activeAnnotation = nil
        activeAnnotationPageIndex = nil
        hasPendingChanges = true
    }
    
    private func appendNewPlacementIfNeeded() {
        let placements = signaturePlacements[currentPageIndex] ?? []
        if placements.isEmpty {
            appendNewPlacement()
        }
    }
    
    private func appendNewPlacement(using image: UIImage? = nil) {
        let signatureImage = image ?? signatureService.signatureImage
        guard let signatureImage else { return }
        let aspectRatio = signatureImage.size.height > 0 ? signatureImage.size.width / signatureImage.size.height : 2.0
        let current = signaturePlacements[currentPageIndex] ?? []
        registerUndoSnapshot(for: currentPageIndex)
        
        var placements = current
        // Stagger new placement to avoid overlap
        let offsetStep: CGFloat = 0.06
        let idx = placements.count
        let x = min(max(0.2, 0.5 + CGFloat(idx) * offsetStep), 0.8)
        let y = min(max(0.2, 0.5 + CGFloat(idx) * offsetStep), 0.8)
        
        placements.append(SignaturePlacement(
            center: .init(x: x, y: y),
            widthRatio: 0.3,
            rotation: 0,
            color: .black,
            aspectRatio: aspectRatio,
            signatureImage: signatureImage
        ))
        signaturePlacements[currentPageIndex] = placements
        activePlacementID[currentPageIndex] = placements.last?.id
        redoStack[currentPageIndex] = []
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
    
    private func applySnapshot(for pageIndex: Int, placements: [SignaturePlacement]) {
        signaturePlacements[pageIndex] = placements
        activePlacementID[pageIndex] = placements.isEmpty ? nil : placements.last?.id
        isPlacingSignature = !placements.isEmpty
    }
    
    private func undoAction(for pageIndex: Int) {
        guard var stack = undoStack[pageIndex], let previous = stack.popLast() else { return }
        let current = signaturePlacements[pageIndex] ?? []
        undoStack[pageIndex] = stack
        redoStack[pageIndex, default: []].append(current)
        applySnapshot(for: pageIndex, placements: previous)
    }
    
    private func redoAction(for pageIndex: Int) {
        guard var stack = redoStack[pageIndex], let next = stack.popLast() else { return }
        let current = signaturePlacements[pageIndex] ?? []
        redoStack[pageIndex] = stack
        undoStack[pageIndex, default: []].append(current)
        applySnapshot(for: pageIndex, placements: next)
    }
    
    private func applyColorToSignature(_ image: UIImage, color: SignatureColor) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorMonochrome") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIColor(color: color.uiColor), forKey: kCIInputColorKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        guard let outputImage = filter.outputImage,
              let cgImageOutput = Self.ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        return UIImage(cgImage: cgImageOutput)
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
        GeometryReader { geometry in
            if let page = pdfDocument.page(at: pageIndex) {
                let transform = DocumentReviewView.PDFPageTransform(page: page, viewSize: geometry.size)
                
                let effectiveCenter = tempPosition ?? placement.center
                let effectiveWidthRatio = tempWidthRatio ?? placement.widthRatio
                let effectiveRotation = tempRotation ?? placement.rotation
                
                let elementSize = transform.viewSize(widthRatio: effectiveWidthRatio, aspectRatio: placement.aspectRatio)
                let xPos = transform.offset.x + effectiveCenter.x * transform.displaySize.width
                let yPos = transform.offset.y + (1 - effectiveCenter.y) * transform.displaySize.height
                
                let coloredSignature: UIImage = {
                    if placement.color == .black { return placement.signatureImage }
                    else { return applyColor(placement.signatureImage, color: placement.color) }
                }()
                
                // --- FIX 2: REMOVED THE FULL SCREEN Color.clear HERE ---
                // This allows taps to pass through to signatures underneath
                
                // Overlay content
                ZStack {
                    Image(uiImage: coloredSignature)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: elementSize.width, height: elementSize.height)
                        .contentShape(Rectangle())
                        .rotationEffect(.degrees(effectiveRotation))
                        .position(x: xPos, y: yPos)
                        .onTapGesture {
                            // #region agent log
                            DocumentReviewView.debugLog(
                                hypothesisId: "H5",
                                message: "tap on active signature image",
                                data: [
                                    "pageIndex": pageIndex,
                                    "isMoveMode": isMoveMode,
                                    "isSelected": isSelected
                                ]
                            )
                            // #endregion
                            // If user taps the active signature, select it
                            if !isMoveMode { isSelected = true }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if tempPosition == nil { onGestureStart() }
                                    let touchX = value.location.x
                                    let touchY = value.location.y
                                    guard touchX >= transform.offset.x && touchX <= transform.offset.x + transform.displaySize.width &&
                                          touchY >= transform.offset.y && touchY <= transform.offset.y + transform.displaySize.height else { return }
                                    
                                    let normalizedX = (touchX - transform.offset.x) / transform.displaySize.width
                                    let normalizedY = 1 - (touchY - transform.offset.y) / transform.displaySize.height
                                    let normalizedWidth = effectiveWidthRatio
                                    let normalizedHeight = normalizedWidth / placement.aspectRatio
                                    
                                    let minX = normalizedWidth / 2
                                    let maxX = 1.0 - normalizedWidth / 2
                                    let minY = normalizedHeight / 2
                                    let maxY = 1.0 - normalizedHeight / 2
                                    
                                    tempPosition = CGPoint(
                                        x: max(minX, min(maxX, normalizedX)),
                                        y: max(minY, min(maxY, normalizedY))
                                    )
                                }
                                .onEnded { _ in
                                    if let finalPos = tempPosition {
                                        placement.center = finalPos
                                    }
                                    tempPosition = nil
                                }
                        )
                    
                    if isSelected && isActive {
                        InlineSelectionBoxView(
                            position: CGPoint(x: xPos, y: yPos),
                            size: CGSize(width: elementSize.width, height: elementSize.height),
                            rotation: effectiveRotation,
                            onMove: { _ in },
                            onResize: { scaleFactor in
                                if initialWidthRatio == nil {
                                    initialWidthRatio = placement.widthRatio
                                }
                                let base = initialWidthRatio ?? placement.widthRatio
                                // FIX 1: Multiply base * scaleFactor (absolute math)
                                tempWidthRatio = max(0.05, min(0.8, base * scaleFactor))
                            },
                            onResizeEnd: {
                                if let final = tempWidthRatio {
                                    placement.widthRatio = final
                                }
                                tempWidthRatio = nil
                                initialWidthRatio = nil
                            },
                            onRotate: { angle in
                                // Use effective rotation at gesture start as base
                                if initialRotation == nil {
                                    initialRotation = effectiveRotation
                                    // #region agent log
                                    DocumentReviewView.debugLog(
                                        hypothesisId: "H7",
                                        message: "rotation start captured initial",
                                        data: [
                                            "pageIndex": pageIndex,
                                            "effectiveRotation": effectiveRotation,
                                            "placementRotation": placement.rotation,
                                            "tempRotation": tempRotation ?? -999,
                                            "capturedInitial": initialRotation ?? -999
                                        ]
                                    )
                                    // #endregion
                                }
                                let baseRotation = initialRotation ?? effectiveRotation
                                var newRotation = baseRotation + angle
                                newRotation = newRotation.truncatingRemainder(dividingBy: 360)
                                if newRotation < 0 { newRotation += 360 }
                                tempRotation = newRotation
                                // #region agent log
                                DocumentReviewView.debugLog(
                                    hypothesisId: "H6",
                                    message: "rotate drag",
                                    data: [
                                        "pageIndex": pageIndex,
                                        "baseRotation": baseRotation,
                                        "angleDelta": angle,
                                        "normalizedRotation": newRotation
                                    ]
                                )
                                // #endregion
                            },
                            onRotateEnd: {
                                if let final = tempRotation {
                                    placement.rotation = final
                                    // #region agent log
                                    DocumentReviewView.debugLog(
                                        hypothesisId: "H6",
                                        message: "rotate end",
                                        data: [
                                            "pageIndex": pageIndex,
                                            "finalRotation": final
                                        ]
                                    )
                                    // #endregion
                                }
                                tempRotation = nil
                                initialRotation = nil
                            },
                            onGestureStart: {
                                if tempRotation == nil && tempWidthRatio == nil {
                                    onGestureStart()
                                }
                            }
                        )
                        .id("inline-box-\(pageIndex)-\(placement.center.x)-\(placement.center.y)-\(placement.widthRatio)")
                        
                        FloatingToolbarViewInline(
                            position: CGPoint(x: xPos, y: yPos - elementSize.height/2 - 60),
                                offsetX: transform.offset.x,
                                offsetY: transform.offset.y,
                                displayWidth: transform.displaySize.width,
                                displayHeight: transform.displaySize.height,
                            onColor: { showColorPicker = true },
                            onDelete: onDelete,
                            onDuplicate: {
                                var duplicate = placement
                                duplicate.center = CGPoint(
                                    x: min(0.95, placement.center.x + 0.15),
                                    y: min(0.95, placement.center.y + 0.15)
                                )
                                onDuplicate(duplicate)
                            },
                            onMoveStart: { },
                            onMoveChanged: { newPos in
                                tempPosition = newPos
                            },
                            onMoveEnded: {
                                if let finalPos = tempPosition {
                                    placement.center = finalPos
                                }
                                tempPosition = nil
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
                        Button(color.rawValue) { placement.color = color }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .allowsHitTesting(isActive)
    }
    
    private func applyColor(_ image: UIImage, color: SignatureColor) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorMonochrome") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIColor(color: color.uiColor), forKey: kCIInputColorKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        guard let outputImage = filter.outputImage,
              let cgImageOutput = DocumentReviewView.ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        return UIImage(cgImage: cgImageOutput)
    }
}

// MARK: - Floating Toolbar
struct FloatingToolbarViewInline: View {
    let position: CGPoint
    let offsetX: CGFloat
    let offsetY: CGFloat
    let displayWidth: CGFloat
    let displayHeight: CGFloat
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
                            if !isMoveMode {
                            isMoveMode = true
                                onMoveStart()
                            }
                            let toolbarCenterX = position.x
                            let toolbarCenterY = position.y
                            let touchX = toolbarCenterX + (value.location.x - 18)
                            let touchY = toolbarCenterY + (value.location.y - 18)
                            guard touchX >= offsetX && touchX <= offsetX + displayWidth && touchY >= offsetY && touchY <= offsetY + displayHeight else { return }
                            let normalizedX = (touchX - offsetX) / displayWidth
                            let normalizedY = 1 - (touchY - offsetY) / displayHeight
                            let normalizedWidth = currentWidthRatio
                            let normalizedHeight = normalizedWidth / currentAspectRatio
                            let minX = normalizedWidth / 2
                            let maxX = 1.0 - normalizedWidth / 2
                            let minY = normalizedHeight / 2
                            let maxY = 1.0 - normalizedHeight / 2
                            let newPos = CGPoint(
                                x: max(minX, min(maxX, normalizedX)),
                                y: max(minY, min(maxY, normalizedY))
                            )
                            onMoveChanged(newPos)
                        }
                        .onEnded { _ in
                            isMoveMode = false
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
    @Binding var selectedSignature: (pageIndex: Int, annotation: PDFAnnotation)?
    let currentlyEditingAnnotation: PDFAnnotation?
    let onDelete: (PDFAnnotation) -> Void
    let onEdit: (PDFAnnotation) -> Void
    
    var body: some View {
        GeometryReader { geometry in
                if let page = pdfDocument.page(at: pageIndex) {
                let transform = DocumentReviewView.PDFPageTransform(page: page, viewSize: geometry.size)
                let signatureAnnotations = page.annotations.filter {
                    $0.userName == "Signature" && $0 !== currentlyEditingAnnotation
                }
                let annotatedItems = signatureAnnotations.map { (ObjectIdentifier($0), $0) }
                
                ForEach(annotatedItems, id: \.0) { _, annotation in
                        let bounds = annotation.bounds
                    let normalizedCenter = CGPoint(
                        x: bounds.midX / transform.pageRect.width,
                        y: bounds.midY / transform.pageRect.height
                    )
                    let center = transform.viewPoint(from: normalizedCenter)
                    let visualWidth = bounds.width * transform.scale
                    let visualHeight = bounds.height * transform.scale
                    
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
        .allowsHitTesting(true)
    }
}

// MARK: - Inline Selection Box
struct InlineSelectionBoxView: View {
    let position: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let onMove: (CGSize) -> Void
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void
    let onRotate: (CGFloat) -> Void
    let onRotateEnd: () -> Void
    let onGestureStart: () -> Void
    
    // Rotation/resize tracking
    @State private var gesturePivot: CGPoint? = nil
    @State private var startRotation: CGFloat = 0
    @State private var startAngle: CGFloat? = nil
    @State private var resizeStartRotation: CGFloat? = nil
    @State private var resizeStartDX: CGFloat? = nil
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotation))
                .position(position)
            
            ForEach(0..<4) { index in
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
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
                .font(.system(size: 16))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
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
    var disableTapGestures: Bool = false
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .systemBackground
        pdfView.isUserInteractionEnabled = true
        pdfView.displaysAsBook = false
        pdfView.displaysPageBreaks = false
        
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            pdfView.minScaleFactor = fitScale
            pdfView.maxScaleFactor = fitScale
        }
        
        let coordinator = context.coordinator
        pdfView.delegate = coordinator
        
        if let page = pdfDocument.page(at: pageIndex) {
            pdfView.go(to: page)
        }
        
        // Disable double-tap to zoom to prevent shape changes
        pdfView.gestureRecognizers?.forEach { recognizer in
            if let tapRecognizer = recognizer as? UITapGestureRecognizer,
               tapRecognizer.numberOfTapsRequired == 2 {
                recognizer.isEnabled = false
            }
        }
        
        context.coordinator.setupTapGestureHandling(pdfView: pdfView)
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document != pdfDocument {
            uiView.document = pdfDocument
        }
        
        // Ensure visible page matches state
        if let currentPage = uiView.currentPage, let doc = uiView.document {
            let actualIndex = doc.index(for: currentPage)
            if actualIndex != pageIndex, let targetPage = doc.page(at: pageIndex) {
                uiView.go(to: targetPage)
            }
        }
        
        context.coordinator.updateTapGestureHandling(pdfView: uiView, disable: disableTapGestures)
        uiView.isUserInteractionEnabled = true
        uiView.displayMode = .singlePage
        uiView.displayDirection = .horizontal
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(pageIndex: $pageIndex)
    }
    
    class Coordinator: NSObject, PDFViewDelegate {
        @Binding var pageIndex: Int
        private var singleTapRecognizers: [UITapGestureRecognizer] = []
        
        init(pageIndex: Binding<Int>) {
            _pageIndex = pageIndex
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
        
