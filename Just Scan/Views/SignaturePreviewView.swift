//
//  SignaturePreviewView.swift
//  Just Scan - ENHANCED
//

import SwiftUI

struct SignaturePreviewView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var signatureService = SignatureService.shared
    @State private var showDeleteAlert = false
    @State private var selectedSignatureID: UUID?
    
    let onEdit: (() -> Void)?
    
    init(onEdit: (() -> Void)? = nil) {
        self.onEdit = onEdit
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                if signatureService.signatureHistory.isEmpty {
                    if #available(iOS 17.0, *) {
                        ContentUnavailableView(
                            "No Signatures",
                            systemImage: "signature",
                            description: Text("Create a signature to get started")
                        )
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "signature")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            
                            Text("No Signatures")
                                .font(.headline)
                            
                            Text("Create a signature to get started")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(signatureService.signatureHistory) { signature in
                                SignatureCard(
                                    signature: signature,
                                    isSelected: signature.id == signatureService.currentSignatureID,
                                    onSelect: {
                                        signatureService.selectSignature(signature.id)
                                    },
                                    onDelete: {
                                        selectedSignatureID = signature.id
                                        showDeleteAlert = true
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Signatures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onEdit?()
                        }
                    } label: {
                        Label("New Signature", systemImage: "plus")
                    }
                }
            }
         
            .alert("Delete Signature?", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let id = selectedSignatureID {
                        signatureService.deleteSignature(id)
                    }
                }
            } message: {
                Text("This signature will be permanently deleted.")
            }
        }
    }
}

// MARK: - Signature Card

struct SignatureCard: View {
    let signature: SavedSignature
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(signature.name)
                        .font(.headline)
                    
                    Text(signature.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
            }
            
            Image(uiImage: signature.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .cornerRadius(8)
            
            HStack {
                Button(isSelected ? "Selected" : "Select") {
                    onSelect()
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .gray : .blue)
                .disabled(isSelected)
                
                Spacer()
                
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}
