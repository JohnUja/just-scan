import SwiftUI
import StoreKit

enum PaywallContext {
    case landing  // First launch
    case export   // When trying to export/share
}

struct PaywallView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeManager = StoreManager.shared
    
    let context: PaywallContext
    let onContinue: (() -> Void)?  // ✅ For landing: allows entry without purchase
    
    @State private var isPurchasing = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showTerms = false
    @State private var isLoadingProducts = false

    @State private var developerTapCount = 0
    @State private var showDeveloperBypass = false
    @State private var showScanAnimation = false
    @State private var glowOpacity: Double = 0.5
    @State private var glowAnimationStarted = false
    
    #if DEBUG
    private let developerBypassEnabled = true
    #else
    private let developerBypassEnabled = false
    #endif
    
    init(context: PaywallContext = .landing, onContinue: (() -> Void)? = nil) {
        self.context = context
        self.onContinue = onContinue
    }

    private let electricBlue = Color(red: 0.0, green: 0.7, blue: 1.0)
    private let brightCyan = Color.cyan
    private let iconGradient = LinearGradient(
        colors: [.cyan, .blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    var body: some View {
        GeometryReader { geometry in
            let isIPad = geometry.size.width > 600 // Detect iPad
            let topSpacing: CGFloat = isIPad ? 60 : 10 // Reduced spacing
            let contentSpacing: CGFloat = isIPad ? 20 : 10 // Reduced spacing between sections
            let bottomSpacing: CGFloat = isIPad ? 60 : 20 // Reduced bottom spacing
            
            ScrollView {
                VStack(spacing: 0) {
                    // Top spacer - pushes content down on iPad
                    Color.clear
                        .frame(height: topSpacing)

                    // MARK: Header (stays at top)
                    VStack(spacing: 8) {
                        ZStack {
                            Image(systemName: "doc")
                                .font(.system(size: 50, weight: .light))
                                .foregroundStyle(iconGradient)
                                .shadow(color: electricBlue.opacity(0.5), radius: 15)
                            #if DEBUG
                                .onTapGesture {
                                    if developerBypassEnabled {
                                        developerTapCount += 1
                                        if developerTapCount >= 5 {
                                            showDeveloperBypass = true
                                            developerTapCount = 0
                                        }
                                    }
                                }
                            #endif
                        
                            Rectangle()
                                .fill(brightCyan)
                                .frame(width: 70, height: 2)
                                .shadow(color: brightCyan, radius: 6)
                                .offset(y: showScanAnimation ? 25 : -25)
                                .onAppear {
                                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: true)) {
                                        showScanAnimation = true
                                    }
                                }
                        }
                        .frame(height: 60)
                        
                        Text("Just Scan")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("The Only Scanner App You Need")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    // ✅ Spacer to push everything below down to bottom on iPad
                    if isIPad {
                        Spacer()
                            .frame(minHeight: 40) // Reduced spacing
                    } else {
                        Color.clear
                            .frame(height: 8)
                    }
                    
                    // Everything after "The Only Scanner App You Need" - pushed down on iPad
                    VStack(spacing: contentSpacing) {
                        // MARK: Feature Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            FeatureCard(icon: "doc.on.doc", title: "Unlimited Scans", subtitle: "Scan & export unlimited")
                            FeatureCard(icon: "text.viewfinder", title: "OCR Text", subtitle: "Extract text instantly")
                            FeatureCard(icon: "signature", title: "Sign PDFs", subtitle: "Add your signature")
                            FeatureCard(icon: "lock.shield", title: "100% Private", subtitle: "On-device processing")
                            FeatureCard(icon: "wand.and.stars", title: "HD Filters", subtitle: "Pro-grade results")
                            FeatureCard(icon: "checkmark.shield", title: "No Watermarks", subtitle: "Clean documents always")
                        }

                        // MARK: Pricing
                        VStack(spacing: 10) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Competitors").font(.caption).foregroundColor(.gray)
                                    Text("Adobe Scan $24.99/yr").strikethrough().foregroundColor(.red).font(.caption)
                                    Text("Scanner Pro $17.99/mo").strikethrough().foregroundColor(.red).font(.caption)
                                    Text("Swift Scan $79.99/yr").strikethrough().foregroundColor(.red).font(.caption)
                                }

                                Spacer()

                                VStack(alignment: .trailing) {
                                    Text("Just Scan").font(.caption).foregroundColor(brightCyan)
                                    if let product = storeManager.products.first {
                                        Text("\(product.displayPrice) Once").font(.title2).bold().foregroundColor(.white)
                                    } else {
                                        Text("Loading...").font(.title2).bold().foregroundColor(.white)
                                    }
                                }
                            }

                        HStack {
                            Image(systemName: "clock.fill").foregroundColor(.orange)
                            Text("Offer valid till July 30th 2026").foregroundColor(.orange).font(.caption)
                        }
                        
                        // Terms and Conditions link
                        Button {
                            showTerms = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("Terms and Conditions apply")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        }
                        .padding(12)
                        .background(Color(white: 0.1))
                        .cornerRadius(12)
                        
                        // MARK: Clarifying Text
                        if context == .landing {
                            Text("Try all features free. Export requires Pro.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 4)
                        } else {
                            // Export context: Make it clear purchase is required
                            Text("Purchase required to export documents.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 4)
                        }
                        
                        // MARK: Action Buttons
                        if context == .landing {
                            // Primary: Continue Free button
                        Button {
                                onContinue?()
                            } label: {
                                Text("Continue Free")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(white: 0.2))
                                    .cornerRadius(12)
                            }
                            
                            // Secondary: Unlock Pro button (optional purchase)
                            Button {
                                attemptPurchase()
                            } label: {
                                HStack {
                                    if isPurchasing {
                                        ProgressView().tint(.black)
                                        Text("Processing...")
                                    } else if !storeManager.productsLoaded || isLoadingProducts {
                                        ProgressView().tint(.black)
                                        Text("Loading...")
                                    } else {
                                        Image(systemName: "lock.open.fill")
                                        if let product = storeManager.products.first {
                                            Text("Unlock Pro - \(product.displayPrice)")
                                        } else {
                                            Text("Unlock Pro")
                                        }
                                    }
                                }
                                .font(.headline)
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.white)
                                .cornerRadius(12)
                            }
                            .disabled(isPurchasing || isLoadingProducts)
                            .opacity((isPurchasing || isLoadingProducts) ? 0.5 : 1.0)
                            
                            // Show helpful message if products aren't loading
                            if !storeManager.productsLoaded && !isLoadingProducts {
                                VStack(spacing: 8) {
                                    Text("Connecting to App Store...")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Button("Retry") {
                                        loadProductsIfNeeded()
                                    }
                                    .font(.caption)
                                    .foregroundColor(.cyan)
                                }
                                .padding(.top, 4)
                            }
                            } else {
                            // Export context: ONLY "Unlock Export" button - NO "Continue" button
                            // Purchase is REQUIRED - no free entry option at export
                            Button {
                                if storeManager.hasPurchased {
                                    dismiss()
                                } else {
                                    attemptPurchase()
                            }
                        } label: {
                            HStack {
                                if isPurchasing {
                                    ProgressView().tint(.black)
                                        Text("Processing...")
                                    } else if !storeManager.productsLoaded || isLoadingProducts {
                                    ProgressView().tint(.black)
                                    Text("Loading...")
                                    } else {
                                        Image(systemName: "lock.open.fill")
                                        if let product = storeManager.products.first {
                                            Text("Unlock Export - \(product.displayPrice)")
                                        } else {
                                            Text("Unlock Export")
                                    }
                                }
                            }
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.white)
                            .cornerRadius(16)
                        }
                            .disabled(!storeManager.productsLoaded || isPurchasing || isLoadingProducts)
                            .opacity((!storeManager.productsLoaded || isPurchasing || isLoadingProducts) ? 0.5 : 1.0)
                        
                        // Show helpful message if products aren't loading
                            if !storeManager.productsLoaded {
                            VStack(spacing: 8) {
                                    Text("Connecting to App Store...")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Button("Retry") {
                                        loadProductsIfNeeded()
                                }
                                .font(.caption)
                                .foregroundColor(.cyan)
                            }
                            .padding(.top, 4)
                            }
                        }

                        Text("One-time purchase. No subscriptions.")
                            .font(.caption)
                            .foregroundColor(.gray)

                        Button("Restore Purchases") {
                            restorePurchases()
                        }
                        .foregroundColor(.secondary)

                            #if DEBUG
                            // Developer bypass only available on landing page, NOT export
                            if showDeveloperBypass && developerBypassEnabled && context == .landing {
                                Button("🔧 Developer Bypass") {
                                    bypassPurchase()
                                }
                                .padding()
                                .background(Color.orange)
                                .cornerRadius(12)
                            }
                            #endif
                    }
                    // Bottom padding
                    Color.clear
                        .frame(height: bottomSpacing)
                }
            }
            .scrollIndicators(.hidden)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .background(backgroundGlow.ignoresSafeArea())
        .onAppear {
            // Initialize glow animation once when view appears
            if !glowAnimationStarted {
                glowAnimationStarted = true
                withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                    glowOpacity = 1.0
                }
            }
        }
        .alert("Purchase Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showTerms) {
            TermsOfServiceView()
        }
        .onAppear {
            // Load products for both contexts now (landing needs it for "Unlock Pro" button)
            if context == .landing || context == .export {
                loadProductsIfNeeded()
            }
        }
        .onChange(of: storeManager.productsLoaded) { loaded in
            // When products finish loading, stop loading indicator
            if loaded {
                isLoadingProducts = false
            }
        }
    }
    
    private func loadProductsIfNeeded() {
        guard !storeManager.productsLoaded && !isLoadingProducts else { return }
        isLoadingProducts = true
        
        Task { @MainActor in
            defer { isLoadingProducts = false }
            do {
                try await storeManager.loadProducts()
            } catch {
                print("❌ Failed to load products: \(error.localizedDescription)")
            }
        }
    }
    
    private func attemptPurchase() {
        Task { @MainActor in
            isPurchasing = true
            
            do {
                if !storeManager.productsLoaded {
                    try await storeManager.loadProducts()
                }
                
                guard storeManager.products.first != nil else {
                    isPurchasing = false
                    errorMessage = "Product not available. Please try again."
                    showError = true
                    return
                }
                
                // purchase() will manage isPurchasing for the actual purchase flow
                purchase() // purchase() calls storeManager.purchaseProduct(...)
            } catch {
                isPurchasing = false
                errorMessage = "Unable to connect to the App Store. Please try again."
                showError = true
            }
        }
    }
    
    private func purchase() {
        guard storeManager.productsLoaded else {
            isPurchasing = false
            errorMessage = "Store not ready yet. Please wait and try again."
            showError = true
            return
        }
        
        guard !storeManager.products.isEmpty else {
            isPurchasing = false
            errorMessage = "Product not available. Please try again later."
            showError = true
            return
        }
        
        // isPurchasing is already true from attemptPurchase()
        storeManager.purchaseProduct { success, error in
            self.isPurchasing = false
            if success {
                dismiss()
            } else {
                if let error = error as NSError?, error.code == -2 {
                    return // user cancelled
                }
                errorMessage = error?.localizedDescription ?? "Purchase failed. Please try again."
                showError = true
            }
        }
    }
    
    private func restorePurchases() {
        storeManager.restorePurchases { success in
            if success { dismiss() }
        }
    }

    private func bypassPurchase() {
        storeManager.setDeveloperBypass(true)
        dismiss()
    }

    private var backgroundGlow: some View {
        ZStack {
            Circle()
                .fill(electricBlue.opacity(glowOpacity * 0.4))
                .frame(width: 500, height: 500)
                .blur(radius: 120)

            Circle()
                .fill(brightCyan.opacity(0.15))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: 150, y: -200)
        }
        .allowsHitTesting(false)
    }
}

struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.white)
                .padding(6)
                .background(
                    Circle()
                        .fill(LinearGradient(colors: [.cyan.opacity(0.4), .blue.opacity(0.2)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundColor(.white)
                Text(subtitle).font(.caption2).foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(white: 0.08))
        .cornerRadius(12)
    }
}
