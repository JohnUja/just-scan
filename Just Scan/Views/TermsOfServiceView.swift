//
//  TermsOfServiceView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

struct TermsOfServiceView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Terms of Service")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.bottom)
                    
                    Text("Last Updated: December 16, 2025")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Group {
                        SectionView(title: "1. Acceptance of Terms", content: """
                        By downloading, installing, or using Just Scan ("the App"), you agree to be bound by these Terms of Service. If you do not agree to these terms, do not use the App.
                        """)
                        
                        SectionView(title: "2. Description of Service", content: """
                        Just Scan is a document scanning application that allows users to scan, process, and manage documents using their iOS device. The App processes all data locally on your device and does not transmit data to external servers.
                        """)
                        
                        SectionView(title: "3. One-Time Purchase", content: """
                        Just Scan is available as a one-time purchase. Upon purchase, you own the App and all its features permanently. No subscriptions or recurring charges will apply.
                        """)
                        
                        SectionView(title: "4. Privacy", content: """
                        Just Scan processes all documents locally on your device. No data is transmitted to external servers. Camera access is used solely for document scanning purposes. Please refer to our Privacy Policy for more information.
                        """)
                        
                        SectionView(title: "5. User Responsibilities", content: """
                        You are responsible for maintaining the security of your device and any documents you scan. Just Scan is not liable for any loss of data or documents.
                        """)
                        
                        SectionView(title: "6. Intellectual Property", content: """
                        All content, features, and functionality of the App are owned by Just Scan and are protected by copyright and other intellectual property laws.
                        """)
                        
                        SectionView(title: "7. Limitation of Liability", content: """
                        Just Scan is provided "as is" without warranties of any kind. We are not liable for any damages arising from your use of the App.
                        """)
                        
                        SectionView(title: "8. Changes to Terms", content: """
                        We reserve the right to modify these terms at any time. Continued use of the App after changes constitutes acceptance of the new terms.
                        """)
                        
                        SectionView(title: "9. Contact", content: """
                        For questions about these Terms, please contact us through the App Store listing or your preferred method of communication.
                        """)
                    }
                }
                .padding()
            }
            .navigationTitle("Terms of Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SectionView: View {
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(content)
                .font(.body)
                .foregroundColor(.secondary)
        }
    }
}

