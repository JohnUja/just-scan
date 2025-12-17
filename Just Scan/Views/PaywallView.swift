//
//  PaywallView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var storeManager = StoreManager.shared
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var developerTapCount = 0
    @State private var showDeveloperBypass = false
    
    // DEVELOPER BYPASS: Set to false before App Store release
    private let developerBypassEnabled = true
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 30) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                            .onTapGesture {
                                if developerBypassEnabled {
                                    developerTapCount += 1
                                    if developerTapCount >= 5 {
                                        showDeveloperBypass = true
                                        developerTapCount = 0
                                    }
                                }
                            }
                        
                        Text("Just Scan")
                            .font(.system(size: 36, weight: .bold))
                        
                        Text("The Sovereign Utility Scanner")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                    
                    // Features
                    VStack(alignment: .leading, spacing: 20) {
                        FeatureRow(icon: "camera.fill", title: "Instant Scanning", description: "Live camera preview with auto-detect")
                        FeatureRow(icon: "doc.on.doc", title: "Multi-Page Support", description: "Scan multiple pages in one session")
                        FeatureRow(icon: "slider.horizontal.3", title: "Smart Filters", description: "B&W, Grayscale, and Color modes")
                        FeatureRow(icon: "signature", title: "Digital Signatures", description: "Add signatures to any document")
                        FeatureRow(icon: "text.viewfinder", title: "OCR Text Extraction", description: "Extract text from scanned documents")
                        FeatureRow(icon: "lock.shield.fill", title: "100% Private", description: "All processing happens on your device")
                    }
                    .padding(.horizontal)
                    
                    // Pricing
                    VStack(spacing: 12) {
                        Text("Own Forever")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("$7.99")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.blue)
                        
                        Text("One-time purchase")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        // Limited time offer
                        HStack {
                            Image(systemName: "clock.fill")
                                .foregroundColor(.orange)
                            Text("Special offer runs until July 2026")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                    .background(Color(white: 0.1))
                    .cornerRadius(16)
                    .padding(.horizontal)
                    
                    // Purchase Button
                    Button {
                        purchase()
                    } label: {
                        HStack {
                            if isPurchasing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Purchase & Own Forever")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isPurchasing ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(isPurchasing)
                    .padding(.horizontal)
                    
                    // Restore Purchases
                    Button {
                        restorePurchases()
                    } label: {
                        Text("Restore Purchases")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 20)
                    
                    // Developer Bypass (Hidden - tap logo 5 times)
                    if showDeveloperBypass && developerBypassEnabled {
                        Button {
                            bypassPurchase()
                        } label: {
                            Text("🔧 Developer Bypass")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.orange)
                                .cornerRadius(12)
                        }
                        .padding(.bottom, 10)
                    }
                    
                    // Debug: Show tap count for testing
                    if developerBypassEnabled {
                        Text("Tap logo 5 times for bypass (taps: \(developerTapCount))")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .padding(.bottom, 10)
                    }
                }
            }
        }
        .alert("Purchase Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            storeManager.loadProducts()
        }
    }
    
    private func purchase() {
        isPurchasing = true
        storeManager.purchaseProduct { success, error in
            isPurchasing = false
            if success {
                dismiss()
            } else if let error = error {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
    
    private func restorePurchases() {
        isPurchasing = true
        storeManager.restorePurchases { success in
            isPurchasing = false
            if success {
                dismiss()
            } else {
                errorMessage = "No previous purchases found."
                showError = true
            }
        }
    }
    
    // DEVELOPER BYPASS: Remove this function before App Store release
    private func bypassPurchase() {
        storeManager.setDeveloperBypass(true)
        // Force update the published property to trigger view refresh
        storeManager.objectWillChange.send()
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

