//
//  SettingsView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    @StateObject private var documentService = DocumentService.shared
    @State private var showClearSignatureAlert = false
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) {
                        showClearSignatureAlert = true
                    } label: {
                        HStack {
                            Text("Clear Signature")
                            Spacer()
                            if signatureService.hasSignature {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .disabled(!signatureService.hasSignature)
                } header: {
                    Text("Signature")
                } footer: {
                    Text("Delete your saved signature. You can create a new one when signing documents.")
                }
                
                Section {
                    HStack {
                        Text("Total Documents")
                        Spacer()
                        Text("\(documentService.documents.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(calculateStorageSize())
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Storage")
                }
                
                Section {
                    NavigationLink {
                        TermsOfServiceView()
                    } label: {
                        HStack {
                            Text("Terms of Service")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Legal")
                }
                
                Section {
                    Link(destination: URL(string: "https://www.linkedin.com/in/johnuja")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("Follow us on LinkedIn")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
                    Button {
                        shareApp()
                    } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                            Text("Recommend Just Scan")
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
                    Link(destination: URL(string: "https://apps.apple.com/app/id\(getAppID())")!) {
                        HStack {
                            Image(systemName: "star.fill")
                            Text("Rate in App Store")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Support")
                } footer: {
                    Text("If you enjoyed our convenience, please give us a 5 star rating in the App Store ❤️")
                }
                
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Build")
                        Spacer()
                        Text("1")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Just Scan - The Sovereign Utility Scanner\nPay once, use forever. No subscriptions.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Clear Signature", isPresented: $showClearSignatureAlert) {
                Button("Clear", role: .destructive) {
                    signatureService.clearSignature()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete your saved signature?")
            }
        }
    }
    
    private func calculateStorageSize() -> String {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "Unknown"
        }
        
        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: documentsURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
    
    private func shareApp() {
        let text = "Check out Just Scan - The best document scanner app! 📄✨"
        let url = URL(string: "https://apps.apple.com/app/id\(getAppID())")!
        
        let activityVC = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityVC, animated: true)
        }
    }
    
    private func getAppID() -> String {
        // Replace with your actual App Store ID when available
        // For now, return a placeholder
        return "YOUR_APP_ID"
    }
}

