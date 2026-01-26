//
//  SettingsView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import UIKit
import StoreKit

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var signatureService = SignatureService.shared
    @StateObject private var documentService = DocumentService.shared
    @StateObject private var storeManager = StoreManager.shared
    @State private var showClearSignatureAlert = false
    @State private var showSafari = false
    @State private var safariURL: URL?
    @State private var showPaywall = false

    private let privacyPolicyURL = URL(string: "https://juvantagecloud.com/just-scan/privacy-policy")!
    private let supportURL = URL(string: "https://juvantagecloud.com/support")!
    
    var body: some View {
        NavigationStack {
            List {
                // Premium Section
                Section {
                    if storeManager.hasPurchased {
                        // Show Pro status if purchased
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Pro Unlocked")
                                .fontWeight(.semibold)
                            Spacer()
                            Text("Active")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    } else {
                        // Show unlock button if not purchased
                        Button {
                            showPaywall = true
                        } label: {
                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.cyan)
                                Text("Unlock Pro")
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Premium")
                } footer: {
                    if storeManager.hasPurchased {
                        Text("You have full access to all premium features.")
                    } else {
                        Text("Unlock unlimited scans, exports, and all premium features with a one-time purchase.")
                    }
                }
                
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

                    Button {
                        openSafari(privacyPolicyURL)
                    } label: {
                        HStack {
                            Text("Privacy Policy (Web)")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Legal")
                }
                
                Section {
                    Button {
                        openSafari(supportURL)
                    } label: {
                        HStack {
                            Image(systemName: "envelope.fill")
                            Text("Support")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    Button {
                        openContactEmail()
                    } label: {
                        HStack {
                            Image(systemName: "envelope")
                            Text("Email Support")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    
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
                    
                    Button {
                        requestReview()
                    } label: {
                        HStack {
                            Image(systemName: "star.fill")
                            Text("Consider Leaving Us a 5 Star Rating")
                            Spacer()
                            Image(systemName: "hand.thumbsup.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Support")
                }
                
                #if DEBUG
                Section {
                    Toggle(isOn: Binding(
                        get: { StoreManager.shared.isBypassEnabled },
                        set: { newValue in
                            // Just update the bypass state - don't force app restart
                            StoreManager.shared.setDeveloperBypass(newValue)
                        }
                    )) {
                        HStack {
                            Text("Enable Developer Bypass")
                            Spacer()
                            if StoreManager.shared.isBypassEnabled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    
                    Button(role: .destructive) {
                        // Reset to paywall/landing page
                        UserDefaults.standard.removeObject(forKey: "developerBypassPurchased")
                        StoreManager.shared.setDeveloperBypass(false)
                        UserDefaults.standard.set(false, forKey: "hasAcceptedTerms")
                        // Force app restart by exiting
                        exit(0)
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Return to Landing Page")
                        }
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Toggle bypass to test paywall flow. Disable bypass to see paywall when exporting.")
                }
                #endif
                
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
                    Text("Just Scan\nPay once, use forever. Users who purchase before July 30th, 2026 will be grandfathered in.")
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
            .sheet(isPresented: $showSafari) {
                if let url = safariURL {
                    SafariView(url: url)
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(context: .export)
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
    
    private func openSafari(_ url: URL) {
        safariURL = url
        showSafari = true
    }

    private func openContactEmail() {
        let email = "support@juvantage.com"
        let subject = "Just Scan Support"
        let body = "Hello,\n\n"
        
        let mailtoURLString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let mailtoURL = URL(string: mailtoURLString) {
            if UIApplication.shared.canOpenURL(mailtoURL) {
                UIApplication.shared.open(mailtoURL)
            } else {
                UIPasteboard.general.string = email
            }
        }
    }

    private func requestReview() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            SKStoreReviewController.requestReview(in: windowScene)
        }
    }
}

