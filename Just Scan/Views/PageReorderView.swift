//
//  PageReorderView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

struct PageReorderView: View {
    @Binding var pages: [UIImage] // Use binding to sync changes
    @State private var draggedItem: Int?
    @State private var selectedPageIndex: Int?
    @State private var pageToDelete: Int?
    @State private var showDeleteConfirmation = false
    let onSave: ([UIImage]) -> Void
    let onBack: () -> Void // Just notify to go back - pages are already synced via binding
    let onCancel: () -> Void // Only used if we need to fully cancel
    
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
                    Button {
                        // Go back to scanner - pages are already synced via @Binding
                        onBack()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
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
            .alert("Delete Page", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let index = pageToDelete {
                        withAnimation {
                            let _ = pages.remove(at: index)
                        }
                        // Clear selection if deleted page was selected
                        if selectedPageIndex == index {
                            selectedPageIndex = nil
                        } else if let selected = selectedPageIndex, selected > index {
                            // Adjust selection index if a page before it was deleted
                            selectedPageIndex = selected - 1
                        }
                        pageToDelete = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pageToDelete = nil
                }
            } message: {
                if let index = pageToDelete {
                    Text("Are you sure you want to delete page \(index + 1)?")
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
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            selectedPageIndex == index ? Color.yellow : Color.clear,
                                            lineWidth: selectedPageIndex == index ? 4 : 0
                                        )
                                )
                                .padding(.horizontal)
                                .onTapGesture {
                                    // Toggle selection - tap again to deselect
                                    if selectedPageIndex == index {
                                        selectedPageIndex = nil
                                    } else {
                                        selectedPageIndex = index
                                    }
                                }
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
        Text("Tap to select • Long press and drag to reorder • Tap trash to delete")
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
            isSelected: selectedPageIndex == index,
            onDelete: {
                pageToDelete = index
                showDeleteConfirmation = true
            },
            onTap: {
                // Sync selection when tapping thumbnail
                if selectedPageIndex == index {
                    selectedPageIndex = nil
                } else {
                    selectedPageIndex = index
                }
            }
        )
        .onDrag {
            draggedItem = index
            selectedPageIndex = nil // Clear selection when dragging starts
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
    let isSelected: Bool
    let onDelete: () -> Void
    let onTap: () -> Void
    
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
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .opacity(isDragging ? 0.5 : 1.0)
            .scaleEffect(isDragging ? 1.1 : 1.0)
            .onTapGesture {
                onTap()
            }
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }
    
    private var borderColor: Color {
        if isDragging {
            return .orange
        } else if isSelected {
            return .yellow
        } else {
            return .blue
        }
    }
    
    private var borderWidth: CGFloat {
        if isDragging {
            return 3
        } else if isSelected {
            return 3
        } else {
            return 2
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

