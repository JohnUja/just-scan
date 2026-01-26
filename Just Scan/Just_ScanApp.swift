//
//  Just_ScanApp.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

@main
struct Just_ScanApp: App {
    @StateObject private var storeManager = StoreManager.shared
    @State private var hasAcceptedTerms = UserDefaults.standard.bool(forKey: "hasAcceptedTerms")
    @State private var hasEnteredApp = false  // ✅ Track if user entered app from landing
    
    var body: some Scene {
        WindowGroup {
            if storeManager.hasPurchased || hasEnteredApp {
                // ✅ Show app if purchased OR user clicked Continue on landing
            ContentView()
                    .preferredColorScheme(.dark) // Force dark mode
            } else if !hasAcceptedTerms {
                TermsAcceptanceView {
                    hasAcceptedTerms = true
                }
                .preferredColorScheme(.dark)
            } else {
                PaywallView(context: .landing, onContinue: {
                    // ✅ Landing Continue: Always allow entry (no purchase required)
                    hasEnteredApp = true
                })
                    .preferredColorScheme(.dark)
            }
        }
    }
}
