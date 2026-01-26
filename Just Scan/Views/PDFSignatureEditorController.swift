//
//  PDFSignatureEditorController.swift
//  Just Scan
//
//  Created as part of signature architecture refactor
//  Phase 3: UIKit PDF editor controller - owns all PDF interaction
//

import UIKit
import PDFKit
import Combine
import CoreImage

/// UIKit view controller that owns all PDF interaction for signatures.
/// This eliminates gesture conflicts by having a single gesture owner.
/// All coordinate conversions go through PDFCoordinateConverter.
///
/// Responsibilities:
/// - Own PDFView and all gesture recognizers
/// - Manage signature models (single source of truth)
/// - Handle coordinate conversion via PDFCoordinateConverter
/// - Update PDF annotations directly (no SwiftUI overlays)
/// - Emit state changes via Combine for SwiftUI integration
@MainActor
class PDFSignatureEditorController: UIViewController {
    
    // MARK: - Properties
    
    private let pdfView = PDFView()
    var pdfDocument: PDFDocument? {
        return pdfView.document
    }
    
    /// Single source of truth: all signatures (saved and unsaved) indexed by page
    private var signatures: [Int: [SignatureModel]] = [:] {
        didSet {
            signaturesSubject.send(signatures)
        }
    }
    
    /// Currently active signature being edited
    private var activeSignatureID: UUID?
    
    /// Cache for screen rect to prevent excessive recalculations during drag
    private var cachedScreenRect: CGRect?
    private var cachedScreenRectSignatureID: UUID?
    private var cachedScreenRectTimestamp: TimeInterval = 0
    private let screenRectCacheTimeout: TimeInterval = 0.016 // ~60fps
    
    /// Track if we're in the middle of a gesture (to prevent cache invalidation)
    private var isInGesture: Bool = false
    
    /// Debug counters for instrumentation
    private var getActiveSignatureScreenRectCallCount: Int = 0
    
    /// Current page index
    var currentPageIndex: Int = 0 {
        didSet {
            currentPageIndexSubject.send(currentPageIndex)
            updateUndoRedoState()
        }
    }
    
    /// Combine publishers for SwiftUI integration
    let signaturesSubject = PassthroughSubject<[Int: [SignatureModel]], Never>()
    let currentPageIndexSubject = PassthroughSubject<Int, Never>()
    let activeSignatureIDSubject = PassthroughSubject<UUID?, Never>()
    let hasPendingChangesSubject = PassthroughSubject<Bool, Never>()
    let canUndoSubject = PassthroughSubject<Bool, Never>()
    let canRedoSubject = PassthroughSubject<Bool, Never>()
    
    /// Undo/redo stacks (limited to last 20 actions per page)
    private var undoStack: [Int: [[SignatureModel]]] = [:] {
        didSet {
            updateUndoRedoState()
        }
    }
    private var redoStack: [Int: [[SignatureModel]]] = [:] {
        didSet {
            updateUndoRedoState()
        }
    }
    private let maxUndoHistory = 20
    
    private func updateUndoRedoState() {
        let canUndo = !(undoStack[currentPageIndex]?.isEmpty ?? true)
        let canRedo = !(redoStack[currentPageIndex]?.isEmpty ?? true)
        canUndoSubject.send(canUndo)
        canRedoSubject.send(canRedo)
    }
    
    /// Gesture recognizers
    private var panGesture: UIPanGestureRecognizer?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var rotationGesture: UIRotationGestureRecognizer?
    private var tapGesture: UITapGestureRecognizer?
    
    /// Gesture state
    private var gestureStartSignatureID: UUID?
    private var gestureStartRect: CGRect?
    private var gestureStartCenter: CGPoint?
    private var gestureStartRotation: CGFloat?
    private var gestureStartScale: CGFloat = 1.0
    
    /// Gesture tracking flags for undo/redo
    private var isMovingSignature = false
    private var isResizingSignature = false
    private var isRotatingSignature = false
    
    /// SignatureService reference
    private let signatureService = SignatureService.shared
    
    /// DocumentSignatureStore reference for JSON persistence
    private let signatureStore = DocumentSignatureStore.shared
    
    /// Current document being edited (needed for signature storage)
    var currentDocument: Document?
    
    /// Overlay layer for uncommitted signatures
    private var overlayLayer: CALayer?
    
    // MARK: - Initialization
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupPDFView()
        setupGestures()
        updateUndoRedoState()
    }
    
    // MARK: - Setup
    
    private func setupPDFView() {
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.autoScales = true
        pdfView.backgroundColor = .systemGray6
        
        // ✅ LOCK PDF: Prevent zoom by setting min/max to same value AFTER autoScales sets initial scale
        // Don't set scaleFactor here - let autoScales fit the page first
        
        // ✅ LOCK PDF: Disable all zoom/pinch gestures from PDFView
        for gesture in pdfView.gestureRecognizers ?? [] {
            // Disable pinch gestures (zoom)
            if gesture is UIPinchGestureRecognizer {
                gesture.isEnabled = false
            }
            // Disable double-tap zoom
            if gesture is UITapGestureRecognizer {
                let tap = gesture as! UITapGestureRecognizer
                if tap.numberOfTapsRequired == 2 {
                    tap.isEnabled = false
                }
            }
        }
        
        // Add overlay layer for uncommitted signatures
        let overlay = CALayer()
        overlay.frame = pdfView.bounds
        pdfView.layer.addSublayer(overlay)
        overlayLayer = overlay
        
        // Overlay frame will be updated in viewDidLayoutSubviews
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayLayer?.frame = pdfView.bounds
        renderSignatureOverlays()
    }
    
    private func setupGestures() {
        // Pan gesture for moving signatures
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pdfView.addGestureRecognizer(pan)
        panGesture = pan
        
        // Pinch gesture for resizing
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        pdfView.addGestureRecognizer(pinch)
        pinchGesture = pinch
        
        // Rotation gesture
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotation.delegate = self
        pdfView.addGestureRecognizer(rotation)
        rotationGesture = rotation
        
        // ✅ NEW: Dedicated tap gesture for annotation selection (highest priority)
        let annotationTap = UITapGestureRecognizer(target: self, action: #selector(handleAnnotationTap(_:)))
        annotationTap.numberOfTapsRequired = 1
        annotationTap.delegate = self
        pdfView.addGestureRecognizer(annotationTap)
        tapGesture = annotationTap
        
        // ✅ CRITICAL FIX: Tap should not block drag - makes drag start instantly
        // Drag must begin immediately; tap is secondary
        annotationTap.require(toFail: pan)
    }
    
    // MARK: - Public Interface
    
    /// Load a PDF document
    /// - Parameter pdfDoc: The PDFDocument to display
    /// - Parameter document: The Document model (for signature storage)
    func loadDocument(_ pdfDoc: PDFDocument, document: Document? = nil) {
        // Store document reference for signature persistence
        currentDocument = document
        
        // pdfDocument is a computed property (get-only), so we just set pdfView.document
        pdfView.document = pdfDoc
        
        // ✅ Ensure PDF fits the page properly
        if let page = pdfDoc.page(at: currentPageIndex) {
            pdfView.go(to: page)
            // Force autoScales to recalculate after setting document
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Lock scale after autoScales has set it
                let currentScale = self.pdfView.scaleFactor
                self.pdfView.minScaleFactor = currentScale
                self.pdfView.maxScaleFactor = currentScale
            }
        }
        
        // ARCHITECTURE: Load signatures from JSON store (NOT from PDF annotations)
        // PDF annotations are ONLY used for export, never for runtime editing
        if let doc = document {
            print("📂 Loading signatures for document ID: \(doc.id)")
            signatures = signatureStore.loadSignatures(for: doc)
            signaturesSubject.send(signatures)
            let count = signatures.values.reduce(0) { $0 + $1.count }
            print("✅ Loaded \(count) signatures from JSON store")
        } else {
            // No document provided - start with empty signatures
            signatures = [:]
            signaturesSubject.send(signatures)
            print("⚠️ No document provided - starting with empty signatures")
        }
        
        renderSignatureOverlays()
    }
    
    /// Get current state for SwiftUI synchronization
    var currentState: (signatures: [Int: [SignatureModel]], activeSignatureID: UUID?, currentPageIndex: Int, hasPendingChanges: Bool) {
        // hasPendingChanges is tracked via subject, default to false for initial sync
        return (signatures, activeSignatureID, currentPageIndex, false)
    }
    
    /// Set current page index
    func setPageIndex(_ index: Int) {
        guard let document = pdfDocument,
              index >= 0 && index < document.pageCount else { return }
        
        // ✅ Allow switching signatures without committing - no need to commit before selection change
        // commitActiveEdit() - REMOVED: Don't force commit when just changing selection
        
        // Clear active signature when changing pages (per-page selection)
        
        activeSignatureID = nil
        activeSignatureIDSubject.send(nil)
        
        currentPageIndex = index
        if let page = document.page(at: index) {
            // ✅ FIX: Temporarily unlock scale to allow autoScales to recalculate for new page
            // This ensures each page is properly fitted, not zoomed in from previous page
            
            // Unlock scale temporarily to allow autoScales to work
            pdfView.minScaleFactor = 0.1
            pdfView.maxScaleFactor = 10.0
            
            // Navigate to new page
            pdfView.go(to: page)
            
            // ✅ Force autoScales to recalculate for the new page
            // Disable and re-enable autoScales to force recalculation
            pdfView.autoScales = false
            pdfView.autoScales = true
            
            // Lock the scale again after autoScales has recalculated
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Lock scale at the new page's fitted size
                let newScale = self.pdfView.scaleFactor
                self.pdfView.minScaleFactor = newScale
                self.pdfView.maxScaleFactor = newScale
            }
        }
        
        // ✅ CRITICAL FIX: Clear and re-render overlays for the new page
        // This ensures signatures from the previous page don't show on the new page
        renderSignatureOverlays()
    }
    
    /// Add a new signature at the center of the current page
    func addNewSignature(imageID: String? = nil) {
        guard let document = pdfDocument,
              document.page(at: currentPageIndex) != nil else { return }
        
        // Get signature image from SignatureService
        let signatureImage: UIImage?
        let finalImageID: String
        
        if let imageID = imageID,
           let uuid = UUID(uuidString: imageID),
           let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
            signatureImage = savedSignature.image
            finalImageID = imageID
        } else if let currentID = signatureService.currentSignatureID {
            signatureImage = signatureService.signatureImage
            finalImageID = currentID.uuidString
        } else if let lastSignature = signatureService.signatureHistory.last {
            signatureImage = lastSignature.image
            finalImageID = lastSignature.id.uuidString
        } else {
            return
        }
        
        guard let image = signatureImage else { return }
        
        let aspectRatio = image.size.height > 0 ? image.size.width / image.size.height : 2.0
        
        let newSignature = SignatureModel(
            center: CGPoint(x: 0.5, y: 0.5), // Center of page (normalized)
            widthRatio: 0.21, // 21% of page width (70% of previous 30%)
            rotation: 0,
            color: .black,
            imageID: finalImageID,
            aspectRatio: aspectRatio
        )
        
        registerUndoSnapshot(for: currentPageIndex)
        signatures[currentPageIndex, default: []].append(newSignature)
        activeSignatureID = newSignature.id
        activeSignatureIDSubject.send(activeSignatureID)
        hasPendingChangesSubject.send(true)
        
        renderSignatureOverlays() // Show the new signature
    }
    
    /// Duplicate the active signature
    func duplicateActiveSignature() {
        guard let activeID = activeSignatureID,
              let activeSignature = getSignature(id: activeID, pageIndex: currentPageIndex) else { return }
        
        // Offset the duplicate slightly (to the right and up in normalized space)
        let offsetX: CGFloat = 0.05 // 5% to the right
        let offsetY: CGFloat = 0.05 // 5% up (remember Y increases upward in PDF)
        
        let duplicate = SignatureModel(
            center: CGPoint(
                x: min(0.95, activeSignature.center.x + offsetX),
                y: min(0.95, activeSignature.center.y + offsetY)
            ),
            widthRatio: activeSignature.widthRatio,
            rotation: activeSignature.rotation,
            color: activeSignature.color,
            imageID: activeSignature.imageID,
            aspectRatio: activeSignature.aspectRatio
        )
        
        registerUndoSnapshot(for: currentPageIndex)
        signatures[currentPageIndex, default: []].append(duplicate)
        activeSignatureID = duplicate.id
        activeSignatureIDSubject.send(activeSignatureID)
        hasPendingChangesSubject.send(true)
        
        renderSignatureOverlays()
    }
    
    /// Set active signature (called from SwiftUI via proxy)
    func setActiveSignature(_ id: UUID?) {
        // ✅ CRITICAL: Only update if actually changing (prevents unnecessary clears)
        guard activeSignatureID != id else {
            
            return
        }
        
        activeSignatureID = id
        
        activeSignatureIDSubject.send(id)
        renderSignatureOverlays()
        
        // Force a small delay to ensure state is synced before SwiftUI queries
        DispatchQueue.main.async { [weak self] in
            self?.renderSignatureOverlays()
        }
    }
    
    /// Delete the active signature
    func deleteActiveSignature() {
        guard let activeID = activeSignatureID else { return }
        
        registerUndoSnapshot(for: currentPageIndex)
        
        // ARCHITECTURE: No annotation handling - just remove from model
        // PDF annotations are only created during export, not during editing
        
        // Remove from signatures array
        if var pageSignatures = signatures[currentPageIndex] {
            pageSignatures.removeAll { $0.id == activeID }
            signatures[currentPageIndex] = pageSignatures
        }
        
        // ✅ Clear active selection (this removes selection box)
        
        activeSignatureID = nil
        activeSignatureIDSubject.send(nil)
        hasPendingChangesSubject.send(true)
        
        // ✅ Refresh overlays (removes any uncommitted signature layers)
        renderSignatureOverlays()
    }
    
    /// Update a signature's imageID (used when editing a signature)
    func updateSignatureImageID(signatureID: UUID, newImageID: String) {
        guard var pageSignatures = signatures[currentPageIndex],
              let index = pageSignatures.firstIndex(where: { $0.id == signatureID }) else {
            return
        }
        
        let oldSignature = pageSignatures[index]
        
        // ✅ Create new signature with updated imageID (imageID is let, so we need a new instance)
        // Get the new signature's aspect ratio from SignatureService
        let newAspectRatio: CGFloat
        if let uuid = UUID(uuidString: newImageID),
           let newSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
            newAspectRatio = newSignature.image.size.width / newSignature.image.size.height
        } else {
            newAspectRatio = oldSignature.aspectRatio // Fallback to old aspect ratio
        }
        
        let updatedSignature = SignatureModel(
            id: oldSignature.id, // Keep same ID
            center: oldSignature.center,
            widthRatio: oldSignature.widthRatio,
            rotation: oldSignature.rotation,
            color: oldSignature.color,
            imageID: newImageID, // ✅ New imageID
            aspectRatio: newAspectRatio
        )
        
        registerUndoSnapshot(for: currentPageIndex)
        pageSignatures[index] = updatedSignature
        signatures[currentPageIndex] = pageSignatures
        signaturesSubject.send(signatures)
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()
    }
    
    /// Change color of active signature
    func changeActiveSignatureColor(_ color: SignatureColor) {
        
        
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else {
            
            return
        }
        
        // ARCHITECTURE: In the new SwiftUI overlay system, we just update the model
        // No PDF annotations are touched during editing
        signature.color = color
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex] {
            if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                pageSignatures[index] = signature
                signatures[currentPageIndex] = pageSignatures
            }
        }
        
        // Re-render overlays with new color
        renderSignatureOverlays()
        
        hasPendingChangesSubject.send(true)
    }
    
    /// DEPRECATED: In the new architecture, signatures are NOT committed to PDF during editing.
    /// Use SignatureExportService.exportFlattened() or exportSecure() instead.
    /// This method is kept for backward compatibility but does nothing.
    @available(*, deprecated, message: "Use SignatureExportService for export instead")
    // DEPRECATED: commitAllToPDF() removed - use SignatureExportService for export
    
    /// Save signatures to JSON store (does NOT modify the PDF file)
    /// The PDF file is only modified during export (flatten or secure)
    func saveToDisk(url: URL) -> Bool {
        guard let doc = currentDocument else {
            print("❌ No document reference - cannot save signatures")
            print("   Current signatures count: \(signatures.values.reduce(0) { $0 + $1.count })")
            print("   URL: \(url)")
            return false
        }
        
        print("💾 === SAVING SIGNATURES TO JSON ===")
        print("   Document ID: \(doc.id)")
        print("   Signatures to save: \(signatures.values.reduce(0) { $0 + $1.count })")
        
        // ARCHITECTURE: Save signatures to JSON store, NOT to PDF annotations
        // PDF file is unchanged - only modified during export
        let saved = signatureStore.saveSignatures(signatures, for: doc)
        
        if saved {
            print("✅ Signatures saved to JSON store")
            hasPendingChangesSubject.send(false)
            
            // Refresh overlays to ensure consistency
            renderSignatureOverlays()
            
            // Post notification to refresh document thumbnails in HomeView
            NotificationCenter.default.post(name: NSNotification.Name("RefreshDocumentThumbnails"), object: nil)
            
            print("💾 === SAVE COMPLETE ===")
        } else {
            print("❌ Failed to save signatures")
        }
        
        return saved
    }
    
    /// Undo last action
    func undo() {
        guard var stack = undoStack[currentPageIndex],
              !stack.isEmpty else { return }
        
        let snapshot = stack.removeLast()
        undoStack[currentPageIndex] = stack
        
        let current = signatures[currentPageIndex] ?? []
        redoStack[currentPageIndex, default: []].append(current)
        
        signatures[currentPageIndex] = snapshot
        hasPendingChangesSubject.send(true)
        
        // ARCHITECTURE: No annotation handling - just re-render overlays
        renderSignatureOverlays()
        
        // Auto-select last modified signature after undo (if it exists)
        if let lastSignature = snapshot.last,
           getSignature(id: lastSignature.id, pageIndex: currentPageIndex) != nil {
            activeSignatureID = lastSignature.id
            activeSignatureIDSubject.send(activeSignatureID)
        } else {
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
        }
        
        // ✅ Clear cache to force recalculation
        clearScreenRectCache()
        renderSignatureOverlays()
        pdfView.setNeedsDisplay()
    }
    
    /// Redo last undone action
    func redo() {
        guard var stack = redoStack[currentPageIndex],
              !stack.isEmpty else { return }
        
        let snapshot = stack.removeLast()
        redoStack[currentPageIndex] = stack
        
        let current = signatures[currentPageIndex] ?? []
        undoStack[currentPageIndex, default: []].append(current)
        
        signatures[currentPageIndex] = snapshot
        hasPendingChangesSubject.send(true)
        
        // ARCHITECTURE: No annotation handling - just re-render overlays
        renderSignatureOverlays()
        
        // Auto-select last modified signature after redo (if it exists)
        if let lastSignature = snapshot.last,
           getSignature(id: lastSignature.id, pageIndex: currentPageIndex) != nil {
            activeSignatureID = lastSignature.id
            activeSignatureIDSubject.send(activeSignatureID)
        } else {
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
        }
        
        // ✅ Clear cache to force recalculation
        clearScreenRectCache()
        renderSignatureOverlays()
        pdfView.setNeedsDisplay()
    }
    
    // MARK: - Private Helpers
    
    private func getSignature(id: UUID, pageIndex: Int) -> SignatureModel? {
        return signatures[pageIndex]?.first { $0.id == id }
    }
    
    /// Clear annotation ID cache (placeholder - no cache currently used)
    private func clearAnnotationIDCache() {
        // No-op for now - can be extended if caching is added
    }
    
    private func commitActiveEdit() {
        // ✅ REMOVED: No longer forcing commit on selection change
        // Signatures can be switched freely without committing
        // Commit only happens on explicit save or when leaving the page
        // This allows switching between signatures without saving
    }
    
    private func registerUndoSnapshot(for pageIndex: Int) {
        let current = signatures[pageIndex] ?? []
        var stack = undoStack[pageIndex] ?? []
        
        // Limit history size
        if stack.count >= maxUndoHistory {
            stack.removeFirst()
        }
        
        stack.append(current)
        undoStack[pageIndex] = stack
        redoStack[pageIndex] = []
    }
    
    // MARK: - Gesture Handlers
    
    // MARK: - NEW: Smart Annotation Tap Handler (Three-Phase Detection)
    
    @objc private func handleAnnotationTap(_ gesture: UITapGestureRecognizer) {
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex) else {
            
            return
        }
        
        let location = gesture.location(in: pdfView)
        let pdfPoint = PDFCoordinateConverter.viewToPDF(location, page: page, pdfView: pdfView)
        
        
        // ✅ PHASE 1: Try to select from loaded model (fast path)
        let pageSignatures = signatures[currentPageIndex] ?? []
        
        for signature in pageSignatures.reversed() {
            // ARCHITECTURE: Always use model rect for hit testing (no annotation lookup)
            let hitRect = signature.pdfRect(for: page)
            
            // Circular hit test (handles rotation better)
            // ✅ Make hit test more forgiving to prevent missing signatures when switching
            let center = CGPoint(x: hitRect.midX, y: hitRect.midY)
            let radius = hypot(hitRect.width, hitRect.height) / 2.0 // More forgiving (was 2.2)
            let distance = hypot(pdfPoint.x - center.x, pdfPoint.y - center.y)
            
            
            
            if distance <= radius {
                // ✅ Allow switching between signatures without committing - this is safe
                // The previous signature's state is preserved in the signatures array
                activeSignatureID = signature.id
                
                clearScreenRectCache()  // ✅ Clear cache when selection changes
                activeSignatureIDSubject.send(activeSignatureID)
                renderSignatureOverlays()
                
                // Force state sync before SwiftUI queries
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.renderSignatureOverlays()
                }
                return
            }
        }
        
        // ✅ PHASE 2: Model miss - scan annotations directly (handles stale model)
        
        
        for annotation in page.annotations.reversed() {
            guard let name = annotation.value(forAnnotationKey: .name) as? String,
                  name == SignatureAnnotationKeys.annotationName else { continue }
            
            // Hit test against annotation bounds
            let bounds = annotation.bounds
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = hypot(bounds.width, bounds.height) / 2.2
            let distance = hypot(pdfPoint.x - center.x, pdfPoint.y - center.y)
            
            if distance <= radius {
                
                
                // DEPRECATED: fromAnnotation removed - annotations are only for export
                // In the new architecture, signatures are loaded from JSON, not PDF annotations
                // If user taps on a PDF annotation (from another app), we ignore it
                // Only signatures created in this app (stored in JSON) are editable
                
                return
            }
        }
        
        // ✅ PHASE 3: No hit - deselect
        // BUT: Check if tap is near any signature (within 2x radius) - if so, don't deselect
        // This prevents deselection when tapping near a signature (user might be trying to switch)
        var isNearAnySignature = false
        for signature in pageSignatures {
            // ARCHITECTURE: Always use model rect (no annotation lookup)
            let hitRect = signature.pdfRect(for: page)
            let center = CGPoint(x: hitRect.midX, y: hitRect.midY)
            let radius = hypot(hitRect.width, hitRect.height) / 2.0
            let distance = hypot(pdfPoint.x - center.x, pdfPoint.y - center.y)
            // ✅ Use 2x radius for "near" check (more forgiving)
            if distance <= radius * 2.0 {
                isNearAnySignature = true
                break
            }
        }
        
        
        // ✅ CRITICAL FIX: Only deselect if we truly didn't hit anything AND not near any signature
        // Don't deselect if we're near a signature (user might be trying to switch)
        let wasActive = activeSignatureID != nil
        if wasActive && !isNearAnySignature {
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
            renderSignatureOverlays()
        }
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // ✅ CRITICAL: Add defensive checks to prevent crashes
        guard let activeID = activeSignatureID else {
            
            return
        }
        guard var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else {
            
            return
        }
        guard let page = pdfDocument?.page(at: currentPageIndex) else {
            
            return
        }
        
        let location = gesture.location(in: pdfView)
        let pdfPoint = PDFCoordinateConverter.viewToPDF(location, page: page, pdfView: pdfView)
        let pageBounds = page.bounds(for: .mediaBox)
        
        switch gesture.state {
        case .began:
            
            isInGesture = true  // ✅ Mark that we're in a gesture to use cache
            gestureStartSignatureID = activeID
            gestureStartCenter = signature.center
            gestureStartRect = signature.pdfRect(for: page)
            registerUndoSnapshot(for: currentPageIndex)
            // Cache the initial rect to prevent jittering
            if let initialRect = getActiveSignatureScreenRect() {
                cachedScreenRect = initialRect
                cachedScreenRectSignatureID = activeID
            }
            
        case .changed:
            
            guard let startCenter = gestureStartCenter else {
                
                return
            }
            
            // Calculate delta from start center (prevents drift)
            let startPDFCenter = CGPoint(
                x: startCenter.x * pageBounds.width,
                y: startCenter.y * pageBounds.height
            )
            
            let dx = (pdfPoint.x - startPDFCenter.x) / pageBounds.width
            let dy = (pdfPoint.y - startPDFCenter.y) / pageBounds.height
            
            // Update normalized center from start position
            signature.center = CGPoint(
                x: startCenter.x + dx,
                y: startCenter.y + dy
            )
            
            // Clamp to valid range
            signature.center.x = max(0.05, min(0.95, signature.center.x))
            signature.center.y = max(0.05, min(0.95, signature.center.y))
            
            // Update in array
            if var pageSignatures = signatures[currentPageIndex] {
                if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                    pageSignatures[index] = signature
                    signatures[currentPageIndex] = pageSignatures
                    
                    // Clear cache when signature position changes
                    clearScreenRectCache()
                }
            }
            
            // ARCHITECTURE: No annotation handling during gestures - just update model
            // SwiftUI overlay will re-render based on model changes
            
        case .ended, .cancelled:
            // ARCHITECTURE: No annotation handling - just finalize gesture state
            gestureStartSignatureID = nil
            gestureStartCenter = nil
            gestureStartRect = nil
            isInGesture = false
            clearScreenRectCache()
            hasPendingChangesSubject.send(true)
            renderSignatureOverlays()
            
        default:
            break
        }
    }
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else {
            
            return
        }
        
        switch gesture.state {
        case .began:
            
            isInGesture = true  // ✅ Mark that we're in a gesture to use cache
            gestureStartScale = gesture.scale
            gestureStartRect = signature.pdfRect(for: page)
            registerUndoSnapshot(for: currentPageIndex)
            // Cache the initial rect to prevent jittering
            if let initialRect = getActiveSignatureScreenRect() {
                cachedScreenRect = initialRect
                cachedScreenRectSignatureID = activeID
            }
            
        case .changed:
            guard gestureStartRect != nil else { return }
            
            let scale = gesture.scale / gestureStartScale
            
            
            
            // Update width ratio (normalized)
            let newWidthRatio = signature.widthRatio * scale
            signature.widthRatio = max(0.05, min(0.5, newWidthRatio)) // Clamp between 5% and 50%
            
            // Update in array
            if var pageSignatures = signatures[currentPageIndex] {
                if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                    pageSignatures[index] = signature
                    signatures[currentPageIndex] = pageSignatures
                    
                    // Clear cache when signature size changes
                    clearScreenRectCache()
                    
                    // ARCHITECTURE: No annotation handling during gestures
                    // SwiftUI overlay will re-render based on model changes
                }
            }
            
            // ✅ CRITICAL: Don't call renderSignatureOverlays() on every pinch change - too expensive and causes jittering
            // renderSignatureOverlays() - REMOVED: Only needed for uncommitted signatures
            
        case .ended, .cancelled:
            // ARCHITECTURE: No annotation handling - just finalize gesture state
            gestureStartScale = 1.0
            gestureStartRect = nil
            isInGesture = false
            clearScreenRectCache()
            hasPendingChangesSubject.send(true)
            renderSignatureOverlays()
            
        default:
            break
        }
    }
    
    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        switch gesture.state {
        case .began:
            
            isInGesture = true  // ✅ Mark that we're in a gesture to use cache
            gestureStartRotation = signature.rotation
            registerUndoSnapshot(for: currentPageIndex)
            // Cache the initial rect to prevent jittering
            if let initialRect = getActiveSignatureScreenRect() {
                cachedScreenRect = initialRect
                cachedScreenRectSignatureID = activeID
            }
            
        case .changed:
            guard let startRotation = gestureStartRotation else { return }
            
            let rotationDelta = gesture.rotation * 180 / .pi // Convert to degrees
            let newRotation = (startRotation + rotationDelta).truncatingRemainder(dividingBy: 360)
            
            signature.rotation = newRotation
            
            // Update in array
            if var pageSignatures = signatures[currentPageIndex] {
                if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                    pageSignatures[index] = signature
                    signatures[currentPageIndex] = pageSignatures
                    
                    // ✅ SYNC FIX: Update both CALayer and SwiftUI in the same run loop cycle
                    // First, publish to SwiftUI (triggers async update)
                    signaturesSubject.send(signatures)
                    
                    // Then update CALayer synchronously in the same frame
                    // Use CATransaction to ensure immediate visual update
                    CATransaction.begin()
                    CATransaction.setDisableActions(true) // Disable implicit animations for instant update
                    updateActiveSignatureLayerTransform(signature: signature, page: page)
                    CATransaction.commit()
                }
            }
            
            // Recalculate screen rect from model for cache
            let modelRect = signature.pdfRect(for: page)
            let modelScreenRect = PDFCoordinateConverter.pdfRectToView(modelRect, page: page, pdfView: pdfView)
            cachedScreenRect = modelScreenRect
            cachedScreenRectSignatureID = activeID
            
        case .ended, .cancelled:
            // ARCHITECTURE: No annotation handling - just finalize gesture state
            gestureStartRotation = nil
            isInGesture = false
            clearScreenRectCache()
            hasPendingChangesSubject.send(true)
            renderSignatureOverlays()
            
        default:
            break
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PDFSignatureEditorController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pinch and rotation to work simultaneously
        if (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIRotationGestureRecognizer) ||
           (gestureRecognizer is UIRotationGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer) {
            return true
        }
        return false
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // ✅ NEW: Tap gesture always works (for selection)
        if gestureRecognizer is UITapGestureRecognizer {
            return true
        }
        
        // ✅ CRITICAL FIX: Pan gesture should work when signature is active
        // But also allow it to start even if activeSignatureID is temporarily nil
        // (This prevents blocking when switching between signatures)
        if gestureRecognizer is UIPanGestureRecognizer {
            // Allow pan if signature is active OR if we're in the middle of a pan gesture
            // (gestureStartSignatureID tracks ongoing pan)
            if activeSignatureID != nil || gestureStartSignatureID != nil {
                return true
            }
            // ✅ Also check if touch is near an active signature (improves gesture recognition)
            if let page = pdfDocument?.page(at: currentPageIndex) {
                let touchPoint = touch.location(in: pdfView)
                let pdfPoint = PDFCoordinateConverter.viewToPDF(touchPoint, page: page, pdfView: pdfView)
                let pageSignatures = signatures[currentPageIndex] ?? []
                for signature in pageSignatures {
                    // ARCHITECTURE: Always use model rect (no annotation lookup)
                    let hitRect = signature.pdfRect(for: page)
                    let center = CGPoint(x: hitRect.midX, y: hitRect.midY)
                    let radius = hypot(hitRect.width, hitRect.height) / 2.0 * 1.5 // 1.5x radius for easier recognition
                    let distance = hypot(pdfPoint.x - center.x, pdfPoint.y - center.y)
                    if distance <= radius {
                        return true  // Touch is near a signature - allow pan
                    }
                }
            }
            return false  // No signature nearby - let PDFView handle scroll
        }
        
        // ✅ Other gestures only work when signature is active
        if gestureRecognizer is UIPinchGestureRecognizer ||
           gestureRecognizer is UIRotationGestureRecognizer {
            return activeSignatureID != nil
        }
        
        return true
    }
    
    // MARK: - UI Helper Methods
    
    /// Get the screen position of the active signature's center
    /// Returns nil if no active signature or page not found
    func getActiveSignatureScreenPosition() -> CGPoint? {
        guard let activeID = activeSignatureID,
              let signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else {
            return nil
        }
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        let pdfCenter = CGPoint(x: pdfRect.midX, y: pdfRect.midY)
        
        // Convert to screen coordinates
        let screenCenter = PDFCoordinateConverter.pdfToView(pdfCenter, page: page, pdfView: pdfView)
        
        // Guard against invalid coordinates
        guard screenCenter.x.isFinite && screenCenter.y.isFinite,
              screenCenter.x >= 0 && screenCenter.y >= 0 else {
            return nil
        }
        
        return screenCenter
    }
    
    /// Get the screen rect of the active signature
    /// Returns nil if no active signature or page not found
    /// Uses caching to prevent excessive recalculations during SwiftUI render cycles
    func getActiveSignatureScreenRect() -> CGRect? {
        guard let activeID = activeSignatureID else {
            cachedScreenRect = nil
            cachedScreenRectSignatureID = nil
            return nil
        }
        
        guard let signature = getSignature(id: activeID, pageIndex: currentPageIndex) else {
            cachedScreenRect = nil
            cachedScreenRectSignatureID = nil
            return nil
        }
        
        guard let page = pdfDocument?.page(at: currentPageIndex) else {
            cachedScreenRect = nil
            cachedScreenRectSignatureID = nil
            return nil
        }
        
        // ✅ CRITICAL FIX: During gestures, return cached rect (set by moveActiveSignature/resize/rotate)
        // The cache is always calculated from model, ensuring consistency
        if isInGesture,
           let cached = cachedScreenRect,
           cachedScreenRectSignatureID == activeID {
            return cached
        }
        
        // ✅ Calculate from model (authoritative source)
        // Selection box should match model position, not padded annotation bounds
        let pdfRect = signature.pdfRect(for: page)
        let screenRect = PDFCoordinateConverter.pdfRectToView(pdfRect, page: page, pdfView: pdfView)
        
        // Guard against invalid rect
        guard screenRect.width.isFinite && screenRect.height.isFinite,
              screenRect.width > 0 && screenRect.height > 0 else {
            cachedScreenRect = nil
            cachedScreenRectSignatureID = nil
            return nil
        }
        
        // ✅ Cache result for subsequent SwiftUI render calls (prevents excessive recalculation)
        cachedScreenRect = screenRect
        cachedScreenRectSignatureID = activeID
        cachedScreenRectTimestamp = Date().timeIntervalSince1970
        
        return screenRect
    }
    
    /// Clear screen rect cache (call when signature position changes)
    private func clearScreenRectCache() {
        cachedScreenRect = nil
        cachedScreenRectSignatureID = nil
    }
    
    /// DEBUG: Log rect probe to track what's changing during gestures
    /// Get screen position for any signature
    func getSignatureScreenPosition(signatureID: UUID, pageIndex: Int) -> CGPoint? {
        guard let signature = getSignature(id: signatureID, pageIndex: pageIndex),
              let page = pdfDocument?.page(at: pageIndex) else {
            return nil
        }
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        let pdfCenter = CGPoint(x: pdfRect.midX, y: pdfRect.midY)
        let screenCenter = PDFCoordinateConverter.pdfToView(pdfCenter, page: page, pdfView: pdfView)
        
        // Guard against invalid coordinates
        guard screenCenter.x.isFinite && screenCenter.y.isFinite else {
            return nil
        }
        
        return screenCenter
    }
    
    /// Get screen rect for any signature
    func getSignatureScreenRect(signatureID: UUID, pageIndex: Int) -> CGRect? {
        guard let signature = getSignature(id: signatureID, pageIndex: pageIndex),
              let page = pdfDocument?.page(at: pageIndex) else {
            return nil
        }
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        
        // Convert to screen coordinates
        let screenRect = PDFCoordinateConverter.pdfRectToView(pdfRect, page: page, pdfView: pdfView)
        
        // Guard against invalid rect
        guard screenRect.width.isFinite && screenRect.height.isFinite,
              screenRect.width > 0 && screenRect.height > 0 else {
            return nil
        }
        
        return screenRect
    }
    
    /// Move active signature by screen delta (converted to normalized coordinates)
    func moveActiveSignature(by screenDelta: CGSize) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        // Register undo snapshot on first move
        if !isMovingSignature {
            isInGesture = true  // ✅ Mark that we're in a gesture to use cache
            registerUndoSnapshot(for: currentPageIndex)
            isMovingSignature = true
        }
        
        // Convert screen delta to normalized delta using scaleFactor + flipY
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = pdfView.scaleFactor
        
        let normalizedDX = screenDelta.width / (pageBounds.width * scale)
        let normalizedDY = -screenDelta.height / (pageBounds.height * scale) // flip Y
        
        // Update normalized center
        signature.center.x = max(0.05, min(0.95, signature.center.x + normalizedDX))
        signature.center.y = max(0.05, min(0.95, signature.center.y + normalizedDY))
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex],
           let idx = pageSignatures.firstIndex(where: { $0.id == activeID }) {
            pageSignatures[idx] = signature
            signatures[currentPageIndex] = pageSignatures
            
            // ✅ CRITICAL FIX: Recalculate screen rect from model AFTER update (prevents delta drift)
            // Recalculate screen rect from model
            let modelRect = signature.pdfRect(for: page)
            let modelScreenRect = PDFCoordinateConverter.pdfRectToView(modelRect, page: page, pdfView: pdfView)
            cachedScreenRect = modelScreenRect
            cachedScreenRectSignatureID = activeID
            
            // ✅ PERFORMANCE: Don't render overlays during move - SwiftUI updates automatically via Combine
            // renderSignatureOverlays() - REMOVED: Causes jitter, SwiftUI handles updates
        }
        
        hasPendingChangesSubject.send(true)
    }
    
    func endMoveSignature() {
        isMovingSignature = false
        isInGesture = false
        clearScreenRectCache()
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()
    }
    
    func endRotateSignature() {
        isRotatingSignature = false
        isInGesture = false
        clearScreenRectCache()
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()
    }
    
    /// Resize active signature by scale factor
    func resizeActiveSignature(by scaleFactor: CGFloat) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        // Register undo snapshot on first resize
        if !isResizingSignature {
            isInGesture = true  // ✅ Mark that we're in a gesture to use cache
            registerUndoSnapshot(for: currentPageIndex)
            isResizingSignature = true
        }
        
        // Update width ratio (normalized)
        let newWidthRatio = signature.widthRatio * scaleFactor
        signature.widthRatio = max(0.05, min(0.5, newWidthRatio)) // Clamp between 5% and 50%
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex] {
            if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                pageSignatures[index] = signature
                signatures[currentPageIndex] = pageSignatures
                
                // Recalculate screen rect from model
                let modelRect = signature.pdfRect(for: page)
                let modelScreenRect = PDFCoordinateConverter.pdfRectToView(modelRect, page: page, pdfView: pdfView)
                cachedScreenRect = modelScreenRect
                cachedScreenRectSignatureID = activeID
                
                // ✅ PERFORMANCE: Don't render overlays during resize - SwiftUI updates automatically via Combine
                // renderSignatureOverlays() - REMOVED: Causes lag, SwiftUI handles updates
            }
        }
        
        hasPendingChangesSubject.send(true)
    }
    
    func endResizeSignature() {
        isResizingSignature = false
        isInGesture = false
        clearScreenRectCache()
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()
    }
    
    /// Rotate active signature by angle (degrees)
    func rotateActiveSignature(by angle: CGFloat) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        // Register undo snapshot on first rotate
        if !isRotatingSignature {
            isInGesture = true  // ✅ Mark that we're in a gesture
            registerUndoSnapshot(for: currentPageIndex)
            isRotatingSignature = true
        }
        
        signature.rotation = (signature.rotation + angle).truncatingRemainder(dividingBy: 360)
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex] {
            if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                pageSignatures[index] = signature
                signatures[currentPageIndex] = pageSignatures
                
                // Recalculate screen rect from model
                let modelRect = signature.pdfRect(for: page)
                let modelScreenRect = PDFCoordinateConverter.pdfRectToView(modelRect, page: page, pdfView: pdfView)
                cachedScreenRect = modelScreenRect
                cachedScreenRectSignatureID = activeID
                
                // ✅ SYNC FIX: Update both CALayer and SwiftUI in the same run loop cycle
                // First, publish to SwiftUI (triggers async update)
                signaturesSubject.send(signatures)
                
                // Then update CALayer synchronously in the same frame
                // Use CATransaction to ensure immediate visual update
                CATransaction.begin()
                CATransaction.setDisableActions(true) // Disable implicit animations for instant update
                updateActiveSignatureLayerTransform(signature: signature, page: page)
                CATransaction.commit()
            }
        }
        
        hasPendingChangesSubject.send(true)
    }
    
    // MARK: - Overlay Rendering
    
    /// Render signature overlays for uncommitted signatures
    private func renderSignatureOverlays() {
        // Clear existing overlays
        overlayLayer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        // Render all uncommitted signatures as overlays
        let pageSignatures = signatures[currentPageIndex] ?? []
        
        // ARCHITECTURE: In new SwiftUI overlay architecture, all signatures are rendered by SwiftUI
        // This CALayer overlay is only for legacy/uncommitted signatures (should be empty now)
        // Keeping this method for backward compatibility, but it should rarely be called
        for signature in pageSignatures {
            renderSignatureOverlay(signature, page: page)
        }
        
        // Also refresh PDF view for committed signatures
        pdfView.setNeedsDisplay()
    }
    
    private func renderSignatureOverlay(_ signature: SignatureModel, page: PDFPage) {
        // Get image
        let image: UIImage?
        if let uuid = UUID(uuidString: signature.imageID),
           let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
            image = savedSignature.image
        } else {
            // ✅ If signature image was deleted, use fallback or skip rendering
            // This prevents showing wrong signature when imageID is invalid
            image = signatureService.signatureImage
            if image == nil {
                print("⚠️ Signature imageID \(signature.imageID) not found - signature may have been deleted")
                // Don't render if no fallback available
                return
            }
        }
        
        guard let finalImage = image else { return }
        
        // Apply color tint
        let tintedImage = applyColorTint(to: finalImage, color: signature.color.uiColor)
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        
        // Convert to view coordinates
        let screenRect = PDFCoordinateConverter.pdfRectToView(pdfRect, page: page, pdfView: pdfView)
        
        // Create image layer
        let imageLayer = CALayer()
        // Set bounds, position, and anchor point for proper rotation
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.position = CGPoint(x: screenRect.midX, y: screenRect.midY)
        imageLayer.bounds = CGRect(x: 0, y: 0, width: screenRect.width, height: screenRect.height)
        // Don't set frame when using position+bounds
        imageLayer.contentsScale = UIScreen.main.scale
        imageLayer.contents = tintedImage.cgImage
        imageLayer.contentsGravity = .resizeAspect
        
        // ✅ Apply rotation + Y-flip to match PDF coordinate system
        // PDF uses bottom-left origin (Y-up), CALayer uses top-left (Y-down)
        let rotationRadians = signature.rotation * .pi / 180.0
        var transform = CATransform3DIdentity
        transform = CATransform3DRotate(transform, rotationRadians, 0, 0, 1)
        transform = CATransform3DScale(transform, 1, -1, 1) // Flip Y to match PDF
        imageLayer.transform = transform
        
        // Selection UI is handled by SwiftUI SelectionBoxView - no CALayer selection indicator needed
        overlayLayer?.addSublayer(imageLayer)
    }
    
    /// Update only the active signature's layer transform (for real-time rotation)
    private func updateActiveSignatureLayerTransform(signature: SignatureModel, page: PDFPage) {
        guard let overlayLayer = overlayLayer,
              let sublayers = overlayLayer.sublayers else { return }
        
        // Find the layer for this signature (by position matching)
        let pdfRect = signature.pdfRect(for: page)
        let screenRect = PDFCoordinateConverter.pdfRectToView(pdfRect, page: page, pdfView: pdfView)
        let expectedPosition = CGPoint(x: screenRect.midX, y: screenRect.midY)
        
        for layer in sublayers {
            // Match by position (within 1pt tolerance)
            if abs(layer.position.x - expectedPosition.x) < 1 &&
               abs(layer.position.y - expectedPosition.y) < 1 {
                // Update transform only (lightweight)
                let rotationRadians = signature.rotation * .pi / 180.0
                var transform = CATransform3DIdentity
                transform = CATransform3DRotate(transform, rotationRadians, 0, 0, 1)
                transform = CATransform3DScale(transform, 1, -1, 1) // Flip Y to match PDF
                layer.transform = transform
                break
            }
        }
    }
    
    private func applyColorTint(to image: UIImage, color: UIColor) -> UIImage {
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
    
    // MARK: - Visual Filter (Preview Only)
    
    /// Apply a visual filter to the PDFView display layer (non-destructive preview)
    /// This does NOT modify the PDF document or annotations
    func setVisualFilter(_ filterType: FilterType) {
        switch filterType {
        case .color:
            // No filter - show original
            pdfView.layer.filters = nil
            
        case .grayscale:
            // Desaturate to grayscale
            let filter = CIFilter(name: "CIColorControls")
            filter?.setDefaults()
            filter?.setValue(0.0, forKey: kCIInputSaturationKey)
            if let filter = filter {
                pdfView.layer.filters = [filter]
            } else {
                pdfView.layer.filters = nil
            }
            
        case .blackAndWhite:
            // High contrast black and white
            let filter = CIFilter(name: "CIColorControls")
            filter?.setDefaults()
            filter?.setValue(0.0, forKey: kCIInputSaturationKey)  // Remove color
            filter?.setValue(1.8, forKey: kCIInputContrastKey)     // High contrast
            filter?.setValue(0.1, forKey: kCIInputBrightnessKey)    // Slight brightness boost
            if let filter = filter {
                pdfView.layer.filters = [filter]
            } else {
                pdfView.layer.filters = nil
            }
        }
        
        // Force layer update
        pdfView.layer.setNeedsDisplay()
        pdfView.setNeedsDisplay()
    }
}

