//
//  PrivacyPolicyView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Privacy Policy")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.bottom)
                    
                    Text("Last Updated: December 16, 2025")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Group {
                        SectionView(title: "1. Overview", content: """
                        Just Scan ("we", "our", or "us") is committed to protecting your privacy. This Privacy Policy explains how we handle information when you use our App.
                        """)
                        
                        SectionView(title: "2. Data Collection", content: """
                        Just Scan does NOT collect, store, or transmit any personal data or documents to external servers. All document processing occurs locally on your device.
                        """)
                        
                        SectionView(title: "3. Camera Access", content: """
                        The App requires camera access to scan documents. Camera data is processed in real-time and is never stored or transmitted. Camera access is used solely for document scanning functionality.
                        """)
                        
                        SectionView(title: "4. Local Storage", content: """
                        Scanned documents are stored locally on your device in the App's sandboxed Documents folder. These files are accessible only to the App and are not shared with third parties.
                        """)
                        
                        SectionView(title: "5. No Data Transmission", content: """
                        Just Scan does not connect to external servers. No documents, images, or personal information are transmitted over the internet. All processing is performed on-device.
                        """)
                        
                        SectionView(title: "6. Third-Party Services", content: """
                        Just Scan does not integrate with third-party analytics, advertising, or data collection services. We use only Apple's native frameworks (VisionKit, Vision, PDFKit) which process data locally.
                        """)
                        
                        SectionView(title: "7. App Store", content: """
                        When you purchase the App through the App Store, Apple may collect certain information as outlined in their Privacy Policy. We do not have access to this information.
                        """)
                        
                        SectionView(title: "8. Your Rights", content: """
                        You have full control over your data. You can delete scanned documents at any time through the App. Uninstalling the App will remove all locally stored data.
                        """)
                        
                        SectionView(title: "9. Children's Privacy", content: """
                        Just Scan is not intended for children under 13. We do not knowingly collect information from children.
                        """)
                        
                        SectionView(title: "10. Changes to Privacy Policy", content: """
                        We may update this Privacy Policy from time to time. Continued use of the App after changes constitutes acceptance of the updated policy.
                        """)
                        
                        SectionView(title: "11. Contact", content: """
                        For questions about this Privacy Policy, please contact us through the App Store listing.
                        """)
                    }
                }
                .padding()
            }
            .navigationTitle("Privacy Policy")
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

