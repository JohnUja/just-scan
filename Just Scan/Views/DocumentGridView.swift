//
//  DocumentGridView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import PDFKit

struct DocumentGridView: View {
    let document: Document
    let onTap: () -> Void
    let onShare: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        VStack(spacing: 4) {
            // PDF thumbnail
            PDFThumbnailView(documentURL: document.fileURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle()) // Make entire area tappable
            
            // Date label
            Text(formatDate(document.createdAt))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle()) // Make entire VStack tappable
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button {
                onShare()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Button {
                onTap()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "text.cursor")
            }
            
            Divider()
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

struct PDFThumbnailView: View {
    let documentURL: URL
    
    var body: some View {
        Group {
            if let pdfDocument = PDFDocument(url: documentURL),
               let firstPage = pdfDocument.page(at: 0) {
                PDFPageView(page: firstPage)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
        }
    }
}

struct PDFPageView: UIViewRepresentable {
    let page: PDFPage
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument()
        pdfView.document?.insert(page, at: 0)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        // Disable user interaction to prevent double-tap zoom, but allow parent tap
        pdfView.isUserInteractionEnabled = false
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        // Ensure user interaction stays disabled
        uiView.isUserInteractionEnabled = false
    }
}

