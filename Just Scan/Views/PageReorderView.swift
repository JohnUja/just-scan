//
//  PageReorderView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

struct PageReorderView: View {
    @State var pages: [UIImage]
    @State private var draggedItem: Int?
    let onSave: ([UIImage]) -> Void
    let onCancel: () -> Void
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                mainContent
            }
            .navigationTitle("Review Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(pages)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            previewArea
            thumbnailTray
        }
    }
    
    private var previewArea: some View {
        Group {
            if pages.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("No pages to review")
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                            Image(uiImage: page)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 400)
                                .cornerRadius(12)
                                .shadow(radius: 5)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
    }
    
    private var thumbnailTray: some View {
        VStack(spacing: 12) {
            trayHeader
            thumbnailScrollView
        }
        .frame(height: 140)
        .background(Color.black.opacity(0.2))
    }
    
    private var trayHeader: some View {
        Text("Long press and drag to reorder • Tap trash to delete")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }
    
    private var thumbnailScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    thumbnailItem(for: page, at: index)
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func thumbnailItem(for page: UIImage, at index: Int) -> some View {
        ThumbnailItemView(
            page: page,
            index: index,
            isDragging: draggedItem == index,
            onDelete: {
                withAnimation {
                    let _ = pages.remove(at: index)
                }
            }
        )
        .onDrag {
            draggedItem = index
            return NSItemProvider(object: "\(index)" as NSString)
        }
        .onDrop(of: [.text], delegate: DragRelocateDelegate(
            item: index,
            listData: $pages,
            current: $draggedItem
        ))
    }
}

struct ThumbnailItemView: View {
    let page: UIImage
    let index: Int
    let isDragging: Bool
    let onDelete: () -> Void
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Image(uiImage: page)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 100)
                    .cornerRadius(8)
                
                VStack {
                    HStack {
                        Spacer()
                        Text("\(index + 1)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .padding(4)
                    }
                    Spacer()
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDragging ? Color.orange : Color.blue, lineWidth: isDragging ? 3 : 2)
            )
            .opacity(isDragging ? 0.5 : 1.0)
            .scaleEffect(isDragging ? 1.1 : 1.0)
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }
}

struct DragRelocateDelegate: DropDelegate {
    let item: Int
    @Binding var listData: [UIImage]
    @Binding var current: Int?
    
    func performDrop(info: DropInfo) -> Bool {
        current = nil
        return true
    }
    
    func dropEntered(info: DropInfo) {
        if item != current {
            let from = current ?? 0
            let to = item
            if from != to {
                withAnimation {
                    listData.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                }
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

