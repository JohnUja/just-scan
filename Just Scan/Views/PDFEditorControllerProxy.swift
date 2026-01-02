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
    
    func setupSubscriptions(controller: PDFSignatureEditorController) {
        controller.canUndoSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$canUndo)
        
        controller.canRedoSubject
            .receive(on: DispatchQueue.main)
            .assign(to: &$canRedo)
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
}

