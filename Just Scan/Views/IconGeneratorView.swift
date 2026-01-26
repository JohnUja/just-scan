//
//  IconGeneratorView.swift
//  Just Scan
//
//  Icon Generator - Exports AppIconView to 1024x1024 image
//

import SwiftUI
import Photos
import PhotosUI

@MainActor
struct IconGeneratorView: View {
    @State private var status = "Ready to Export"
    @State private var showPermissionAlert = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Icon Preview")
                .font(.headline)
                .foregroundColor(.white)
            
            // Preview (scaled down for display)
            AppIconView(size: 256)
                .cornerRadius(40)
                .shadow(radius: 10)
            
            Text(status)
                .foregroundColor(.gray)
                .padding(.horizontal)
                .multilineTextAlignment(.center)
            
            Button("Save 1024x1024 Icon to Photos") {
                Task { @MainActor in
                    await requestPermissionAndSave()
                }
            }
            .buttonStyle(.borderedProminent)
            .padding()
            
            Text("After saving, AirDrop to Mac and add to Assets.xcassets")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
                .padding(.horizontal)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .alert("Photos Permission Required", isPresented: $showPermissionAlert) {
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please allow photo library access to save the icon.")
        }
    }
    
    private func requestPermissionAndSave() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        
        switch status {
        case .authorized, .limited:
            await renderAndSave()
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if newStatus == .authorized || newStatus == .limited {
                await renderAndSave()
            } else {
                showPermissionAlert = true
            }
        default:
            showPermissionAlert = true
        }
    }
    
    private func renderAndSave() async {
        status = "Rendering..."
        
        // Create renderer for exact App Store size
        let renderer = ImageRenderer(content: 
            AppIconView(size: 1024)
                .background(Color.black)
        )
        
        // Set scale to 1.0 for pixel-perfect 1024x1024 output
        renderer.scale = 1.0
        
        guard let uiImage = renderer.uiImage else {
            status = "❌ Error rendering image"
            return
        }
        
        // Extract image data to pass to background task (avoids actor isolation issues)
        guard let imageData = uiImage.pngData() else {
            status = "❌ Error converting image"
            return
        }
        
        // Run Photos operation in detached task (completely off MainActor)
        let saved = await Task.detached { () -> Bool in
            guard let image = UIImage(data: imageData) else {
                return false
            }
            
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }) { success, _ in
                    continuation.resume(returning: success)
                }
            }
        }.value
        
        if saved {
            status = "✅ Saved! Check your Photos app."
        } else {
            status = "❌ Failed to save image"
        }
    }
}

