//
//  DocumentGridView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import PDFKit
import CoreGraphics

struct DocumentGridView: View {
    let document: Document
    let tileSize: CGFloat
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
    
    private var safeTileSize: CGFloat {
        if tileSize.isFinite, tileSize > 1 {
            return tileSize
        }
        return 150
    }
    private var thumbnailHeight: CGFloat { safeTileSize }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // PDF thumbnail
            PDFThumbnailView(documentURL: document.fileURL)
                .frame(width: safeTileSize, height: thumbnailHeight)
                .clipped()
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
        .frame(width: safeTileSize, alignment: .leading)
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
    @State private var refreshID = UUID()  // Force refresh when file changes
    @State private var thumbnailImage: UIImage? = nil
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if isLoading {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .task {
            await loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RefreshDocumentThumbnails"))) { _ in
            // Force refresh by updating ID and reloading
            refreshID = UUID()
            Task {
                await loadThumbnail()
            }
        }
    }
    
    // ✅ OPTIMIZED: Generate thumbnail as UIImage instead of loading full PDFView
    // This is MUCH more memory-efficient for 50-100 documents
    private func loadThumbnail() async {
        isLoading = true
        
        // Check cache first (actor requires await)
        if let cached = await ThumbnailCache.shared.get(for: documentURL) {
            await MainActor.run {
                self.thumbnailImage = cached
                self.isLoading = false
            }
            return
        }
        
        // Generate thumbnail on background thread
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let pdfDoc = CGPDFDocument(documentURL as CFURL),
                  let firstPage = pdfDoc.page(at: 1) else {
                return nil
            }
            
            let pageRect = firstPage.getBoxRect(.mediaBox)
            let scale: CGFloat = 200.0 / max(pageRect.width, pageRect.height) // Target ~200pt thumbnail
            let targetSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            return renderer.image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: targetSize))
                
                context.cgContext.saveGState()
                context.cgContext.scaleBy(x: scale, y: scale)
                context.cgContext.drawPDFPage(firstPage)
                context.cgContext.restoreGState()
            }
        }.value
        
        // Cache and update UI on main thread
        if let image = image {
            await ThumbnailCache.shared.set(image, for: documentURL)
            await MainActor.run {
                self.thumbnailImage = image
                self.isLoading = false
            }
        } else {
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
}

// ✅ Simple in-memory cache for thumbnails (prevents regenerating on scroll)
// ✅ Thread-safe using actor for concurrent access
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: UIImage] = [:]
    private let maxCacheSize = 50  // Limit cache to prevent memory issues
    
    private init() {}
    
    func get(for url: URL) -> UIImage? {
        return cache[url]
    }
    
    func set(_ image: UIImage, for url: URL) {
        // Simple LRU: if cache is full, remove oldest (first) entry
        if cache.count >= maxCacheSize {
            if let firstKey = cache.keys.first {
                cache.removeValue(forKey: firstKey)
            }
        }
        cache[url] = image
    }
    
    
    func clear() {
        cache.removeAll()
    }
}

// ✅ REMOVED: PDFPageView is no longer needed - we use cached UIImage thumbnails instead
// This significantly reduces memory usage for large document collections

