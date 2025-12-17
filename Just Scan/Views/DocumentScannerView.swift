//
//  DocumentScannerView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
@preconcurrency import VisionKit

struct DocumentScannerView: UIViewControllerRepresentable {
    var didFinishScanning: ((_ pages: [UIImage]) -> Void)
    var didCancel: (() -> Void)
    
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scannerViewController = VNDocumentCameraViewController()
        scannerViewController.delegate = context.coordinator
        return scannerViewController
    }
    
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(didFinishScanning: didFinishScanning, didCancel: didCancel)
    }
    
    @MainActor
    class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let didFinishScanning: ([UIImage]) -> Void
        let didCancel: () -> Void
        
        init(didFinishScanning: @escaping ([UIImage]) -> Void, didCancel: @escaping () -> Void) {
            self.didFinishScanning = didFinishScanning
            self.didCancel = didCancel
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var scannedPages: [UIImage] = []
            
            for i in 0..<scan.pageCount {
                scannedPages.append(scan.imageOfPage(at: i))
            }
            
            didFinishScanning(scannedPages)
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            didCancel()
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("Scanner error: \(error.localizedDescription)")
            didCancel()
            controller.dismiss(animated: true)
        }
    }
}

