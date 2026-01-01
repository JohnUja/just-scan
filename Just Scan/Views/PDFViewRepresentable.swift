import SwiftUI
import PDFKit

struct PDFViewRepresentable: UIViewRepresentable {
    let pdfDocument: PDFDocument
    @Binding var pageIndex: Int
    @Binding var pdfViewInstance: PDFView?
    @Binding var refreshTrigger: UUID
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .systemGray6
        
        // Ensure user interaction is enabled so gestures pass through
        pdfView.isUserInteractionEnabled = true
        
        // Set the initial page
        if let page = pdfDocument.page(at: pageIndex) {
            pdfView.go(to: page)
        }
        
        DispatchQueue.main.async {
            self.pdfViewInstance = pdfView
        }
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        // Sync document if it changes
        if uiView.document != pdfDocument {
            uiView.document = pdfDocument
        }
        
        // Sync page index if it changes externally
        if let currentPage = uiView.currentPage {
            let index = pdfDocument.index(for: currentPage)
            // Check if we need to move to a different page
            if index != NSNotFound && index != pageIndex {
                if let targetPage = pdfDocument.page(at: pageIndex) {
                    uiView.go(to: targetPage)
                }
            }
        }
    }
}