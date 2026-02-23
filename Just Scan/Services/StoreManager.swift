//
//  StoreManager.swift
//  Just Scan
//
//  Created by John Uja on 2025-12-16.
//

import Foundation
import StoreKit

@MainActor
class StoreManager: ObservableObject {
    static let shared = StoreManager()
    
    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []
    @Published private(set) var productsLoaded = false
    
    private let productID = "com.justscan.unlock" // You'll need to create this in App Store Connect
    
    #if DEBUG
    // DEVELOPER BYPASS (Debug only)
    private var developerBypass: Bool {
        get {
            UserDefaults.standard.bool(forKey: "developerBypassPurchased")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "developerBypassPurchased")
            // Trigger view update when bypass changes
            objectWillChange.send()
        }
    }
    #endif
    
    private init() {
        Task {
            await loadPurchasedProducts()
            // Start listening for transaction updates (catches purchases from other devices, network issues, etc.)
            await listenForTransactions()
        }
    }
    
    // Listen for transaction updates (StoreKit 2 best practice)
    // Catches purchases that might happen outside the normal purchase flow
    private func listenForTransactions() async {
        for await result in Transaction.updates {
            switch result {
            case .verified(let transaction):
                // Only handle our product
                if transaction.productID == productID {
                    await transaction.finish()
                    // Reload purchased products to update UI
                    await loadPurchasedProducts()
                    print("✅ Transaction update received and processed: \(transaction.productID)")
                } else {
                    // Not our product, but still finish it
                    await transaction.finish()
                }
            case .unverified(_, let error):
                print("⚠️ Unverified transaction update: \(error.localizedDescription)")
                // Don't finish unverified transactions
            }
        }
    }
    
    var hasPurchased: Bool {
        #if DEBUG
        return developerBypass || purchasedProductIDs.contains(productID)
        #else
        return purchasedProductIDs.contains(productID)
        #endif
    }
    
    // Expose bypass state for testing UI
    var isBypassEnabled: Bool {
        #if DEBUG
        return developerBypass
        #else
        return false
        #endif
    }
    
    #if DEBUG
    func setDeveloperBypass(_ enabled: Bool) {
        developerBypass = enabled
        // Trigger view update
        objectWillChange.send()
    }
    #else
    func setDeveloperBypass(_ enabled: Bool) {
        // No-op in Release builds
    }
    #endif
    
    func loadProducts() async throws {
        print("🛒 Loading products with ID: \(productID)")
        let products = try await Product.products(for: [productID])
        print("🛒 Loaded \(products.count) products")
        
        if products.isEmpty {
            print("⚠️ WARNING: No products found! Make sure '\(productID)' exists in App Store Connect")
        } else {
            print("✅ Product found: \(products.first?.displayName ?? "Unknown") - \(products.first?.displayPrice ?? "No price")")
        }
        
        self.products = products
        self.productsLoaded = !products.isEmpty
    }
    
    func purchaseProduct(completion: @escaping (Bool, Error?) -> Void) {
        guard let product = products.first else {
            Task { @MainActor in
                completion(false, NSError(domain: "StoreManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Product not available"]))
            }
            return
        }
        
        Task {
            do {
                let result = try await product.purchase()
                
                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        await transaction.finish()
                        await loadPurchasedProducts()
                        await MainActor.run {
                            completion(true, nil)
                        }
                    case .unverified(_, let error):
                        await MainActor.run {
                            completion(false, error)
                        }
                    }
                case .userCancelled:
                    await MainActor.run {
                        completion(false, NSError(domain: "StoreManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Purchase cancelled"]))
                    }
                case .pending:
                    await MainActor.run {
                        completion(false, NSError(domain: "StoreManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Purchase pending"]))
                    }
                @unknown default:
                    await MainActor.run {
                        completion(false, NSError(domain: "StoreManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unknown purchase result"]))
                    }
                }
            } catch {
                await MainActor.run {
                    completion(false, error)
                }
            }
        }
    }
    
    func restorePurchases(completion: @escaping (Bool) -> Void) {
        Task {
            do {
                try await AppStore.sync()
                await loadPurchasedProducts()
                await MainActor.run {
                    completion(hasPurchased)
                }
            } catch {
                print("Failed to restore purchases: \(error)")
                await MainActor.run {
                    completion(false)
                }
            }
        }
    }
    
    private func loadPurchasedProducts() async {
        var purchasedIDs: Set<String> = []
        
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                if transaction.productID == productID {
                    purchasedIDs.insert(transaction.productID)
                }
            case .unverified:
                break
            }
        }
        
        purchasedProductIDs = purchasedIDs
    }
}

