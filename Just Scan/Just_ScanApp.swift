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
    
    var body: some Scene {
        WindowGroup {
            if storeManager.hasPurchased {
                ContentView()
                    .preferredColorScheme(.dark) // Force dark mode
            } else if !hasAcceptedTerms {
                TermsAcceptanceView {
                    hasAcceptedTerms = true
                }
                .preferredColorScheme(.dark)
            } else {
                PaywallView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
