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
    
    private var displayName: String {
        // Match Files.app style: show name without the .pdf extension
        document.fileName.replacingOccurrences(of: ".pdf", with: "")
    }
    
    private var displayDate: Date {
        // Prefer last modified (Files-style), fallback to createdAt
        document.lastModified ?? document.createdAt
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // PDF thumbnail
            PDFThumbnailView(documentURL: document.fileURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle()) // Make entire area tappable
            
            // Name + metadata (Files-style: name, then time/date, then size)
            Text(displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            
            Text(formatFilesStyleDate(displayDate))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Text(document.fileSizeString)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
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
    
    private func formatFilesStyleDate(_ date: Date) -> String {
        // Files.app behavior: show time if it's today, otherwise show a short date in the user's locale.
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .none
        f.dateStyle = .short
        return f
    }()
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
        // ✅ Create document and insert page (annotations are preserved)
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        pdfView.document = doc
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        // ✅ Ensure annotations are displayed
        pdfView.displayBox = .mediaBox
        // Disable user interaction to prevent double-tap zoom, but allow parent tap
        pdfView.isUserInteractionEnabled = false
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        // Ensure user interaction stays disabled
        uiView.isUserInteractionEnabled = false
        // ✅ Force refresh to show annotations
        uiView.setNeedsDisplay()
    }
}

