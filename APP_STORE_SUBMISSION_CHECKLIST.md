# App Store Submission Checklist - Just Scan

## ✅ Pre-Submission Checklist

### 1. Code Changes Completed
- [x] **Zoom Disabled** - PDFView locked to fit-to-screen, pinch gestures disabled
- [x] **Developer Bypass Removed** - PaywallView and StoreManager cleaned up
- [x] **Harmony Architecture** - Single master function for all signature operations
- [x] **Visual Styling** - Clean blue selection boxes, no white outlines

### 2. Privacy & Permissions
- [x] **Camera Permission** - `NSCameraUsageDescription` configured in project.pbxproj
  - Description: "Just Scan uses your camera to scan documents. All processing happens on your device. No data is sent to external servers."
- [x] **Photo Library** - Not needed (app uses VNDocumentCameraViewController)
- [x] **Privacy Policy** - Exists at `Just Scan/Views/PrivacyPolicyView.swift`

### 3. App Store Connect Setup

#### Product Configuration
- [ ] Create Non-Consumable In-App Purchase in App Store Connect
  - **Product ID:** `com.justscan.onetime`
  - **Price:** $7.99
  - **Type:** Non-Consumable
  - **Localization:** Add description in all supported languages

#### App Information
- [ ] **App Name:** Just Scan
- [ ] **Subtitle:** The Sovereign Utility Scanner
- [ ] **Category:** Productivity / Utilities
- [ ] **Age Rating:** 4+ (no objectionable content)
- [ ] **Privacy Policy URL:** Required (host your privacy policy online)

#### Screenshots Required
- [ ] iPhone 6.7" (iPhone 14 Pro Max, 15 Pro Max) - 1290 x 2796
- [ ] iPhone 6.5" (iPhone 11 Pro Max, XS Max) - 1242 x 2688
- [ ] iPhone 5.5" (iPhone 8 Plus) - 1242 x 2208
- [ ] iPad Pro 12.9" - 2048 x 2732
- [ ] iPad Pro 11" - 1668 x 2388

#### App Preview Video (Optional but Recommended)
- [ ] 15-30 second video showing:
  - Document scanning
  - Signature placement
  - OCR text extraction
  - Multi-page support

### 4. Build Configuration

#### Version & Build Numbers
- [ ] **Marketing Version:** 1.0 (already set)
- [ ] **Build Number:** Increment for each submission (1, 2, 3...)
- [ ] **Bundle Identifier:** `JIT.Just-Scan` (verify in project.pbxproj)

#### Signing & Capabilities
- [ ] **Development Team:** BWC2VJDMH9 (verify this is correct)
- [ ] **Code Signing:** Automatic (verify it's set correctly)
- [ ] **App Store Distribution Certificate:** Required
- [ ] **Provisioning Profile:** App Store profile

### 5. App Store Metadata

#### Description (4000 char limit)
```
Just Scan - The Sovereign Utility Scanner

Transform your iPhone into a powerful document scanner with complete privacy.

KEY FEATURES:
• Instant Document Scanning - Live camera preview with auto-detect
• Multi-Page Support - Scan multiple pages in one session
• Smart Filters - B&W, Grayscale, and Color modes
• Digital Signatures - Add signatures to any document
• OCR Text Extraction - Extract text from scanned documents
• 100% Private - All processing happens on your device

Perfect for:
- Business professionals
- Students
- Anyone who needs to digitize documents

No subscriptions. Own forever. One-time purchase.
```

#### Keywords (100 char limit)
```
scanner, document, PDF, signature, OCR, scan, document scanner, PDF scanner
```

#### Support URL
- [ ] Create support page or use email: support@yourdomain.com

#### Marketing URL (Optional)
- [ ] Create landing page if you have one

### 6. Testing Checklist

#### Functionality
- [ ] Document scanning works
- [ ] Multi-page scanning works
- [ ] Signature placement works
- [ ] Signature duplication works (with proper offset)
- [ ] Signature dragging works smoothly
- [ ] OCR text extraction works
- [ ] PDF export works
- [ ] Page navigation works
- [ ] No page duplication bug
- [ ] Signatures appear immediately (not after save)

#### Purchase Flow
- [ ] Terms & Conditions screen appears first
- [ ] Paywall appears after accepting terms
- [ ] Purchase button works
- [ ] Restore purchases works
- [ ] No developer bypass visible
- [ ] Test with Sandbox Apple ID

#### Edge Cases
- [ ] App handles no camera permission gracefully
- [ ] App handles empty document list
- [ ] App handles large PDF files
- [ ] App handles multiple signatures on same page
- [ ] App handles signature on different pages

### 7. Legal Requirements

#### Privacy Policy
- [ ] Privacy policy is accessible in-app (Settings)
- [ ] Privacy policy URL is provided in App Store Connect
- [ ] Privacy policy states: No data collection, all processing on-device

#### Terms of Service
- [ ] Terms acceptance screen on first launch
- [ ] Terms accessible in-app (Settings)

### 8. Build & Archive

#### Before Building
- [ ] Clean build folder (Product > Clean Build Folder)
- [ ] Select "Any iOS Device" or "Generic iOS Device"
- [ ] Verify Release configuration

#### Archive
- [ ] Product > Archive
- [ ] Wait for archive to complete
- [ ] Verify archive appears in Organizer

#### Upload
- [ ] Click "Distribute App"
- [ ] Select "App Store Connect"
- [ ] Select "Upload"
- [ ] Follow prompts to upload

### 9. App Store Connect Submission

#### After Upload
- [ ] Wait for processing (usually 10-30 minutes)
- [ ] Go to App Store Connect > My Apps > Just Scan
- [ ] Create new version
- [ ] Fill in all metadata
- [ ] Upload screenshots
- [ ] Add app preview if created
- [ ] Select build
- [ ] Answer export compliance questions
- [ ] Submit for review

### 10. Common Rejection Reasons to Avoid

- [ ] **Missing Privacy Policy** - Must be accessible in-app AND in App Store Connect
- [ ] **Incomplete Purchase Flow** - Test with Sandbox account
- [ ] **Missing App Icons** - Verify all sizes are present
- [ ] **Crash on Launch** - Test on multiple devices
- [ ] **Missing Functionality** - Ensure all features work
- [ ] **Inappropriate Content** - Verify age rating is correct
- [ ] **Misleading Screenshots** - Screenshots must match app functionality

### 11. Post-Submission

#### Review Timeline
- Typical review: 24-48 hours
- Can take up to 7 days

#### If Rejected
- [ ] Read rejection reason carefully
- [ ] Fix issues
- [ ] Resubmit with explanation

#### If Approved
- [ ] App goes live automatically (if "Automatically release" is enabled)
- [ ] Or manually release when ready

---

## Quick Reference

**Bundle ID:** JIT.Just-Scan  
**Product ID:** com.justscan.onetime  
**Price:** $7.99  
**Version:** 1.0  
**Minimum iOS:** 16.0  

**Required Permissions:**
- Camera (NSCameraUsageDescription) ✅

**Not Required:**
- Photo Library (using VNDocumentCameraViewController)
- Microphone
- Location

---

## Notes

- All document processing happens on-device
- No external servers or data transmission
- Privacy-first architecture
- One-time purchase, no subscriptions

