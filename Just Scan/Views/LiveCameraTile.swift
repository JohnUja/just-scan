//
//  LiveCameraTile.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import SwiftUI
@preconcurrency import AVFoundation

struct LiveCameraTile: View {
    @StateObject private var cameraManager = CameraManager()
    @Environment(\.scenePhase) var scenePhase
    let onTap: () -> Void
    
    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(session: cameraManager.session)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Pulsing border
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue, lineWidth: 3)
                .opacity(cameraManager.isActive ? 1.0 : 0.3)
                .animation(
                    Animation.easeInOut(duration: 1.5)
                        .repeatForever(autoreverses: true),
                    value: cameraManager.isActive
                )
            
            // Overlay text
            VStack {
                Spacer()
                Text("Tap to Scan")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.bottom, 8)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onTapGesture {
            onTap()
        }
        .onAppear {
            cameraManager.startSession()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background || newPhase == .inactive {
                cameraManager.stopSession()
            } else if newPhase == .active {
                cameraManager.startSession()
            }
        }
    }
}

@MainActor
class CameraManager: ObservableObject {
    @Published var isActive = false
    let session = AVCaptureSession()
    private var videoInput: AVCaptureDeviceInput?
    
    init() {
        setupCamera()
    }
    
    private func setupCamera() {
        session.sessionPreset = .photo
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        
        videoInput = input
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
    }
    
    func startSession() {
        guard !session.isRunning else { return }
        let sessionRef = session
        DispatchQueue.global(qos: .userInitiated).async {
            sessionRef.startRunning()
            DispatchQueue.main.async { [weak self] in
                self?.isActive = true
            }
        }
    }
    
    func stopSession() {
        guard session.isRunning else { return }
        let sessionRef = session
        DispatchQueue.global(qos: .userInitiated).async {
            sessionRef.stopRunning()
            DispatchQueue.main.async { [weak self] in
                self?.isActive = false
            }
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = context.coordinator.previewLayer {
            previewLayer.frame = uiView.bounds
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

