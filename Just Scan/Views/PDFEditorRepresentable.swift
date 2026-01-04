//
//  PDFEditorRepresentable.swift
//  Just Scan
//
//  Created as part of signature architecture refactor
//  Phase 4: UIViewControllerRepresentable wrapper for PDFSignatureEditorController
//

import SwiftUI
import PDFKit
import Combine

/// SwiftUI wrapper for PDFSignatureEditorController
/// Bridges UIKit PDF editor to SwiftUI
struct PDFEditorRepresentable: UIViewControllerRepresentable {
    let pdfDocument: PDFDocument
    @Binding var signatures: [Int: [SignatureModel]]
    @Binding var currentPageIndex: Int
    @Binding var activeSignatureID: UUID?
    @Binding var hasPendingChanges: Bool
    
    // Controller proxy for method access
    var controllerProxy: PDFEditorControllerProxy?
    
    // Callbacks
    var onPageChange: ((Int) -> Void)?
    var onSignatureChange: (([Int: [SignatureModel]]) -> Void)?
    
    func makeUIViewController(context: Context) -> PDFSignatureEditorController {
        let controller = PDFSignatureEditorController()
        controller.loadDocument(pdfDocument)
        
        // Store controller in proxy if provided
        controllerProxy?.controller = controller
        controllerProxy?.bind(to: controller)
        
        // Subscribe to Combine publishers
        context.coordinator.setupSubscriptions(controller: controller)
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: PDFSignatureEditorController, context: Context) {
        // Page sync only - avoid unnecessary document reloads
        let targetPageIndex = currentPageIndex
        Task { @MainActor in
            if uiViewController.currentPageIndex != targetPageIndex {
                uiViewController.setPageIndex(targetPageIndex)
            }
        }
        
        // Store controller reference in coordinator and proxy
        context.coordinator.controller = uiViewController
        controllerProxy?.controller = uiViewController
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            signatures: $signatures,
            currentPageIndex: $currentPageIndex,
            activeSignatureID: $activeSignatureID,
            hasPendingChanges: $hasPendingChanges,
            onPageChange: onPageChange,
            onSignatureChange: onSignatureChange
        )
    }
    
    @MainActor
    class Coordinator {
        @Binding var signatures: [Int: [SignatureModel]]
        @Binding var currentPageIndex: Int
        @Binding var activeSignatureID: UUID?
        @Binding var hasPendingChanges: Bool
        
        var onPageChange: ((Int) -> Void)?
        var onSignatureChange: (([Int: [SignatureModel]]) -> Void)?
        
        // Store controller reference for method access
        weak var controller: PDFSignatureEditorController?
        
        private var cancellables = Set<AnyCancellable>()
        
        init(
            signatures: Binding<[Int: [SignatureModel]]>,
            currentPageIndex: Binding<Int>,
            activeSignatureID: Binding<UUID?>,
            hasPendingChanges: Binding<Bool>,
            onPageChange: ((Int) -> Void)?,
            onSignatureChange: (([Int: [SignatureModel]]) -> Void)?
        ) {
            _signatures = signatures
            _currentPageIndex = currentPageIndex
            _activeSignatureID = activeSignatureID
            _hasPendingChanges = hasPendingChanges
            self.onPageChange = onPageChange
            self.onSignatureChange = onSignatureChange
        }
        
        @MainActor
        func setupSubscriptions(controller: PDFSignatureEditorController) {
            // Prevent duplicate subscriptions
            cancellables.removeAll()
            
            // Subscribe to signatures changes
            controller.signaturesSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newSignatures in
                    self?.signatures = newSignatures
                    self?.onSignatureChange?(newSignatures)
                }
                .store(in: &cancellables)
            
            // Subscribe to page index changes
            controller.currentPageIndexSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newIndex in
                    self?.currentPageIndex = newIndex
                    self?.onPageChange?(newIndex)
                }
                .store(in: &cancellables)
            
            // Subscribe to active signature ID changes
            controller.activeSignatureIDSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newID in
                    self?.activeSignatureID = newID
                }
                .store(in: &cancellables)
            
            // Subscribe to pending changes
            controller.hasPendingChangesSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] hasChanges in
                    self?.hasPendingChanges = hasChanges
                }
                .store(in: &cancellables)
        }
        
    }
}


