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
        
        // Update overlay when view bounds change
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateOverlayFrame),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func updateOverlayFrame() {
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
    
    /// Delete the active signature
    func deleteActiveSignature() {
        guard let activeID = activeSignatureID else { return }
        
        registerUndoSnapshot(for: currentPageIndex)
        
        // Remove from signatures array
        if var pageSignatures = signatures[currentPageIndex] {
            pageSignatures.removeAll { $0.id == activeID }
            signatures[currentPageIndex] = pageSignatures
            
            // If it was committed, remove from PDF
            if let page = pdfDocument?.page(at: currentPageIndex),
               let annotation = findAnnotation(for: activeID, page: page) {
                page.removeAnnotation(annotation)
            }
        }
        
        // Clear active selection
        activeSignatureID = nil
        activeSignatureIDSubject.send(nil)
        hasPendingChangesSubject.send(true)
        
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
           let page = pdfDocument?.page(at: currentPageIndex),
           let annotation = findAnnotation(for: activeID, page: page) as? ImageStampAnnotation {
            annotation.originalColor = color
            renderSignatureOverlays()
        }
        
        hasPendingChangesSubject.send(true)
    }
    
    /// Commit all signatures to PDF annotations
    func commitAllToPDF() {
        guard let document = pdfDocument else { return }
        
        for (pageIndex, pageSignatures) in signatures {
            guard let page = document.page(at: pageIndex) else { continue }
            
            for var signature in pageSignatures {
                if !signature.isCommitted {
                    // Create annotation
                    if let annotation = createAnnotation(from: signature, page: page) {
                        page.addAnnotation(annotation)
                        signature.isCommitted = true
                        signature.annotationID = annotation.userName
                        
                        // Update in array
                        if var pageSigs = signatures[pageIndex],
                           let index = pageSigs.firstIndex(where: { $0.id == signature.id }) {
                            pageSigs[index] = signature
                            signatures[pageIndex] = pageSigs
                        }
                    }
                }
            }
        }
        
        renderSignatureOverlays()
    }
    
    /// Save PDF to disk
    func saveToDisk(url: URL) -> Bool {
        guard let document = pdfDocument,
              let data = document.dataRepresentation() else { return false }
        
        do {
            try data.write(to: url, options: .atomic)
            hasPendingChangesSubject.send(false)
            return true
        } catch {
            print("Failed to save PDF: \(error)")
            return false
        }
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
        return page.annotations.first { annotation in
            // Check if annotation matches signature
            if annotation is ImageStampAnnotation {
                // Compare by position and properties (simplified - could be improved)
                return true // Placeholder - would need to store signatureID in annotation
            }
            return false
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
            widthRatio: signature.widthRatio
        )
        
        annotation.setValue("JustScanSignature_v1", forAnnotationKey: .name)
        annotation.isLocked = true
        annotation.shouldPrint = true
        
        return annotation
    }
    
    private func loadSignaturesFromAnnotations() {
        guard let document = pdfDocument else { return }
        
        var loadedSignatures: [Int: [SignatureModel]] = [:]
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            let pageSignatures = page.annotations.compactMap { annotation -> SignatureModel? in
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
        for signature in pageSignatures.reversed() {
            // Check if tap is within signature bounds (using normalized coordinates)
            let pdfRect = signature.pdfRect(for: page)
            if pdfRect.contains(pdfPoint) {
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
            gestureStartRect = signature.pdfRect(for: page)
            registerUndoSnapshot(for: currentPageIndex)
            
        case .changed:
            guard let startRect = gestureStartRect else { return }
            
            // Calculate delta in normalized coordinates
            let deltaX = (pdfPoint.x - startRect.midX) / pageBounds.width
            let deltaY = (pdfPoint.y - startRect.midY) / pageBounds.height
            
            // Update normalized center
            signature.center.x += deltaX
            signature.center.y += deltaY
            
            // Clamp to valid range
            signature.center.x = max(0.05, min(0.95, signature.center.x))
            signature.center.y = max(0.05, min(0.95, signature.center.y))
            
            // Update in array
            if var pageSignatures = signatures[currentPageIndex] {
                if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                    pageSignatures[index] = signature
                    signatures[currentPageIndex] = pageSignatures
                }
            }
            
            renderSignatureOverlays()
            
        case .ended, .cancelled:
            gestureStartSignatureID = nil
            gestureStartRect = nil
            hasPendingChangesSubject.send(true)
            
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
        
        // CRITICAL FIX: Convert screen delta to PDF delta using coordinate converter
        let pageBounds = page.bounds(for: .mediaBox)
        
        // Convert screen delta to PDF delta
        // Use PDFCoordinateConverter to properly handle coordinate conversion
        let screenPoint1 = CGPoint(x: 0, y: 0)
        let screenPoint2 = CGPoint(x: screenDelta.width, y: screenDelta.height)
        
        let pdfPoint1 = PDFCoordinateConverter.viewToPDF(screenPoint1, page: page, pdfView: pdfView)
        let pdfPoint2 = PDFCoordinateConverter.viewToPDF(screenPoint2, page: page, pdfView: pdfView)
        
        // Calculate PDF delta
        let pdfDeltaX = pdfPoint2.x - pdfPoint1.x
        let pdfDeltaY = pdfPoint2.y - pdfPoint1.y
        
        // Convert PDF delta to normalized delta
        let normalizedDX = pdfDeltaX / pageBounds.width
        let normalizedDY = pdfDeltaY / pageBounds.height
        
        // Update normalized center
        signature.center.x += normalizedDX
        signature.center.y += normalizedDY
        
        // Clamp to 0...1
        signature.center.x = max(0.05, min(0.95, signature.center.x))
        signature.center.y = max(0.05, min(0.95, signature.center.y))
        
        // Update in array
        if var pageSignatures = signatures[currentPageIndex] {
            if let index = pageSignatures.firstIndex(where: { $0.id == activeID }) {
                pageSignatures[index] = signature
                signatures[currentPageIndex] = pageSignatures
            }
        }
        
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays() // Refresh display
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
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else { return }
        
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
            }
        }
        
        hasPendingChangesSubject.send(true)
        renderSignatureOverlays()
    }
    
    /// Rotate active signature by angle (degrees)
    func rotateActiveSignature(by angle: CGFloat) {
        guard let activeID = activeSignatureID,
              var signature = getSignature(id: activeID, pageIndex: currentPageIndex) else { return }
        
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
        imageLayer.frame = screenRect
        imageLayer.contents = tintedImage.cgImage
        imageLayer.contentsGravity = .resizeAspect
        
        // Apply rotation (convert to radians)
        let rotationRadians = signature.rotation * .pi / 180.0
        imageLayer.transform = CATransform3DMakeRotation(rotationRadians, 0, 0, 1)
        
        // Add selection indicator if active
        if signature.id == activeSignatureID {
            let selectionLayer = CAShapeLayer()
            selectionLayer.frame = screenRect
            
            let path = UIBezierPath(rect: CGRect(x: 0, y: 0, width: screenRect.width, height: screenRect.height))
            selectionLayer.path = path.cgPath
            selectionLayer.strokeColor = UIColor.systemYellow.cgColor
            selectionLayer.fillColor = UIColor.clear.cgColor
            selectionLayer.lineWidth = 2.0
            selectionLayer.lineDashPattern = [5, 3]
            
            overlayLayer?.addSublayer(selectionLayer)
        }
        
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
}

