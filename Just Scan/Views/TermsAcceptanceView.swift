//
//  TermsAcceptanceView.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI

struct TermsAcceptanceView: View {
    @State private var hasAcceptedTerms = false
    @State private var showTerms = false
    @State private var showPrivacy = false
    
    let onAccept: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                // App Icon/Logo
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("Welcome to Just Scan")
                    .font(.system(size: 28, weight: .bold))
                
                Text("The Sovereign Utility Scanner")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Terms Checkbox
                VStack(spacing: 20) {
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            hasAcceptedTerms.toggle()
                        } label: {
                            Image(systemName: hasAcceptedTerms ? "checkmark.square.fill" : "square")
                                .font(.title2)
                                .foregroundColor(hasAcceptedTerms ? .blue : .gray)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("I agree to the")
                                .font(.body)
                            
                            HStack(spacing: 4) {
                                Button {
                                    showTerms = true
                                } label: {
                                    Text("Terms of Service")
                                        .underline()
                                        .foregroundColor(.blue)
                                }
                                
                                Text("and")
                                    .foregroundColor(.secondary)
                                
                                Button {
                                    showPrivacy = true
                                } label: {
                                    Text("Privacy Policy")
                                        .underline()
                                        .foregroundColor(.blue)
                                }
                            }
                            .font(.body)
                        }
                    }
                    .padding()
                    .background(Color(white: 0.1))
                    .cornerRadius(12)
                    
                    // Continue Button
                    Button {
                        if hasAcceptedTerms {
                            UserDefaults.standard.set(true, forKey: "hasAcceptedTerms")
                            onAccept()
                        }
                    } label: {
                        Text("Agree and Continue")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(hasAcceptedTerms ? Color.blue : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(!hasAcceptedTerms)
                }
                .padding(.horizontal, 40)
                
                Spacer()
            }
        }
        .sheet(isPresented: $showTerms) {
            TermsOfServiceView()
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacyPolicyView()
        }
    }
}

