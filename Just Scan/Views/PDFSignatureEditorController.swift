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
    private var activeSignatureID: UUID? {
        didSet {
            // #region agent log
            // Log ALL changes to activeSignatureID (including nil assignments) to track what's clearing it
            if oldValue != activeSignatureID {
                DebugLogger.shared.logHypothesis("A", message: "activeSignatureID property changed (didSet)", data: [
                    "oldValue": oldValue?.uuidString ?? "nil",
                    "newValue": activeSignatureID?.uuidString ?? "nil",
                    "callStack": Thread.callStackSymbols.prefix(5).joined(separator: " -> ")
                ])
            }
            // #endregion
        }
    }
    
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
        
        // Disable double-tap zoom (we'll handle zoom ourselves if needed)
        for gesture in pdfView.gestureRecognizers ?? [] {
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
    func loadDocument(_ document: PDFDocument) {
        // pdfDocument is a computed property (get-only), so we just set pdfView.document
        pdfView.document = document
        
        if let page = document.page(at: currentPageIndex) {
            pdfView.go(to: page)
        }
        
        // Load existing signatures from annotations
        loadSignaturesFromAnnotations()
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
        // #region agent log
        let oldActiveID = activeSignatureID
        DebugLogger.shared.logHypothesis("A", message: "Clearing activeSignatureID (page change)", data: [
            "oldActiveID": oldActiveID?.uuidString ?? "nil",
            "newPageIndex": index
        ])
        // #endregion
        activeSignatureID = nil
        activeSignatureIDSubject.send(nil)
        
        currentPageIndex = index
        if let page = document.page(at: index) {
            pdfView.go(to: page)
        }
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
            aspectRatio: aspectRatio,
            isCommitted: false
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
            aspectRatio: activeSignature.aspectRatio,
            isCommitted: false
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
        // ✅ CRITICAL: Capture old value BEFORE changing it
        let oldValue = activeSignatureID
        
        // #region agent log
        DebugLogger.shared.logEntry("setActiveSignature", params: [
            "id": id?.uuidString ?? "nil",
            "oldActiveID": oldValue?.uuidString ?? "nil",
            "callStack": Thread.callStackSymbols.prefix(3).joined(separator: " -> ")
        ], hypothesisId: "A")
        // #endregion
        
        // ✅ CRITICAL: Only update if actually changing (prevents unnecessary clears)
        guard activeSignatureID != id else {
            // #region agent log
            DebugLogger.shared.logHypothesis("A", message: "setActiveSignature: No change, skipping", data: ["id": id?.uuidString ?? "nil"])
            // #endregion
            return
        }
        
        activeSignatureID = id
        // #region agent log
        DebugLogger.shared.logStateChange("activeSignatureID", oldValue: oldValue?.uuidString, newValue: activeSignatureID?.uuidString, hypothesisId: "A")
        // #endregion
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
        
        // ✅ Remove from PDF annotation first (if committed)
        if let page = pdfDocument?.page(at: currentPageIndex),
           let annotation = findAnnotation(for: activeID, page: page) {
            page.removeAnnotation(annotation)
            pdfView.setNeedsDisplay()  // ✅ Force refresh
        }
        
        // ✅ Remove from signatures array
        if var pageSignatures = signatures[currentPageIndex] {
            pageSignatures.removeAll { $0.id == activeID }
            signatures[currentPageIndex] = pageSignatures
        }
        
        // ✅ Clear active selection (this removes selection box)
        // #region agent log
        DebugLogger.shared.logHypothesis("A", message: "Clearing activeSignatureID (delete)", data: [
            "deletedID": activeID.uuidString
        ])
        // #endregion
        activeSignatureID = nil
        activeSignatureIDSubject.send(nil)
        hasPendingChangesSubject.send(true)
        
        // ✅ Refresh overlays (removes any uncommitted signature layers)
        renderSignatureOverlays()
    }
    
    /// Change color of active signature
    func changeActiveSignatureColor(_ color: SignatureColor) {
        // #region agent log
        DebugLogger.shared.logEntry("changeActiveSignatureColor", params: [
            "activeID": activeSignatureID?.uuidString ?? "nil",
            "newColor": color.rawValue,
            "pageIndex": currentPageIndex
        ], hypothesisId: "COLOR")
        // #endregion
        
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else {
            // #region agent log
            DebugLogger.shared.logHypothesis("COLOR", message: "❌ No active signature to change color", data: [:])
            // #endregion
            return
        }
        
        // #region agent log
        let oldColor = signature.color
        let oldCenter = signature.center
        let oldRotation = signature.rotation
        DebugLogger.shared.log(
            location: "PDFSignatureEditorController.swift:\(#line)",
            message: "Before color change",
            data: [
                "oldColor": oldColor.rawValue,
                "center": "\(oldCenter)",
                "rotation": oldRotation,
                "isCommitted": signature.isCommitted
            ],
            hypothesisId: "COLOR"
        )
        // #endregion
        
        signature.color = color
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex] {
            if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                pageSignatures[index] = signature
                signatures[currentPageIndex] = pageSignatures
            }
        }
        
        // If committed, update annotation
        if signature.isCommitted,
           let page = pdfDocument?.page(at: currentPageIndex) {
            // ✅ CRITICAL: Ensure annotation is updated without remove/add to prevent visual flipping
            if let existing = findAnnotation(for: signature.id, page: page) as? ImageStampAnnotation {
                // #region agent log
                let oldRotation = existing.originalRotation
                let oldColor = existing.originalColor
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:\(#line)",
                    message: "Updating annotation metadata for color change (no remove/add)",
                    data: [
                        "oldRotation": oldRotation,
                        "newRotation": signature.rotation,
                        "oldColor": oldColor.rawValue,
                        "newColor": signature.color.rawValue,
                        "rotationChanged": oldRotation != signature.rotation
                    ],
                    hypothesisId: "COLOR"
                )
                // #endregion
                // ✅ STRATEGY A: Do NOT pre-tint - only update color metadata
                // The draw() method will tint the base image on every redraw
                // This prevents double-tinting and ensures consistent colors
                
                // Ensure baseImageData exists (for clean retinting)
                if existing.baseImageData == nil {
                    // If baseImageData is missing, fetch original from SignatureService
                    if let uuid = UUID(uuidString: signature.imageID),
                       let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
                        existing.baseImageData = savedSignature.image.pngData()
                        // Also update storedImageData to base for backward compatibility
                        existing.storedImageData = savedSignature.image.pngData()
                    } else if let currentImage = existing.baseImage {
                        // Fallback: use current image as base
                        existing.baseImageData = currentImage.pngData()
                    }
                }
                
                // ✅ CRITICAL: Do NOT write tinted image to storedImageData
                // storedImageData should remain base (untinted) - draw() will tint it
                
                // #region agent log
                let beforeBounds = existing.bounds
                let beforeRotation = existing.originalRotation
                let beforeColor = existing.originalColor
                let hasBaseImageData = existing.baseImageData != nil
                let baseImageSize = existing.baseImage?.size
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:changeActiveSignatureColor",
                    message: "Before annotation update",
                    data: [
                        "beforeBounds": "\(beforeBounds)",
                        "beforeRotation": beforeRotation,
                        "beforeColor": beforeColor.rawValue,
                        "hasBaseImageData": hasBaseImageData,
                        "baseImageSize": baseImageSize != nil ? "\(baseImageSize!)" : "nil"
                    ],
                    hypothesisId: "COLOR"
                )
                // #endregion
                
                // Update metadata only (bounds, rotation, color)
                updateAnnotationBounds(existing, for: signature, page: page)
                existing.originalRotation = signature.rotation
                existing.originalColor = signature.color
                existing.originalAspectRatio = signature.aspectRatio
                existing.originalWidthRatio = signature.widthRatio
                
                // #region agent log
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:changeActiveSignatureColor",
                    message: "After annotation metadata update",
                    data: [
                        "afterBounds": "\(existing.bounds)",
                        "afterRotation": existing.originalRotation,
                        "afterColor": existing.originalColor.rawValue,
                        "boundsChanged": beforeBounds != existing.bounds,
                        "rotationChanged": beforeRotation != existing.originalRotation
                    ],
                    hypothesisId: "COLOR"
                )
                // #endregion
                
                // ✅ CRITICAL: Regenerate payload with new image data AND exact center
                existing.updatePayload(centerNormalized: signature.center)
                // ✅ Force redraw without remove/add (prevents visual rotation/flip)
                pdfView.setNeedsDisplay()
                // ✅ Clear cache to ensure selection box updates
                clearScreenRectCache()
                
                // #region agent log
                DebugLogger.shared.logExit("changeActiveSignatureColor", result: [
                    "finalBounds": "\(existing.bounds)",
                    "finalRotation": existing.originalRotation,
                    "finalColor": existing.originalColor.rawValue
                ], hypothesisId: "COLOR")
                // #endregion
            } else {
                // Only create new if doesn't exist
                upsertAnnotation(for: signature, on: page)
            }
        }
        
        // #region agent log
        DebugLogger.shared.log(
            location: "PDFSignatureEditorController.swift:\(#line)",
            message: "After color change",
            data: [
                "newColor": signature.color.rawValue,
                "center": "\(signature.center)",
                "rotation": signature.rotation,
                "centerChanged": signature.center != oldCenter,
                "rotationChanged": signature.rotation != oldRotation
            ],
            hypothesisId: "COLOR"
        )
        // #endregion
        
        renderSignatureOverlays()
        
        hasPendingChangesSubject.send(true)
    }
    
    /// Commit all signatures to PDF annotations
    func commitAllToPDF() {
        guard let document = pdfDocument else { return }
        
        for (pageIndex, pageSignatures) in signatures {
            guard let page = document.page(at: pageIndex) else { continue }
            
            var updated = pageSignatures
            for i in updated.indices {
                var sig = updated[i]
                
                // Upsert: update existing or create new
                upsertAnnotation(for: sig, on: page)
                
                sig.isCommitted = true
                sig.annotationID = sig.id.uuidString
                updated[i] = sig
            }
            signatures[pageIndex] = updated
        }
        
        renderSignatureOverlays()
    }
    
    /// Save PDF to disk
    func saveToDisk(url: URL) -> Bool {
        guard let document = pdfDocument else { return false }
        
        print("💾 === SAVING TO DISK ===")
        
        // Commit everything
        commitAllToPDF()
        
        // Write to disk
        let ok = document.write(to: url)
        
        if ok {
            print("✅ Write successful - reloading annotations")
            
            // ✅ CRITICAL FIX: Save activeSignatureID before clearing, so we can restore it after reload
            let savedActiveID = activeSignatureID
            
            // Clear selection temporarily (will restore after reload if signature still exists)
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
            
            // Force reload from disk to sync
            if let reloaded = PDFDocument(url: url) {
                pdfView.document = reloaded
                
                // Clear and reload model
                clearAnnotationIDCache()
                
                // #region agent log
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:saveToDisk",
                    message: "Reloading PDF after save - checking coordinate consistency",
                    data: [
                        "pageIndex": currentPageIndex,
                        "signatureCountBefore": signatures[currentPageIndex]?.count ?? 0,
                        "savedActiveID": savedActiveID?.uuidString ?? "nil"
                    ],
                    hypothesisId: "C"
                )
                // #endregion
                
                loadSignaturesFromAnnotations()
                
                // #region agent log
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:saveToDisk",
                    message: "After reload - checking if signatures moved",
                    data: [
                        "pageIndex": currentPageIndex,
                        "signatureCountAfter": signatures[currentPageIndex]?.count ?? 0,
                        "signatures": signatures[currentPageIndex]?.map { sig in
                            [
                                "id": sig.id.uuidString,
                                "center": "\(sig.center)",
                                "widthRatio": sig.widthRatio,
                                "rotation": sig.rotation
                            ]
                        } ?? []
                    ],
                    hypothesisId: "C"
                )
                // #endregion
                
                // ✅ CRITICAL FIX: Restore activeSignatureID if the signature still exists after reload
                if let savedID = savedActiveID,
                   getSignature(id: savedID, pageIndex: currentPageIndex) != nil {
                    // Signature still exists - restore selection
                    activeSignatureID = savedID
                    activeSignatureIDSubject.send(savedID)
                    // #region agent log
                    DebugLogger.shared.log(
                        location: "PDFSignatureEditorController.swift:saveToDisk",
                        message: "✅ Restored activeSignatureID after save/reload",
                        data: [
                            "restoredID": savedID.uuidString
                        ],
                        hypothesisId: "C"
                    )
                    // #endregion
                } else {
                    // #region agent log
                    DebugLogger.shared.log(
                        location: "PDFSignatureEditorController.swift:saveToDisk",
                        message: "⚠️ Could not restore activeSignatureID - signature not found after reload",
                        data: [
                            "savedID": savedActiveID?.uuidString ?? "nil"
                        ],
                        hypothesisId: "C"
                    )
                    // #endregion
                }
            }
            
            hasPendingChangesSubject.send(false)
            
            // ✅ Post notification to refresh document thumbnails in HomeView
            NotificationCenter.default.post(name: NSNotification.Name("RefreshDocumentThumbnails"), object: nil)
            
            print("💾 === SAVE COMPLETE ===")
        } else {
            print("❌ Write failed")
        }
        
        return ok
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
        
        // ✅ CRITICAL: Update committed annotations to reflect undo state
        if let page = pdfDocument?.page(at: currentPageIndex) {
            // Remove all existing annotations for this page
            let existingAnnotations = page.annotations.filter { ann in
                guard let name = ann.value(forAnnotationKey: .name) as? String,
                      name == SignatureAnnotationKeys.annotationName else { return false }
                return true
            }
            existingAnnotations.forEach { page.removeAnnotation($0) }
            
            // Re-add annotations from snapshot (committed signatures)
            for signature in snapshot where signature.isCommitted {
                upsertAnnotation(for: signature, on: page)
            }
        }
        
        // ✅ CRITICAL FIX: Validate signature exists before selecting (prevents ghost selections)
        // BRAIN LOGIC: Auto-select last modified signature after undo, but only if it exists
        if let lastSignature = snapshot.last,
           getSignature(id: lastSignature.id, pageIndex: currentPageIndex) != nil {
            // Signature exists in current model - safe to select
            activeSignatureID = lastSignature.id
            activeSignatureIDSubject.send(activeSignatureID)
        } else {
            // No valid signature to select - clear selection
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
        
        // ✅ CRITICAL: Update committed annotations to reflect redo state
        if let page = pdfDocument?.page(at: currentPageIndex) {
            // Remove all existing annotations for this page
            let existingAnnotations = page.annotations.filter { ann in
                guard let name = ann.value(forAnnotationKey: .name) as? String,
                      name == SignatureAnnotationKeys.annotationName else { return false }
                return true
            }
            existingAnnotations.forEach { page.removeAnnotation($0) }
            
            // Re-add annotations from snapshot (committed signatures)
            for signature in snapshot where signature.isCommitted {
                upsertAnnotation(for: signature, on: page)
            }
        }
        
        // ✅ CRITICAL FIX: Validate signature exists before selecting (prevents ghost selections)
        // BRAIN LOGIC: Auto-select last modified signature after redo, but only if it exists
        if let lastSignature = snapshot.last,
           getSignature(id: lastSignature.id, pageIndex: currentPageIndex) != nil {
            // Signature exists in current model - safe to select
            activeSignatureID = lastSignature.id
            activeSignatureIDSubject.send(activeSignatureID)
        } else {
            // No valid signature to select - clear selection
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
    
    private func findAnnotation(for signatureID: UUID, page: PDFPage) -> PDFAnnotation? {
        let key = signatureID.uuidString
        return page.annotations.first(where: { ann in
            guard let name = ann.value(forAnnotationKey: .name) as? String,
                  name == SignatureAnnotationKeys.annotationName else { return false }
            // Match by userName (which equals signatureID)
            return ann.userName == key
        })
    }
    
    /// Update annotation bounds directly (for performance during gestures)
    private func updateAnnotationBounds(_ existing: ImageStampAnnotation, for signature: SignatureModel, page: PDFPage) {
        let pageBounds = page.bounds(for: .mediaBox)
        
        // Base rect from normalized coordinates (unrotated)
        let baseWidth = signature.widthRatio * pageBounds.width
        let baseHeight = baseWidth / signature.aspectRatio
        let baseCenterX = signature.center.x * pageBounds.width
        let baseCenterY = signature.center.y * pageBounds.height
        
        let baseRect = CGRect(
            x: baseCenterX - baseWidth / 2,
            y: baseCenterY - baseHeight / 2,
            width: baseWidth,
            height: baseHeight
        )
        
        // Calculate padded bounding box for rotation
        let rotationRadians = abs(signature.rotation.truncatingRemainder(dividingBy: 180)) * .pi / 180
        let rotatedWidth = abs(cos(rotationRadians)) * baseRect.width + abs(sin(rotationRadians)) * baseRect.height
        let rotatedHeight = abs(sin(rotationRadians)) * baseRect.width + abs(cos(rotationRadians)) * baseRect.height
        
        let boundsWidth = max(rotatedWidth, baseRect.width) * 1.05
        let boundsHeight = max(rotatedHeight, baseRect.height) * 1.05
        
        // ✅ CRITICAL: Use EXACT center (baseCenterX/Y) not baseRect.midX/Y to prevent rounding errors
        let bounds = CGRect(
            x: baseCenterX - boundsWidth / 2,  // Use exact center, not baseRect.midX
            y: baseCenterY - boundsHeight / 2, // Use exact center, not baseRect.midY
            width: boundsWidth,
            height: boundsHeight
        )
        
        // ✅ CRITICAL FIX: Clamp bounds but NEVER mutate model here (prevents cross-page corruption)
        // Model mutation in geometry helpers creates hidden feedback loops and cross-page bugs
        // If clamping is needed, do it where the model changes (pan/move), not in annotation rendering
        let clamped = PDFCoordinateConverter.clampRectToPageBounds(bounds, page: page)
        existing.bounds = clamped
    }
    
    /// Upsert annotation: update existing or create new
    private func upsertAnnotation(for signature: SignatureModel, on page: PDFPage) {
        let sigID = signature.id.uuidString
        
        if let existing = findAnnotation(for: signature.id, page: page) as? ImageStampAnnotation {
            // Update bounds
            updateAnnotationBounds(existing, for: signature, page: page)
            
            // Update metadata
            existing.originalRotation = signature.rotation
            existing.originalColor = signature.color
            existing.originalAspectRatio = signature.aspectRatio
            existing.originalWidthRatio = signature.widthRatio
            existing.isReadOnly = false
            existing.userName = sigID
            existing.setValue(SignatureAnnotationKeys.annotationName, forAnnotationKey: .name)
            
            // Update identity fields
            existing.signatureID = sigID
            existing.imageID = signature.imageID
            
            // ✅ CRITICAL: Update payload with exact center to prevent post-save drift
            existing.updatePayload(centerNormalized: signature.center)
            
            // Just refresh view (no remove/add)
            pdfView.setNeedsDisplay()
            return
        }
        
        // Create if missing
        if let annotation = createAnnotation(from: signature, page: page) {
            page.addAnnotation(annotation)
        }
    }
    
    private func createAnnotation(from signature: SignatureModel, page: PDFPage) -> ImageStampAnnotation? {
        // Get image from SignatureService using imageID
        let image: UIImage?
        if let uuid = UUID(uuidString: signature.imageID),
           let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
            image = savedSignature.image
        } else {
            // Fallback to current signature
            image = signatureService.signatureImage
        }
        
        guard let finalImage = image else { return nil }
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        
        // Calculate bounding box with rotation padding
        let rotationRadians = abs(signature.rotation.truncatingRemainder(dividingBy: 180)) * .pi / 180
        let rotatedWidth = abs(cos(rotationRadians)) * pdfRect.width + abs(sin(rotationRadians)) * pdfRect.height
        let rotatedHeight = abs(sin(rotationRadians)) * pdfRect.width + abs(cos(rotationRadians)) * pdfRect.height
        
        let boundsWidth = max(rotatedWidth, pdfRect.width) * 1.05
        let boundsHeight = max(rotatedHeight, pdfRect.height) * 1.05
        
        let centerX = pdfRect.midX
        let centerY = pdfRect.midY
        
        let bounds = CGRect(
            x: centerX - boundsWidth / 2,
            y: centerY - boundsHeight / 2,
            width: boundsWidth,
            height: boundsHeight
        )
        
        let clampedBounds = PDFCoordinateConverter.clampRectToPageBounds(bounds, page: page)
        
        let annotation = ImageStampAnnotation(
            bounds: clampedBounds,
            image: finalImage,
            rotation: signature.rotation,
            color: signature.color,
            aspectRatio: signature.aspectRatio,
            widthRatio: signature.widthRatio,
            signatureID: signature.id.uuidString,
            imageID: signature.imageID
        )
        
        // CRITICAL: Always set both name and userName for consistency
        annotation.setValue(SignatureAnnotationKeys.annotationName, forAnnotationKey: .name)
        annotation.userName = signature.id.uuidString
        
        annotation.shouldPrint = true
        annotation.isReadOnly = false   // IMPORTANT: keep editable after reopen
        
        // ✅ CRITICAL: Update payload with exact center to prevent post-save drift
        annotation.updatePayload(centerNormalized: signature.center)
        
        return annotation
    }
    
    private func loadSignaturesFromAnnotations() {
        guard !isLoadingSignatures, let document = pdfDocument else { return }
        isLoadingSignatures = true
        defer { isLoadingSignatures = false }
        
        print("📦 === LOADING SIGNATURES ===")
        
        var loadedSignatures: [Int: [SignatureModel]] = [:]
        var totalLoaded = 0
        var totalFailed = 0
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            var pageSignatures: [SignatureModel] = []
            var annotationsToRehydrate: [(PDFAnnotation, SignatureModel)] = []
            
            for annotation in page.annotations {
                let name = annotation.value(forAnnotationKey: .name) as? String
                let contents = annotation.contents ?? ""
                
                let isOurs = (name == SignatureAnnotationKeys.annotationName) ||
                             contents.hasPrefix(SignatureAnnotationKeys.payloadPrefix)
                
                if isOurs {
                    // Ensure it's marked correctly
                    if name != SignatureAnnotationKeys.annotationName {
                        annotation.setValue(SignatureAnnotationKeys.annotationName, forAnnotationKey: .name)
                    }
                    
                    // Ensure editable
                    if let stamp = annotation as? ImageStampAnnotation {
                        stamp.isReadOnly = false
                    } else {
                        annotation.isReadOnly = false
                    }
                    
                    // Convert to model
                    if let model = SignatureModel.fromAnnotation(annotation, page: page) {
                        pageSignatures.append(model)
                        totalLoaded += 1
                        
                        // Mark for rehydration if needed
                        if !(annotation is ImageStampAnnotation) {
                            annotationsToRehydrate.append((annotation, model))
                        }
                    } else {
                        print("❌ Failed to convert annotation on page \(pageIndex)")
                        totalFailed += 1
                    }
                }
            }
            
            // Rehydrate non-ImageStampAnnotations
            for (oldAnnotation, model) in annotationsToRehydrate {
                page.removeAnnotation(oldAnnotation)
                if let newAnnotation = createAnnotation(from: model, page: page) {
                    page.addAnnotation(newAnnotation)
                }
            }
            
            if !pageSignatures.isEmpty {
                loadedSignatures[pageIndex] = pageSignatures
            }
        }
        
        signatures = loadedSignatures
        clearAnnotationIDCache()
        
        // ✅ CRITICAL FIX: Clear activeSignatureID if it no longer exists (prevents ghost selections after save/reload)
        if let currentActiveID = activeSignatureID,
           getSignature(id: currentActiveID, pageIndex: currentPageIndex) == nil {
            // Active signature was deleted or doesn't exist - clear selection
            // #region agent log
            DebugLogger.shared.logHypothesis("A", message: "Clearing activeSignatureID (signature not found after reload)", data: [
                "missingID": currentActiveID.uuidString,
                "pageIndex": currentPageIndex
            ])
            // #endregion
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
        }
        
        // ✅ CRITICAL: Publish to SwiftUI
        signaturesSubject.send(signatures)
        
        print("✅ Loaded \(totalLoaded) signatures, failed \(totalFailed)")
        print("📦 === LOAD COMPLETE ===")
        
        // Force render
        renderSignatureOverlays()
    }
    
    /// Flag to prevent recursive loading
    private var isLoadingSignatures = false
    
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
        // ✅ CRITICAL: Capture current active ID BEFORE any hit testing
        // This ensures we can properly track switching between signatures
        let currentActiveIDBeforeTap = activeSignatureID
        
        // #region agent log
        DebugLogger.shared.logEntry("handleAnnotationTap", params: [
            "currentPageIndex": currentPageIndex,
            "currentActiveID": currentActiveIDBeforeTap?.uuidString ?? "nil"
        ], hypothesisId: "SWITCH")
        // #endregion
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex) else {
            // #region agent log
            DebugLogger.shared.logHypothesis("SWITCH", message: "handleAnnotationTap: guard failed", data: ["hasDocument": pdfDocument != nil, "hasPage": pdfDocument?.page(at: currentPageIndex) != nil])
            // #endregion
            return
        }
        
        let location = gesture.location(in: pdfView)
        let pdfPoint = PDFCoordinateConverter.viewToPDF(location, page: page, pdfView: pdfView)
        // #region agent log
        DebugLogger.shared.log(location: "PDFSignatureEditorController.swift:\(#line)", message: "Tap location converted", data: ["viewLocation": "\(location)", "pdfPoint": "\(pdfPoint)"], hypothesisId: "SWITCH")
        // #endregion
        
        // ✅ PHASE 1: Try to select from loaded model (fast path)
        let pageSignatures = signatures[currentPageIndex] ?? []
        
        for signature in pageSignatures.reversed() {
            // Use annotation bounds if committed (includes padding)
            let hitRect: CGRect
            if signature.isCommitted,
               let annotation = findAnnotation(for: signature.id, page: page) {
                hitRect = annotation.bounds
            } else {
                hitRect = signature.pdfRect(for: page)
            }
            
            // Circular hit test (handles rotation better)
            // ✅ Make hit test more forgiving to prevent missing signatures when switching
            let center = CGPoint(x: hitRect.midX, y: hitRect.midY)
            let radius = hypot(hitRect.width, hitRect.height) / 2.0 // More forgiving (was 2.2)
            let distance = hypot(pdfPoint.x - center.x, pdfPoint.y - center.y)
            
            // #region agent log
            if currentActiveIDBeforeTap != nil && currentActiveIDBeforeTap != signature.id {
                // Log potential switches for debugging
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:\(#line)",
                    message: "Checking signature for switch",
                    data: [
                        "currentActiveID": currentActiveIDBeforeTap?.uuidString ?? "nil",
                        "checkingSignatureID": signature.id.uuidString,
                        "distance": distance,
                        "radius": radius,
                        "withinRadius": distance <= radius
                    ],
                    hypothesisId: "SWITCH"
                )
            }
            // #endregion
            
            if distance <= radius {
                // ✅ Use the captured active ID from BEFORE tap processing
                let previousID = currentActiveIDBeforeTap?.uuidString ?? "nil"
                let isActuallySwitching = currentActiveIDBeforeTap != nil && currentActiveIDBeforeTap != signature.id
                
                // #region agent log
                DebugLogger.shared.logHypothesis("SWITCH", message: isActuallySwitching ? "✅ Switching signature selection" : "✅ Selecting signature", data: [
                    "previousSignatureID": previousID,
                    "newSignatureID": signature.id.uuidString,
                    "isActuallySwitching": isActuallySwitching,
                    "previousSignatureCommitted": currentActiveIDBeforeTap != nil ? (getSignature(id: currentActiveIDBeforeTap!, pageIndex: currentPageIndex)?.isCommitted ?? false) : false,
                    "newSignatureCommitted": signature.isCommitted
                ])
                // #endregion
                
                // ✅ Allow switching between signatures without committing - this is safe
                // The previous signature's state is preserved in the signatures array
                activeSignatureID = signature.id
                // #region agent log
                DebugLogger.shared.logStateChange("activeSignatureID", oldValue: currentActiveIDBeforeTap?.uuidString, newValue: activeSignatureID?.uuidString, hypothesisId: "SWITCH")
                // #endregion
                clearScreenRectCache()  // ✅ Clear cache when selection changes
                activeSignatureIDSubject.send(activeSignatureID)
                renderSignatureOverlays()
                
                // Force state sync before SwiftUI queries
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // #region agent log
                    DebugLogger.shared.log(location: "PDFSignatureEditorController.swift:\(#line)", message: "After async dispatch - signature switch complete", data: ["activeSignatureID": self.activeSignatureID?.uuidString ?? "nil"], hypothesisId: "SWITCH")
                    // #endregion
                    self.renderSignatureOverlays()
                }
                return
            }
        }
        
        // ✅ PHASE 2: Model miss - scan annotations directly (handles stale model)
        // #region agent log
        DebugLogger.shared.logHypothesis("A", message: "Model miss - scanning annotations directly", data: [:])
        // #endregion
        
        for annotation in page.annotations.reversed() {
            guard let name = annotation.value(forAnnotationKey: .name) as? String,
                  name == SignatureAnnotationKeys.annotationName else { continue }
            
            // Hit test against annotation bounds
            let bounds = annotation.bounds
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = hypot(bounds.width, bounds.height) / 2.2
            let distance = hypot(pdfPoint.x - center.x, pdfPoint.y - center.y)
            
            if distance <= radius {
                // #region agent log
                DebugLogger.shared.logHypothesis("A", message: "Direct annotation hit - rehydrating model", data: [:])
                // #endregion
                
                // Rehydrate model from annotation
                if let model = SignatureModel.fromAnnotation(annotation, page: page) {
                    // Add to model (check if already exists first)
                    var pageSignatures = signatures[currentPageIndex] ?? []
                    if !pageSignatures.contains(where: { $0.id == model.id }) {
                        pageSignatures.append(model)
                        signatures[currentPageIndex] = pageSignatures
                        // ✅ CRITICAL: Publish to SwiftUI
                        signaturesSubject.send(signatures)
                        // #region agent log
                        DebugLogger.shared.logHypothesis("A", message: "Added rehydrated signature to model", data: ["signatureID": model.id.uuidString])
                        // #endregion
                    } else {
                        // #region agent log
                        DebugLogger.shared.logHypothesis("A", message: "Signature already in model, updating", data: ["signatureID": model.id.uuidString])
                        // #endregion
                        if let index = pageSignatures.firstIndex(where: { $0.id == model.id }) {
                            pageSignatures[index] = model
                            signatures[currentPageIndex] = pageSignatures
                            // ✅ CRITICAL: Publish to SwiftUI
                            signaturesSubject.send(signatures)
                        }
                    }
                    
                    // Select it
                    activeSignatureID = model.id
                    activeSignatureIDSubject.send(activeSignatureID)
                    renderSignatureOverlays()
                    
                    // Force a small delay to ensure Combine publishers have propagated
                    DispatchQueue.main.async { [weak self] in
                        self?.renderSignatureOverlays()
                    }
                    
                    // #region agent log
                    DebugLogger.shared.logHypothesis("A", message: "Rehydrated and selected", data: ["signatureID": model.id.uuidString])
                    // #endregion
                    return
                } else {
                    // #region agent log
                    DebugLogger.shared.logHypothesis("A", message: "Failed to rehydrate annotation", data: [:])
                    // #endregion
                }
            }
        }
        
        // ✅ PHASE 3: No hit - deselect
        // BUT: Check if tap is near any signature (within 2x radius) - if so, don't deselect
        // This prevents deselection when tapping near a signature (user might be trying to switch)
        var isNearAnySignature = false
        for signature in pageSignatures {
            let hitRect: CGRect
            if signature.isCommitted,
               let annotation = findAnnotation(for: signature.id, page: page) {
                hitRect = annotation.bounds
            } else {
                hitRect = signature.pdfRect(for: page)
            }
            let center = CGPoint(x: hitRect.midX, y: hitRect.midY)
            let radius = hypot(hitRect.width, hitRect.height) / 2.0
            let distance = hypot(pdfPoint.x - center.x, pdfPoint.y - center.y)
            // ✅ Use 2x radius for "near" check (more forgiving)
            if distance <= radius * 2.0 {
                isNearAnySignature = true
                break
            }
        }
        
        // #region agent log
        let wasActive = activeSignatureID != nil
        let activeIDBeforeDeselect = activeSignatureID?.uuidString ?? "nil"
        DebugLogger.shared.logHypothesis("SWITCH", message: isNearAnySignature ? "No signature hit but near signature - NOT deselecting" : "No signature hit - deselecting", data: [
            "wasActive": wasActive,
            "activeIDBeforeDeselect": activeIDBeforeDeselect,
            "tapLocation": "\(gesture.location(in: pdfView))",
            "pdfPoint": "\(pdfPoint)",
            "isNearAnySignature": isNearAnySignature
        ])
        // #endregion
        
        // ✅ CRITICAL FIX: Only deselect if we truly didn't hit anything AND not near any signature
        // Don't deselect if we're near a signature (user might be trying to switch)
        if wasActive && !isNearAnySignature {
            // #region agent log
            let oldActiveID = activeSignatureID
            DebugLogger.shared.logHypothesis("SWITCH", message: "Clearing activeSignatureID (no hit, not near signature)", data: [
                "oldActiveID": oldActiveID?.uuidString ?? "nil",
                "tapLocation": "\(gesture.location(in: pdfView))"
            ])
            // #endregion
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
            renderSignatureOverlays()
        }
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // ✅ CRITICAL: Add defensive checks to prevent crashes
        guard let activeID = activeSignatureID else {
            // #region agent log
            DebugLogger.shared.logHypothesis("MOVE", message: "⚠️ Pan gesture but no activeSignatureID", data: [:])
            // #endregion
            return
        }
        guard var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else {
            // #region agent log
            DebugLogger.shared.logHypothesis("MOVE", message: "⚠️ Pan gesture but signature not found", data: ["activeID": activeID.uuidString, "pageIndex": currentPageIndex])
            // #endregion
            return
        }
        guard let page = pdfDocument?.page(at: currentPageIndex) else {
            // #region agent log
            DebugLogger.shared.logHypothesis("MOVE", message: "⚠️ Pan gesture but page not found", data: ["pageIndex": currentPageIndex])
            // #endregion
            return
        }
        
        let location = gesture.location(in: pdfView)
        let pdfPoint = PDFCoordinateConverter.viewToPDF(location, page: page, pdfView: pdfView)
        let pageBounds = page.bounds(for: .mediaBox)
        
        switch gesture.state {
        case .began:
            // #region agent log
            DebugLogger.shared.logEntry("handlePan", params: [
                "activeID": activeID.uuidString,
                "startLocation": "\(location)",
                "startPDFPoint": "\(pdfPoint)"
            ], hypothesisId: "MOVE")
            // #endregion
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
            // #region agent log
            // ✅ Removed unsafe value(forKey:) call - can cause crashes
            // Log periodically using timestamp instead
            let timestamp = Date().timeIntervalSince1970
            if Int(timestamp * 10) % 10 == 0 {  // Log every ~1 second to avoid spam
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:handlePan",
                    message: "Pan gesture changed",
                    data: [
                        "location": "\(location)",
                        "pdfPoint": "\(pdfPoint)",
                        "velocity": "\(gesture.velocity(in: pdfView))"
                    ],
                    hypothesisId: "MOVE"
                )
            }
            // #endregion
            guard let startCenter = gestureStartCenter else {
                // #region agent log
                DebugLogger.shared.logHypothesis("MOVE", message: "⚠️ Pan changed but no startCenter - aborting", data: [:])
                // #endregion
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
                    
                    // ✅ Clear cache when signature position changes (prevents stale cache during drag)
                    clearScreenRectCache()
                    
                    // If committed, update annotation bounds directly (no remove/add)
                    if signature.isCommitted,
                       let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                        updateAnnotationBounds(existing, for: signature, page: page)
                        pdfView.setNeedsDisplay()
                    }
                }
            }
            
            // ✅ CRITICAL: Don't render overlays on every pan change - too expensive and causes jittering
            // Only update annotation bounds directly (committed signatures)
            // renderSignatureOverlays() - REMOVED: Only needed for uncommitted signatures
            
        case .ended, .cancelled:
            // #region agent log
            DebugLogger.shared.logExit("handlePan", result: [
                "finalCenter": "\(signature.center)",
                "isCommitted": signature.isCommitted,
                "finalPDFRect": "\(signature.pdfRect(for: page))"
            ], hypothesisId: "MOVE")
            // #endregion
            
            if signature.isCommitted {
                upsertAnnotation(for: signature, on: page)
            }
            
            gestureStartSignatureID = nil
            gestureStartCenter = nil
            gestureStartRect = nil
            isInGesture = false  // ✅ Clear gesture flag
            // ✅ Clear cache to force selection box recalculation with new position
            clearScreenRectCache()
            hasPendingChangesSubject.send(true)
            renderSignatureOverlays()  // Only render once at end
            
        default:
            break
        }
    }
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else {
            // #region agent log
            DebugLogger.shared.logHypothesis("SCALE", message: "⚠️ Pinch gesture but guard failed", data: [
                "activeID": activeSignatureID?.uuidString ?? "nil",
                "signatureExists": getSignature(id: activeSignatureID ?? UUID(), pageIndex: currentPageIndex) != nil,
                "pageExists": pdfDocument?.page(at: currentPageIndex) != nil
            ])
            // #endregion
            return
        }
        
        switch gesture.state {
        case .began:
            // #region agent log
            DebugLogger.shared.logEntry("handlePinch", params: [
                "activeID": activeID.uuidString,
                "startScale": gesture.scale,
                "startWidthRatio": signature.widthRatio
            ], hypothesisId: "SCALE")
            // #endregion
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
            
            // #region agent log
            let frameCount = Int(Date().timeIntervalSince1970 * 10) % 10
            if frameCount == 0 {  // Log periodically to avoid spam
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:handlePinch",
                    message: "Pinch gesture changed",
                    data: [
                        "gestureScale": gesture.scale,
                        "gestureStartScale": gestureStartScale,
                        "calculatedScale": scale,
                        "oldWidthRatio": signature.widthRatio
                    ],
                    hypothesisId: "SCALE"
                )
            }
            // #endregion
            
            // Update width ratio (normalized)
            let newWidthRatio = signature.widthRatio * scale
            signature.widthRatio = max(0.05, min(0.5, newWidthRatio)) // Clamp between 5% and 50%
            
            // Update in array
            if var pageSignatures = signatures[currentPageIndex] {
                if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                    pageSignatures[index] = signature
                    signatures[currentPageIndex] = pageSignatures
                    
                    // ✅ Clear cache when signature size changes (prevents stale cache during resize)
                    clearScreenRectCache()
                    
                    // If committed, update annotation bounds directly (no payload update - too expensive per frame)
                    if signature.isCommitted,
                       let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                        updateAnnotationBounds(existing, for: signature, page: page)
                        existing.originalRotation = signature.rotation
                        existing.originalColor = signature.color
                        existing.originalAspectRatio = signature.aspectRatio
                        existing.originalWidthRatio = signature.widthRatio
                        pdfView.setNeedsDisplay()
                    }
                }
            }
            
            // ✅ CRITICAL: Don't call renderSignatureOverlays() on every pinch change - too expensive and causes jittering
            // renderSignatureOverlays() - REMOVED: Only needed for uncommitted signatures
            
        case .ended, .cancelled:
            // #region agent log
            DebugLogger.shared.logExit("handlePinch", result: [
                "finalWidthRatio": signature.widthRatio,
                "isCommitted": signature.isCommitted
            ], hypothesisId: "SCALE")
            // #endregion
            
            // ✅ CRITICAL FIX: On pinch .ended, finalize by updating payload once
            // This is the ONLY place payload should be updated during resize
            if signature.isCommitted,
               let page = pdfDocument?.page(at: currentPageIndex),
               let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                // Finalize bounds and update payload with exact center
                upsertAnnotation(for: signature, on: page)
            }
            
            gestureStartScale = 1.0
            gestureStartRect = nil
            isInGesture = false  // ✅ Clear gesture flag
            clearScreenRectCache()  // ✅ Clear cache when resize ends
            hasPendingChangesSubject.send(true)
            renderSignatureOverlays()  // Only render once at end
            
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
            // #region agent log
            DebugLogger.shared.logEntry("handleRotation", params: [
                "activeID": activeID.uuidString,
                "startRotation": signature.rotation,
                "isCommitted": signature.isCommitted
            ], hypothesisId: "ROTATE")
            // #endregion
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
            
            // #region agent log
            let frameCount = Int(Date().timeIntervalSince1970 * 100) % 10
            if frameCount == 0 {  // Log periodically to avoid spam
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:handleRotation",
                    message: "Rotation gesture changed",
                    data: [
                        "startRotation": startRotation,
                        "rotationDelta": rotationDelta,
                        "newRotation": newRotation,
                        "gestureRotation": gesture.rotation,
                        "isCommitted": signature.isCommitted
                    ],
                    hypothesisId: "ROTATE"
                )
            }
            // #endregion
            
            signature.rotation = newRotation
            
            // Update in array
            if var pageSignatures = signatures[currentPageIndex] {
                if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                    pageSignatures[index] = signature
                    signatures[currentPageIndex] = pageSignatures
                    
                    // ✅ CRITICAL FIX: During rotation .changed, ONLY update rotation and redraw
                    // Do NOT recompute padded bounds/clamp every frame (causes bouncing/oscillation)
                    // Do NOT clear cache during rotation - keep cached rect to prevent jittering
                    // Only update rotation value and trigger redraw
                    if signature.isCommitted {
                        // Just update rotation metadata and redraw - no bounds recomputation
                        if let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                            existing.originalRotation = signature.rotation
                            // ✅ CRITICAL: Do NOT call updateAnnotationBounds during rotation - causes bouncing
                            // The bounds will be recalculated on .ended via upsertAnnotation
                            pdfView.setNeedsDisplay()
                        }
                    }
                    
                    // ✅ CRITICAL FIX: Keep cached rect during rotation - rotation doesn't change rect size
                    // The selection box will rotate via the rotation parameter, not by recalculating rect
                    // This prevents jittering and bouncing during rotation
                }
            }
            
            // ✅ Don't render overlays during rotation - too expensive and causes lag
            // renderSignatureOverlays() - REMOVED: Only needed for uncommitted signatures
            
        case .ended, .cancelled:
            // #region agent log
            DebugLogger.shared.logExit("handleRotation", result: [
                "finalRotation": signature.rotation,
                "isCommitted": signature.isCommitted
            ], hypothesisId: "ROTATE")
            // #endregion
            
            // ✅ CRITICAL FIX: On rotation .ended, finalize by recomputing padded bounds once and updating payload
            // This is the ONLY place bounds and payload should be updated during rotation
            if signature.isCommitted,
               let page = pdfDocument?.page(at: currentPageIndex) {
                upsertAnnotation(for: signature, on: page)  // This calls updatePayload internally
            }
            
            gestureStartRotation = nil
            isInGesture = false  // ✅ Clear gesture flag
            clearScreenRectCache()  // ✅ Clear cache when rotation ends to recalculate with new rotation
            hasPendingChangesSubject.send(true)
            renderSignatureOverlays()  // Only render once at end
            
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
                    let hitRect = signature.isCommitted && findAnnotation(for: signature.id, page: page) != nil
                        ? findAnnotation(for: signature.id, page: page)!.bounds
                        : signature.pdfRect(for: page)
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
    /// Uses caching to prevent excessive recalculations during drag operations
    func getActiveSignatureScreenRect() -> CGRect? {
        // #region agent log
        getActiveSignatureScreenRectCallCount += 1
        let timestamp = Date().timeIntervalSince1970
        let frameID = Int(timestamp * 60) % 60  // Log every ~1 second (60fps)
        if getActiveSignatureScreenRectCallCount % 60 == 0 || frameID == 0 {  // Throttle to avoid spam
            DebugLogger.shared.log(
                location: "PDFSignatureEditorController.swift:getActiveSignatureScreenRect",
                message: "📊 getActiveSignatureScreenRect called",
                data: [
                    "callCount": getActiveSignatureScreenRectCallCount,
                    "timestamp": timestamp,
                    "activeID": activeSignatureID?.uuidString ?? "nil",
                    "isInGesture": isInGesture,
                    "hasCache": cachedScreenRect != nil
                ],
                hypothesisId: "JITTER"
            )
        }
        // #endregion
        
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
        
        // ✅ CRITICAL FIX: Use cache during gestures to prevent jittering
        // If we're in a gesture and have a valid cache for this signature, return cached value
        // This prevents SwiftUI from recalculating the rect on every render during gestures
        if isInGesture,
           let cached = cachedScreenRect,
           cachedScreenRectSignatureID == activeID {
            // #region agent log
            if getActiveSignatureScreenRectCallCount % 60 == 0 || frameID == 0 {
                DebugLogger.shared.log(
                    location: "PDFSignatureEditorController.swift:getActiveSignatureScreenRect",
                    message: "📊 Using cached rect (in gesture)",
                    data: [
                        "cachedRect": "\(cached)"
                    ],
                    hypothesisId: "JITTER"
                )
            }
            // #endregion
            return cached
        }
        
        // ✅ CRITICAL FIX: Use different rect source based on signature state
        // Uncommitted (SwiftUI overlay): Use model geometry (center/widthRatio/rotation)
        // Committed (PDFKit annotation): Use annotation bounds (prevents drift from padding/clamping)
        let pdfRect: CGRect
        let rectSource: String
        if signature.isCommitted,
           let annotation = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
            // ✅ Committed: Use annotation bounds (PDFKit's actual drawn bounds)
            // This prevents "signature moves inside box" from padding/clamping/normalization
            pdfRect = annotation.bounds
            rectSource = "annotation.bounds"
        } else {
            // ✅ Uncommitted: Use model geometry (SwiftUI is drawing it)
            pdfRect = signature.pdfRect(for: page)
            rectSource = "model.pdfRect"
        }
        
        // #region agent log
        if getActiveSignatureScreenRectCallCount % 60 == 0 || frameID == 0 {
            DebugLogger.shared.log(
                location: "PDFSignatureEditorController.swift:getActiveSignatureScreenRect",
                message: "📊 Rect calculation",
                data: [
                    "rectSource": rectSource,
                    "isCommitted": signature.isCommitted,
                    "pdfRect": "\(pdfRect)",
                    "modelCenter": "\(signature.center)",
                    "modelRotation": signature.rotation
                ],
                hypothesisId: "JITTER"
            )
        }
        // #endregion
        
        // Convert PDF rect to screen rect
        let screenRect = PDFCoordinateConverter.pdfRectToView(pdfRect, page: page, pdfView: pdfView)
        
        // #region agent log
        if getActiveSignatureScreenRectCallCount % 60 == 0 || frameID == 0 {
            DebugLogger.shared.log(
                location: "PDFSignatureEditorController.swift:getActiveSignatureScreenRect",
                message: "📊 Screen rect result",
                data: [
                    "screenRect": "\(screenRect)",
                    "width": screenRect.width,
                    "height": screenRect.height
                ],
                hypothesisId: "JITTER"
            )
        }
        // #endregion
        
        // Guard against invalid rect
        guard screenRect.width.isFinite && screenRect.height.isFinite,
              screenRect.width > 0 && screenRect.height > 0 else {
            cachedScreenRect = nil
            cachedScreenRectSignatureID = nil
            return nil
        }
        
        // ✅ CRITICAL FIX: Cache the result to prevent recalculation on every SwiftUI render
        cachedScreenRect = screenRect
        cachedScreenRectSignatureID = activeID
        cachedScreenRectTimestamp = timestamp
        
        return screenRect
    }
    
    /// Clear screen rect cache (call when signature position changes)
    private func clearScreenRectCache() {
        cachedScreenRect = nil
        cachedScreenRectSignatureID = nil
    }
    
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
            // Cache the initial rect to prevent jittering
            if let initialRect = getActiveSignatureScreenRect() {
                cachedScreenRect = initialRect
                cachedScreenRectSignatureID = activeID
            }
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
            
            // If committed, update annotation live
            if signature.isCommitted,
               let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                updateAnnotationBounds(existing, for: signature, page: page)
                existing.originalRotation = signature.rotation
                existing.originalColor = signature.color
                existing.originalWidthRatio = signature.widthRatio
                existing.originalAspectRatio = signature.aspectRatio
                // ✅ During move: Only update bounds + metadata + redraw (no payload update - too expensive per frame)
                pdfView.setNeedsDisplay()
            }
        }
        
        // ✅ CRITICAL: Don't call renderSignatureOverlays() on every move - too expensive and causes jittering
        // Only update annotation bounds directly (same as pan gesture)
        hasPendingChangesSubject.send(true)
        // renderSignatureOverlays() - REMOVED: Only needed for uncommitted signatures
    }
    
    func endMoveSignature() {
        isMovingSignature = false
        isInGesture = false  // ✅ Clear gesture flag
        // ✅ Clear cache to force selection box recalculation with new position
        clearScreenRectCache()
        
        // ✅ CRITICAL: Update payload with exact center ONCE at end (not every frame)
        if let activeID = activeSignatureID,
           let signature = getSignature(id: activeID, pageIndex: currentPageIndex),
           let page = pdfDocument?.page(at: currentPageIndex),
           let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
            existing.updatePayload(centerNormalized: signature.center)
        }
        
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()  // Only render once at end
    }
    
    func endRotateSignature() {
        isRotatingSignature = false
        isInGesture = false  // ✅ Clear gesture flag
        hasPendingChangesSubject.send(true)
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
            // Cache the initial rect to prevent jittering
            if let initialRect = getActiveSignatureScreenRect() {
                cachedScreenRect = initialRect
                cachedScreenRectSignatureID = activeID
            }
        }
        
        // Update width ratio (normalized)
        let newWidthRatio = signature.widthRatio * scaleFactor
        signature.widthRatio = max(0.05, min(0.5, newWidthRatio)) // Clamp between 5% and 50%
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex] {
            if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                pageSignatures[index] = signature
                signatures[currentPageIndex] = pageSignatures
                
                // ✅ If committed, update annotation bounds directly (no remove/add - prevents bouncing)
                if signature.isCommitted,
                   let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                    // Update bounds and metadata directly (same as pan/rotation gestures)
                    updateAnnotationBounds(existing, for: signature, page: page)
                    existing.originalRotation = signature.rotation
                    existing.originalColor = signature.color
                    existing.originalAspectRatio = signature.aspectRatio
                    existing.originalWidthRatio = signature.widthRatio
                    // ✅ During resize: Only update bounds + metadata + redraw (no payload update - too expensive per frame)
                    pdfView.setNeedsDisplay()
                }
            }
        }
        
        hasPendingChangesSubject.send(true)
        // ✅ CRITICAL: Don't call renderSignatureOverlays() on every resize - too expensive and causes jittering
        // renderSignatureOverlays() - REMOVED: Only needed for uncommitted signatures
    }
    
    func endResizeSignature() {
        isResizingSignature = false
        isInGesture = false  // ✅ Clear gesture flag
        // ✅ Clear cache to force selection box recalculation with new size
        clearScreenRectCache()
        
        // ✅ CRITICAL: Update payload with exact center ONCE at end (not every frame)
        if let activeID = activeSignatureID,
           let signature = getSignature(id: activeID, pageIndex: currentPageIndex),
           let page = pdfDocument?.page(at: currentPageIndex),
           let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
            existing.updatePayload(centerNormalized: signature.center)
        }
        
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()  // Only render once at end
    }
    
    /// Rotate active signature by angle (degrees)
    func rotateActiveSignature(by angle: CGFloat) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        // Register undo snapshot on first rotate
        if !isRotatingSignature {
            registerUndoSnapshot(for: currentPageIndex)
            isRotatingSignature = true
        }
        
        signature.rotation = (signature.rotation + angle).truncatingRemainder(dividingBy: 360)
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex] {
            if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                pageSignatures[index] = signature
                signatures[currentPageIndex] = pageSignatures
                
                // ✅ If committed, update annotation with remove/add invalidation
                if signature.isCommitted,
                   let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                    // Update bounds and metadata
                    updateAnnotationBounds(existing, for: signature, page: page)
                    existing.originalRotation = signature.rotation
                    existing.originalColor = signature.color
                    existing.originalAspectRatio = signature.aspectRatio
                    existing.originalWidthRatio = signature.widthRatio
                    // ✅ During rotate: Only update bounds + metadata + redraw (no payload update - too expensive per frame)
                    pdfView.setNeedsDisplay()
                }
            }
        }
        
        hasPendingChangesSubject.send(true)
        // ✅ CRITICAL: Don't render overlays on every rotate call - too expensive
        // renderSignatureOverlays() - REMOVED: Only needed for uncommitted signatures
    }
    
    // MARK: - Overlay Rendering
    
    /// Render signature overlays for uncommitted signatures
    private func renderSignatureOverlays() {
        // Clear existing overlays
        overlayLayer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        // Render all uncommitted signatures as overlays
        let pageSignatures = signatures[currentPageIndex] ?? []
        
        for signature in pageSignatures where !signature.isCommitted {
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
            image = signatureService.signatureImage
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
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setDefaults()
                filter.setValue(0.0, forKey: kCIInputSaturationKey)
                pdfView.layer.filters = [filter]
            } else {
                pdfView.layer.filters = nil
            }
            
        case .blackAndWhite:
            // High contrast black and white
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setDefaults()
                filter.setValue(0.0, forKey: kCIInputSaturationKey)  // Remove color
                filter.setValue(1.8, forKey: kCIInputContrastKey)     // High contrast
                filter.setValue(0.1, forKey: kCIInputBrightnessKey)    // Slight brightness boost
                pdfView.layer.filters = [filter]
            } else {
                pdfView.layer.filters = nil
            }
        }
    }
}

