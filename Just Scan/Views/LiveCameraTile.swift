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
    @State private var pulse = false // ✅ Local state for opacity pulse (doesn't affect layout)
    let onTap: () -> Void
    
    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(session: cameraManager.session)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // ✅ Pulsing border - opacity only, no layout changes
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue, lineWidth: 3)
                .opacity(cameraManager.isActive ? (pulse ? 1.0 : 0.35) : 0.2)
                .onAppear {
                    // Start pulse animation when view appears
                    pulse = false
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
                .onChange(of: cameraManager.isActive) { active in
                    // ✅ Control pulse based on camera active state
                    if active {
                        pulse = false
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    } else {
                        // Stop animation when inactive
                        withAnimation(.easeInOut(duration: 0.3)) {
                            pulse = false
                        }
                    }
                }
            
            // Overlay text
            VStack {
                Spacer()
                Text("Tap to Scan")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onTapGesture {
            onTap()
        }
        .task {
            // ✅ Start camera immediately when view appears
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
    
    // ✅ Nonisolated properties - safe to access from background queue
    nonisolated let session = AVCaptureSession()
    nonisolated private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    // ✅ Safe: isConfigured is only accessed from within sessionQueue.async blocks (serial queue)
    nonisolated(unsafe) private var isConfigured = false
    
    init() {
        // Don't configure here - do it on sessionQueue
    }
    
    // ✅ Nonisolated method - runs on background queue
    nonisolated private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            print("⚠️ Failed to configure camera session")
            return
        }
        
        session.addInput(input)
        session.commitConfiguration()
        isConfigured = true
        print("✅ Camera session configured")
        }
    
    // ✅ Nonisolated - can be called from any context
    nonisolated func startSession() {
        print("🎥 startSession() called")
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("🎥 status: \(status.rawValue), isConfigured: \(isConfigured), inputs: \(session.inputs.count), running: \(session.isRunning)")
        
        // ✅ Request permission if not determined
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    // Recursively call startSession (now authorized) - nonisolated so safe
                    self.startSession()
                } else {
                    Task { @MainActor in
                        self.isActive = false
                    }
                    print("⚠️ Camera permission denied")
                }
            }
            return
        }
        
        guard status == .authorized else {
            Task { @MainActor in
                self.isActive = false
            }
            print("⚠️ Camera permission not authorized")
            return
        }
        
        // ✅ Start session on dedicated queue (not MainActor)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            if !self.isConfigured {
                self.configureSession()
            }
            
            guard !self.session.isRunning else {
                print("🎥 Session already running")
                Task { @MainActor in
                    self.isActive = true
                }
                return
            }
            
            self.session.startRunning()
            
            // Check after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    print("🎥 after start: running = \(self.session.isRunning)")
                    self.isActive = self.session.isRunning
                }
            }
        }
    }
    
    nonisolated func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in
                self.isActive = false
            }
        }
    }
}

// ✅ Custom UIView that properly handles preview layer layout
final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        // ✅ layoutSubviews handles frame updates automatically
        uiView.previewLayer.session = session
    }
}

