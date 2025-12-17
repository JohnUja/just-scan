//
//  SignaturePreviewView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

struct SignaturePreviewView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    @State private var showDeleteAlert = false
    let onEdit: (() -> Void)?
    
    init(onEdit: (() -> Void)? = nil) {
        self.onEdit = onEdit
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 30) {
                    if let signature = signatureService.signatureImage {
                        Image(uiImage: signature)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 300, maxHeight: 150)
                            .background(Color.white)
                            .cornerRadius(12)
                            .padding()
                    } else {
                        Text("No signature saved")
                            .foregroundColor(.secondary)
                    }
                    
                    // Removed buttons - just preview
                }
            }
            .navigationTitle("Signature Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") {
                        dismiss()
                    }
                }
            }
        }
    }
}

