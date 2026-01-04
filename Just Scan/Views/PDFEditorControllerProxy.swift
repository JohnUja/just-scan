//
//  PDFEditorControllerProxy.swift
//  Just Scan
//
//  Created as part of signature architecture refactor
//  Helper class to access PDFSignatureEditorController methods from SwiftUI
//

import Foundation
import Combine

/// Proxy class to access PDFSignatureEditorController methods from SwiftUI
/// This bridges UIKit controller methods to SwiftUI
@MainActor
class PDFEditorControllerProxy: ObservableObject {
    weak var controller: PDFSignatureEditorController?
    
    init(controller: PDFSignatureEditorController? = nil) {
        self.controller = controller
    }
    
    // MARK: - Signature Management
    
    func addNewSignature(imageID: String? = nil) {
        controller?.addNewSignature(imageID: imageID)
    }
    
    func duplicateActiveSignature() {
        controller?.duplicateActiveSignature()
    }
    
    func deleteActiveSignature() {
        controller?.deleteActiveSignature()
    }
    
    func changeActiveSignatureColor(_ color: SignatureColor) {
        controller?.changeActiveSignatureColor(color)
    }
    
    // MARK: - Document Management
    
    func commitAllToPDF() {
        controller?.commitAllToPDF()
    }
    
    func saveToDisk(url: URL) -> Bool {
        return controller?.saveToDisk(url: url) ?? false
    }
    
    func setPageIndex(_ index: Int) {
        controller?.setPageIndex(index)
    }
    
    // MARK: - Undo/Redo
    
    func undo() {
        controller?.undo()
    }
    
    func redo() {
        controller?.redo()
    }
    
    // MARK: - State Queries
    
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var isSubscribed = false
    
    func bind(to controller: PDFSignatureEditorController) {
        self.controller = controller
        
        // Prevent duplicate subscriptions
        cancellables.removeAll()
        isSubscribed = true
        
        controller.canUndoSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canUndo = $0 }
            .store(in: &cancellables)
        
        controller.canRedoSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canRedo = $0 }
            .store(in: &cancellables)
    }
    
    // Legacy method for compatibility
    func setupSubscriptions(controller: PDFSignatureEditorController) {
        bind(to: controller)
    }
    
    // MARK: - UI Helpers
    
    func getActiveSignatureScreenPosition() -> CGPoint? {
        return controller?.getActiveSignatureScreenPosition()
    }
    
    func getActiveSignatureScreenRect() -> CGRect? {
        return controller?.getActiveSignatureScreenRect()
    }
    
    func getSignatureScreenPosition(signatureID: UUID, pageIndex: Int) -> CGPoint? {
        return controller?.getSignatureScreenPosition(signatureID: signatureID, pageIndex: pageIndex)
    }
    
    func getSignatureScreenRect(signatureID: UUID, pageIndex: Int) -> CGRect? {
        return controller?.getSignatureScreenRect(signatureID: signatureID, pageIndex: pageIndex)
    }
    
    func moveActiveSignature(by delta: CGSize) {
        controller?.moveActiveSignature(by: delta)
    }
    
    func resizeActiveSignature(by scaleFactor: CGFloat) {
        controller?.resizeActiveSignature(by: scaleFactor)
    }
    
    func rotateActiveSignature(by angle: CGFloat) {
        controller?.rotateActiveSignature(by: angle)
    }
    
    func endMoveSignature() {
        guard let controller = controller else { return }
        controller.endMoveSignature()
    }
    
    func endResizeSignature() {
        guard let controller = controller else { return }
        controller.endResizeSignature()
    }
    
    func endRotateSignature() {
        guard let controller = controller else { return }
        controller.endRotateSignature()
    }
    
    /// Set active signature (SwiftUI should use this instead of directly setting activeSignatureID)
    func selectSignature(_ id: UUID?) {
        controller?.setActiveSignature(id)
    }
    
    // MARK: - Visual Filter
    
    /// Apply a visual filter to the PDFView display (non-destructive preview)
    func setVisualFilter(_ filterType: FilterType) {
        controller?.setVisualFilter(filterType)
    }
}

