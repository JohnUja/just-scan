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
    
    private let productID = "com.justscan.onetime" // You'll need to create this in App Store Connect
    
    // DEVELOPER BYPASS: Set to false before App Store release
    private var developerBypass: Bool {
        get {
            UserDefaults.standard.bool(forKey: "developerBypassPurchased")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "developerBypassPurchased")
        }
    }
    
    private init() {
        Task {
            await loadPurchasedProducts()
        }
    }
    
    var hasPurchased: Bool {
        developerBypass || purchasedProductIDs.contains(productID)
    }
    
    func setDeveloperBypass(_ enabled: Bool) {
        developerBypass = enabled
        // Trigger view update
        objectWillChange.send()
    }
    
    func loadProducts() {
        Task {
            do {
                let products = try await Product.products(for: [productID])
                self.products = products
            } catch {
                print("Failed to load products: \(error)")
            }
        }
    }
    
    func purchaseProduct(completion: @escaping (Bool, Error?) -> Void) {
        guard let product = products.first else {
            completion(false, NSError(domain: "StoreManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Product not available"]))
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
                        completion(true, nil)
                    case .unverified(_, let error):
                        completion(false, error)
                    }
                case .userCancelled:
                    completion(false, NSError(domain: "StoreManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Purchase cancelled"]))
                case .pending:
                    completion(false, NSError(domain: "StoreManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Purchase pending"]))
                @unknown default:
                    completion(false, NSError(domain: "StoreManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unknown purchase result"]))
                }
            } catch {
                completion(false, error)
            }
        }
    }
    
    func restorePurchases(completion: @escaping (Bool) -> Void) {
        Task {
            do {
                try await AppStore.sync()
                await loadPurchasedProducts()
                completion(hasPurchased)
            } catch {
                print("Failed to restore purchases: \(error)")
                completion(false)
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

