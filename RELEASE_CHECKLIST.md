# Release Checklist - Remove Developer Bypass

## Before App Store Release:

### 1. Remove Developer Bypass from PaywallView.swift
**File:** `Just Scan/Views/PaywallView.swift`
- Line ~15: Change `private let developerBypassEnabled = true` to `false`
- Remove or comment out the `bypassPurchase()` function (line ~120)
- Remove the developer bypass button UI code

### 2. Remove Developer Bypass from StoreManager.swift
**File:** `Just Scan/Services/StoreManager.swift`
- Remove the `developerBypass` computed property (lines ~20-28)
- Remove `setDeveloperBypass()` function
- Update `hasPurchased` to only check `purchasedProductIDs.contains(productID)`

### 3. Test Purchase Flow
- Test with Sandbox Apple ID
- Verify Terms & Conditions screen appears first
- Verify Paywall appears after accepting terms
- Verify purchase flow works correctly
- Verify restore purchases works

### 4. App Store Connect Setup
- Create Non-Consumable product with ID: `com.justscan.onetime`
- Set price to $7.99
- Update product ID in StoreManager.swift if different

---

**Note:** The developer bypass is currently enabled for testing. Remember to disable it before submitting to the App Store!

