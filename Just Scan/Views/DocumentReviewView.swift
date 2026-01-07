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
    @State private var showFilterOptions = false
    @State private var selectedFilter: FilterType = .blackAndWhite
    @State private var showColorPicker = false
    
    // Unified signature state
    @State private var signatures: [Int: [SignatureModel]] = [:]
    @State private var activeSignatureID: UUID? = nil {
        didSet {
            // #region agent log
            DebugLogger.shared.logStateChange(
                "activeSignatureID (DocumentReviewView)",
                oldValue: oldValue?.uuidString,
                newValue: activeSignatureID?.uuidString,
                hypothesisId: "A"
            )
            // #endregion
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
                .sheet(isPresented: $showSignatureCanvas) {
                    SignatureCanvasView(onSave: {
                        if signatureService.hasSignature {
                            let imageID = signatureService.currentSignatureID?.uuidString
                            editorProxy.addNewSignature(imageID: imageID)
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
                            let imageID = signatureService.currentSignatureID?.uuidString
                            editorProxy.addNewSignature(imageID: imageID)
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
                .confirmationDialog("Change Color", isPresented: $showColorPicker) {
                    ForEach(SignatureColor.allCases, id: \.self) { color in
                        Button(color.rawValue.capitalized) {
                            editorProxy.changeActiveSignatureColor(color)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $showOCROverlay) {
                    OCRResultView(text: ocrText)
                }
                .onAppear {
                    loadPDF()
                    // #region agent log
                    DebugLogger.shared.log(location: "DocumentReviewView.swift:\(#line)", message: "DocumentReviewView appeared", data: ["document": document.fileName], hypothesisId: "A")
                    // #endregion
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
                .alert("Multiple Signatures Detected", isPresented: $showSignatureWarning) {
                    Button("Cancel", role: .cancel) {}
                    Button("Save Anyway") {
                        editorProxy.commitAllToPDF()
                    }
                } message: {
                    Text("This document contains different signature images. Are you sure you want to proceed?")
                }
                .confirmationDialog("Unsaved Changes", isPresented: $showExitPrompt) {
                    Button("Save") {
                        editorProxy.commitAllToPDF()
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
                                // #region agent log
                                let _ = {
                                    DebugLogger.shared.log(
                                        location: "DocumentReviewView.swift:\(#line)",
                                        message: "Checking selection box conditions",
                                        data: [
                                            "activeSignatureID": activeSignatureID?.uuidString ?? "nil",
                                            "currentPageIndex": currentPageIndex,
                                            "hasSignatures": signatures[currentPageIndex] != nil,
                                            "signatureCount": signatures[currentPageIndex]?.count ?? 0
                                        ],
                                        hypothesisId: "B"
                                    )
                                }()
                                // #endregion
                                
                                if let activeID = activeSignatureID,
                                   let activeSignature = signatures[currentPageIndex]?.first(where: { $0.id == activeID }),
                                   let screenRect = editorProxy.getActiveSignatureScreenRect(),
                                   screenRect.width > 0 && screenRect.height > 0,
                                   screenRect.midX.isFinite && screenRect.midY.isFinite {
                                    
                                    let rectCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)
                                    let toolbarOffset: CGFloat = 80
                                    let rotationHandleOffset: CGFloat = 50
                                    
                                    FloatingToolbarView(
                                        position: CGPoint(x: rectCenter.x, y: screenRect.minY - toolbarOffset),
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
                                    
                                    SelectionBoxView(
                                        position: rectCenter,
                                        size: screenRect.size,
                                        rotation: activeSignature.rotation,
                                        rotationHandleOffset: rotationHandleOffset,
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
                                    // ✅ CRITICAL: Selection box border is non-interactive (set inside SelectionBoxView)
                                    // Corner handles and rotation handle are interactive (they have their own hit testing)
                                    // This allows pan gestures to pass through the border to PDFView while keeping handles functional
                                    // ✅ CRITICAL FIX: Disable implicit animation to prevent jittering during PDF redraws
                                    .transaction { transaction in
                                        transaction.animation = nil
                                    }
                                    .zIndex(1000)
                                    .id("selection-\(activeID.uuidString)-\(currentPageIndex)-\(selectionBoxRefreshID)")
                                    .onAppear {
                                        // #region agent log - REMOVED: Too verbose (renders every frame)
                                        // selectionBoxRenderCount += 1
                                        // #endregion
                                    }
                                } else {
                                    // #region agent log
                                    let _ = {
                                        var failureReasons: [String] = []
                                        if activeSignatureID == nil {
                                            failureReasons.append("activeSignatureID is nil")
                                        } else if signatures[currentPageIndex]?.first(where: { $0.id == activeSignatureID! }) == nil {
                                            failureReasons.append("signature not found in model")
                                        } else if let rect = editorProxy.getActiveSignatureScreenRect() {
                                            if rect.width <= 0 || rect.height <= 0 {
                                                failureReasons.append("rect has invalid size: \(rect)")
                                            }
                                        } else {
                                            failureReasons.append("getActiveSignatureScreenRect returned nil")
                                        }
                                        DebugLogger.shared.log(
                                            location: "DocumentReviewView.swift:\(#line)",
                                            message: "❌ Selection box conditions failed",
                                            data: ["failureReasons": failureReasons],
                                            hypothesisId: "B"
                                        )
                                    }()
                                    // #endregion
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
                    editorProxy.commitAllToPDF()
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
                    editorProxy.commitAllToPDF()
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
                        Button { secureAndShareFlattened() } label: {
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
    
    private func applyFilter(_ filterType: FilterType) {
            selectedFilter = filterType
        editorProxy.setVisualFilter(filterType)
    }
    
    private func secureAndShare() {
        editorProxy.commitAllToPDF()
        if hasMixedSignaturesInDocument() {
            pendingShareAction = { self.performSecureShare() }
            showDocumentSignatureWarning = true
        } else {
            performSecureShare()
        }
    }
    
    private func secureAndShareFlattened() {
        editorProxy.commitAllToPDF()
        if hasMixedSignaturesInDocument() {
            pendingShareAction = { self.performFlattenedShare() }
            showDocumentSignatureWarning = true
        } else {
            performFlattenedShare()
        }
    }
    
    private func performSecureShare() {
        guard let pdfDoc = pdfDocument else {
            print("❌ No PDF document to share")
            return
        }
        
        // ARCHITECTURE: Use SignatureExportService to create annotations with payload
        guard let exportData = SignatureExportService.shared.exportSecure(
            pdfDocument: pdfDoc,
            signatures: signatures
        ),
        let exportDoc = PDFDocument(data: exportData) else {
            print("❌ Failed to create secure export")
            return
        }
        
        print("✅ Created secure PDF with \(signatures.values.reduce(0) { $0 + $1.count }) signatures")
        sharePDF(exportDoc, mode: "secured")
    }
    
    private func performFlattenedShare() {
        guard let pdfDoc = pdfDocument else {
            print("❌ No PDF document to share")
            return
        }
        
        // ARCHITECTURE: Use SignatureExportService to render signatures into page pixels
        guard let exportData = SignatureExportService.shared.exportFlattened(
            pdfDocument: pdfDoc,
            signatures: signatures
        ),
        let exportDoc = PDFDocument(data: exportData) else {
            print("❌ Failed to create flattened export")
            return
        }
        
        // Optionally apply filter
        let finalDoc: PDFDocument
        if selectedFilter == .color {
            finalDoc = exportDoc
        } else {
            finalDoc = DocumentService.shared.applyFilter(to: exportDoc, filterType: selectedFilter)
        }
        
        print("✅ Created flattened PDF with \(signatures.values.reduce(0) { $0 + $1.count }) signatures")
        sharePDF(finalDoc, mode: "flattened")
    }
    
    private func sharePDF(_ pdfDocument: PDFDocument, mode: String) {
        // #region agent log
        DebugLogger.shared.logEntry("sharePDF", params: [
            "mode": mode,
            "pageCount": pdfDocument.pageCount,
            "fileName": document.fileName
        ], hypothesisId: "SHARE")
        // #endregion
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(document.fileName)_shared.pdf")
        guard pdfDocument.write(to: tempURL) else {
            // #region agent log
            DebugLogger.shared.logHypothesis("SHARE", message: "❌ Failed to write PDF to temp file", data: ["tempURL": tempURL.path])
            // #endregion
            return
        }
        
                                        // #region agent log
        DebugLogger.shared.log(
            location: "DocumentReviewView.swift:sharePDF",
            message: "PDF written to temp file",
                                            data: [
                "tempURL": tempURL.path,
                "fileExists": FileManager.default.fileExists(atPath: tempURL.path)
            ],
            hypothesisId: "SHARE"
                                        )
                                        // #endregion
        
        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            // #region agent log
            DebugLogger.shared.logHypothesis("SHARE", message: "✅ Presenting share sheet", data: ["mode": mode])
            // #endregion
            rootViewController.present(activityVC, animated: true)
        } else {
            // #region agent log
            DebugLogger.shared.logHypothesis("SHARE", message: "❌ Failed to get root view controller", data: [:])
            // #endregion
        }
    }
    
    private func hasMixedSignaturesInDocument() -> Bool {
        guard let pdfDoc = pdfDocument else { return false }
        var signatureHashes: Set<Int> = []
        for pageIndex in 0..<pdfDoc.pageCount {
            if let page = pdfDoc.page(at: pageIndex) {
                for annotation in page.annotations where isSignatureAnnotation(annotation) {
                    if let stamp = annotation as? ImageStampAnnotation, let image = stamp.imageSnapshot {
                        signatureHashes.insert(image.pngData()?.hashValue ?? 0)
                    }
                }
            }
        }
        return signatureHashes.count > 1
    }
}
