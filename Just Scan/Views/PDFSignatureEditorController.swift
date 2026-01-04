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
        
        // Tap gesture for selection
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
        tapGesture = tap
        
        // Enable simultaneous gestures
        pan.require(toFail: tap)
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
    
    /// Set current page index
    func setPageIndex(_ index: Int) {
        guard let document = pdfDocument,
              index >= 0 && index < document.pageCount else { return }
        
        // Commit any active edits before changing pages
        commitActiveEdit()
        
        // Clear active signature when changing pages (per-page selection)
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
            widthRatio: 0.3, // 30% of page width
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
        activeSignatureID = id
        activeSignatureIDSubject.send(id)
        renderSignatureOverlays()
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
        activeSignatureID = nil
        activeSignatureIDSubject.send(nil)
        hasPendingChangesSubject.send(true)
        
        // ✅ Refresh overlays (removes any uncommitted signature layers)
        renderSignatureOverlays()
    }
    
    /// Change color of active signature
    func changeActiveSignatureColor(_ color: SignatureColor) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else { return }
        
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
            upsertAnnotation(for: signature, on: page)
        }
        
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
        
        // Make sure everything is actually in PDF as annotations
        commitAllToPDF()
        
        // Prefer PDFDocument.write(to:) to preserve annotations
        let ok = document.write(to: url)
        
        if ok {
            hasPendingChangesSubject.send(false)
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
        
        // BRAIN LOGIC: Auto-select last modified signature after undo
        if let lastSignature = snapshot.last {
            activeSignatureID = lastSignature.id
            activeSignatureIDSubject.send(activeSignatureID)
        } else {
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
        }
        
        renderSignatureOverlays()
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
        
        // BRAIN LOGIC: Auto-select last modified signature after redo
        if let lastSignature = snapshot.last {
            activeSignatureID = lastSignature.id
            activeSignatureIDSubject.send(activeSignatureID)
        } else {
            activeSignatureID = nil
            activeSignatureIDSubject.send(nil)
        }
        
        renderSignatureOverlays()
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
        
        let bounds = CGRect(
            x: baseRect.midX - boundsWidth / 2,
            y: baseRect.midY - boundsHeight / 2,
            width: boundsWidth,
            height: boundsHeight
        )
        
        existing.bounds = PDFCoordinateConverter.clampRectToPageBounds(bounds, page: page)
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
            
            // Refresh payload
            existing.updatePayloadIfNeeded()
            
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
        
        return annotation
    }
    
    private func loadSignaturesFromAnnotations() {
        guard let document = pdfDocument else { return }
        
        var loadedSignatures: [Int: [SignatureModel]] = [:]
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            let pageSignatures = page.annotations.compactMap { annotation -> SignatureModel? in
                // ✅ Ensure annotation is editable when loading
                if let stamp = annotation as? ImageStampAnnotation {
                    stamp.isReadOnly = false  // ✅ Make editable on load
                } else {
                    annotation.isReadOnly = false  // ✅ Make editable on load
                }
                return SignatureModel.fromAnnotation(annotation, page: page)
            }
            
            if !pageSignatures.isEmpty {
                loadedSignatures[pageIndex] = pageSignatures
            }
        }
        
        signatures = loadedSignatures
    }
    
    private func commitActiveEdit() {
        // Commit any active signature edits to PDF if needed
        // This is called before page changes
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
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex) else { return }
        
        let location = gesture.location(in: pdfView)
        let pdfPoint = PDFCoordinateConverter.viewToPDF(location, page: page, pdfView: pdfView)
        
        // Find signature at tap location (check all signatures on current page)
        let pageSignatures = signatures[currentPageIndex] ?? []
        
        // Check from top to bottom (reverse order) to get the topmost signature
        // Use improved hit-testing that accounts for rotation
        for signature in pageSignatures.reversed() {
            let pdfRect = signature.pdfRect(for: page)
            let center = CGPoint(x: pdfRect.midX, y: pdfRect.midY)
            
            // Use distance-to-center bounding circle for better hit-testing with rotation
            let dx = pdfPoint.x - center.x
            let dy = pdfPoint.y - center.y
            let radius = hypot(pdfRect.width, pdfRect.height) / 2
            
            if hypot(dx, dy) <= radius {
                activeSignatureID = signature.id
                activeSignatureIDSubject.send(activeSignatureID)
                renderSignatureOverlays()
                return
            }
        }
        
        // No signature hit - deselect
        activeSignatureID = nil
        activeSignatureIDSubject.send(nil)
        renderSignatureOverlays()
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        let location = gesture.location(in: pdfView)
        let pdfPoint = PDFCoordinateConverter.viewToPDF(location, page: page, pdfView: pdfView)
        let pageBounds = page.bounds(for: .mediaBox)
        
        switch gesture.state {
        case .began:
            gestureStartSignatureID = activeID
            gestureStartCenter = signature.center
            gestureStartRect = signature.pdfRect(for: page)
            registerUndoSnapshot(for: currentPageIndex)
            
        case .changed:
            guard let startCenter = gestureStartCenter else { return }
            
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
                    
                    // If committed, update annotation bounds directly (no remove/add)
                    if signature.isCommitted,
                       let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                        updateAnnotationBounds(existing, for: signature, page: page)
                    }
                }
            }
            
            // Only render overlays (uncommitted signatures), not full PDF redraw
            renderSignatureOverlays()
            
        case .ended, .cancelled:
            if signature.isCommitted {
                upsertAnnotation(for: signature, on: page)
            }
            
            gestureStartSignatureID = nil
            gestureStartCenter = nil
            gestureStartRect = nil
            hasPendingChangesSubject.send(true)
            renderSignatureOverlays()
            
        default:
            break
        }
    }
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        switch gesture.state {
        case .began:
            gestureStartScale = 1.0
            gestureStartRect = signature.pdfRect(for: page)
            registerUndoSnapshot(for: currentPageIndex)
            
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
                    
                    // If committed, update annotation immediately
                    if signature.isCommitted,
                       let page = pdfDocument?.page(at: currentPageIndex) {
                        upsertAnnotation(for: signature, on: page)
                    }
                }
            }
            
            renderSignatureOverlays()
            
        case .ended, .cancelled:
            gestureStartScale = 1.0
            gestureStartRect = nil
            hasPendingChangesSubject.send(true)
            
        default:
            break
        }
    }
    
    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else { return }
        
        switch gesture.state {
        case .began:
            gestureStartRotation = signature.rotation
            registerUndoSnapshot(for: currentPageIndex)
            
        case .changed:
            guard let startRotation = gestureStartRotation else { return }
            
            let rotationDelta = gesture.rotation * 180 / .pi // Convert to degrees
            signature.rotation = (startRotation + rotationDelta).truncatingRemainder(dividingBy: 360)
            
            // Update in array
            if var pageSignatures = signatures[currentPageIndex] {
                if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                    pageSignatures[index] = signature
                    signatures[currentPageIndex] = pageSignatures
                    
                    // If committed, update annotation immediately
                    if signature.isCommitted,
                       let page = pdfDocument?.page(at: currentPageIndex) {
                        upsertAnnotation(for: signature, on: page)
                    }
                }
            }
            
            renderSignatureOverlays()
            
        case .ended, .cancelled:
            gestureStartRotation = nil
            hasPendingChangesSubject.send(true)
            
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
        // Only handle gestures when a signature is active (for now)
        // Could be enhanced to detect if touch is on a signature
        return activeSignatureID != nil || gestureRecognizer == tapGesture
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
    func getActiveSignatureScreenRect() -> CGRect? {
        guard let activeID = activeSignatureID,
              let signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else {
            return nil
        }
        
        // Get PDF rect from normalized coordinates
        let pdfRect = signature.pdfRect(for: page)
        
        // Convert PDF rect to screen rect
        let screenRect = PDFCoordinateConverter.pdfRectToView(pdfRect, page: page, pdfView: pdfView)
        
        // Guard against invalid rect
        guard screenRect.width.isFinite && screenRect.height.isFinite,
              screenRect.width > 0 && screenRect.height > 0 else {
            return nil
        }
        
        return screenRect
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
            
            // If committed, update annotation live
            if signature.isCommitted,
               let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                updateAnnotationBounds(existing, for: signature, page: page)
                existing.originalRotation = signature.rotation
                existing.originalColor = signature.color
                existing.originalWidthRatio = signature.widthRatio
                existing.originalAspectRatio = signature.aspectRatio
                existing.updatePayloadIfNeeded()
                pdfView.setNeedsDisplay()
            }
        }
        
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()
    }
    
    func endMoveSignature() {
        isMovingSignature = false
        hasPendingChangesSubject.send(true)
    }
    
    func endResizeSignature() {
        isResizingSignature = false
        hasPendingChangesSubject.send(true)
    }
    
    func endRotateSignature() {
        isRotatingSignature = false
        hasPendingChangesSubject.send(true)
    }
    
    /// Resize active signature by scale factor
    func resizeActiveSignature(by scaleFactor: CGFloat) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
              let page = pdfDocument?.page(at: currentPageIndex) else { return }
        
        // Register undo snapshot on first resize
        if !isResizingSignature {
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
                
                // ✅ If committed, update annotation with remove/add invalidation
                if signature.isCommitted,
                   let existing = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
                    // Update bounds and metadata
                    updateAnnotationBounds(existing, for: signature, page: page)
                    existing.originalRotation = signature.rotation
                    existing.originalColor = signature.color
                    existing.originalAspectRatio = signature.aspectRatio
                    existing.originalWidthRatio = signature.widthRatio
                    existing.updatePayloadIfNeeded()
                    
                    // ✅ Remove/add to force PDFKit refresh (prevents caching issues)
                    page.removeAnnotation(existing)
                    page.addAnnotation(existing)
                }
            }
        }
        
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
                    existing.updatePayloadIfNeeded()
                    
                    // ✅ Remove/add to force PDFKit refresh (prevents bouncing/jumping)
                    page.removeAnnotation(existing)
                    page.addAnnotation(existing)
                }
            }
        }
        
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()
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

