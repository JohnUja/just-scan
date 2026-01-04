# Signature Selection Analysis - Refactor Branch

## Overview
This document explains how signature selection works in the **refactor branch** (`refactor/signature-architecture-fixes`), which uses a unified `SignatureModel` architecture with UIKit-based gesture handling.

---

## Architecture Differences: Main vs Refactor

### Main Branch (Old):
- **State:** `SignaturePlacement` struct
- **Selection:** `activePlacementID[Int: UUID?]` (uncommitted) + `activeAnnotation` (committed)
- **Tap Detection:** SwiftUI `SavedSignatureOverlay` with invisible buttons
- **Rendering:** SwiftUI overlays for uncommitted, PDFKit for committed

### Refactor Branch (New):
- **State:** `SignatureModel` struct (unified for both committed/uncommitted)
- **Selection:** Single `activeSignatureID: UUID?` (works for both)
- **Tap Detection:** UIKit `UITapGestureRecognizer` directly on PDFView
- **Rendering:** CALayer overlays for uncommitted, PDFKit annotations for committed

---

## 1. Initial Selection (When User Inserts New Signature)

### Code Path:
```swift
// DocumentReviewView.swift - User taps "+" button
editorProxy.addNewSignature(imageID: imageID)

// PDFEditorControllerProxy.swift - Proxy forwards
controller?.addNewSignature(imageID: imageID)

// PDFSignatureEditorController.swift - Lines 222-266
func addNewSignature(imageID: String? = nil) {
    // 1. Get signature image from SignatureService
    let signatureImage: UIImage?
    let finalImageID: String
    // ... (gets image from service)
    
    // 2. Create SignatureModel with isCommitted = false
    let newSignature = SignatureModel(
        center: CGPoint(x: 0.5, y: 0.5),  // Normalized center
        widthRatio: 0.3,
        rotation: 0,
        color: .black,
        imageID: finalImageID,
        aspectRatio: aspectRatio,
        isCommitted: false  // ✅ KEY: Not committed yet
    )
    
    // 3. Register undo snapshot BEFORE adding
    registerUndoSnapshot(for: currentPageIndex)
    
    // 4. Add to in-memory signatures array
    signatures[currentPageIndex, default: []].append(newSignature)
    
    // 5. ✅ Set as active (triggers selection box/toolbar)
    activeSignatureID = newSignature.id
    activeSignatureIDSubject.send(activeSignatureID)
    hasPendingChangesSubject.send(true)
    
    // 6. Render as CALayer overlay (not PDF annotation)
    renderSignatureOverlays()
}
```

### What Happens:
1. **New `SignatureModel` created** with `isCommitted = false`
2. **Added to `signatures[currentPageIndex]`** array (in-memory only)
3. **`activeSignatureID = newSignature.id`** sets it as active
4. **Rendered as CALayer overlay** via `renderSignatureOverlays()`
5. **SwiftUI `SelectionBoxView` appears** because `activeSignatureID` is set

---

## 2. Rendering (Uncommitted Signatures)

### Code Path:
```swift
// PDFSignatureEditorController.swift - Lines 1095-1111
private func renderSignatureOverlays() {
    // Clear existing overlays
    overlayLayer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    
    guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
    
    // ✅ Render all uncommitted signatures as CALayer overlays
    let pageSignatures = signatures[currentPageIndex] ?? []
    
    for signature in pageSignatures where !signature.isCommitted {
        renderSignatureOverlay(signature, page: page)  // ✅ CALayer rendering
    }
    
    // Also refresh PDF view for committed signatures
    pdfView.setNeedsDisplay()
}

// Lines 1113-1150
private func renderSignatureOverlay(_ signature: SignatureModel, page: PDFPage) {
    // 1. Get image from SignatureService
    let image: UIImage?
    if let uuid = UUID(uuidString: signature.imageID),
       let savedSignature = signatureService.signatureHistory.first(where: { $0.id == uuid }) {
        image = savedSignature.image
    }
    
    // 2. Apply color tint
    let tintedImage = applyColorTint(to: finalImage, color: signature.color.uiColor)
    
    // 3. Convert normalized coordinates to screen coordinates
    let pdfRect = signature.pdfRect(for: page)
    let screenRect = PDFCoordinateConverter.pdfRectToView(pdfRect, page: page, pdfView: pdfView)
    
    // 4. Create CALayer for overlay
    let imageLayer = CALayer()
    imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    imageLayer.position = CGPoint(x: screenRect.midX, y: screenRect.midY)
    imageLayer.bounds = CGRect(x: 0, y: 0, width: screenRect.width, height: screenRect.height)
    imageLayer.contents = tintedImage.cgImage
    
    // 5. Apply rotation + Y-flip transform
    let rotationRadians = signature.rotation * .pi / 180.0
    var transform = CATransform3DIdentity
    transform = CATransform3DRotate(transform, rotationRadians, 0, 0, 1)
    transform = CATransform3DScale(transform, 1, -1, 1)  // Y-flip for PDF coords
    imageLayer.transform = transform
    
    // 6. Add to overlay layer (above PDFView)
    overlayLayer?.addSublayer(imageLayer)
}
```

### What Happens:
- **Uncommitted signatures** render as CALayer overlays on top of PDFView
- **Committed signatures** render via PDFKit annotations (drawn by PDFKit)
- **Selection box** rendered by SwiftUI `SelectionBoxView` when `activeSignatureID` matches

---

## 3. Move/Scale/Rotate (Uncommitted)

### Code Path:
```swift
// DocumentReviewView.swift - SelectionBoxView gestures
onMove: { delta in
    editorProxy.moveActiveSignature(by: delta)
}

// PDFSignatureEditorController.swift - Lines 947-990
func moveActiveSignature(by screenDelta: CGSize) {
    guard let activeID = activeSignatureID,
          var signature = getSignature(id: activeID, pageIndex: currentPageIndex),
          let page = pdfDocument?.page(at: currentPageIndex) else { return }
    
    // 1. Register undo snapshot on FIRST move only
    if !isMovingSignature {
        registerUndoSnapshot(for: currentPageIndex)
        isMovingSignature = true
    }
    
    // 2. Convert screen delta to normalized coordinates
    let normalizedDX = screenDelta.width / (pageBounds.width * scale)
    let normalizedDY = -screenDelta.height / (pageBounds.height * scale)
    
    // 3. Update signature model
    signature.center.x += normalizedDX
    signature.center.y += normalizedDY
    
    // 4. Update in-memory array
    pageSignatures[idx] = signature
    signatures[currentPageIndex] = pageSignatures
    
    // 5. If committed, update PDF annotation (not needed for uncommitted)
    if signature.isCommitted {
        updateAnnotationBounds(existing, for: signature, page: page)
        pdfView.setNeedsDisplay()
    }
    
    // 6. Re-render overlay (CALayer updates)
    renderSignatureOverlays()
}
```

**Resize and Rotate follow the same pattern** - update `SignatureModel`, then re-render.

---

## 4. After Save Operation

### Code Path:
```swift
// DocumentReviewView.swift - User taps "Save"
editorProxy.commitAllToPDF()
_ = editorProxy.saveToDisk(url: document.fileURL)

// PDFSignatureEditorController.swift - Lines 361-382
func commitAllToPDF() {
    guard let document = pdfDocument else { return }
    
    for (pageIndex, pageSignatures) in signatures {
        guard let page = document.page(at: pageIndex) else { continue }
        
        var updated = pageSignatures
        for i in updated.indices {
            var sig = updated[i]
            
            // ✅ Convert SignatureModel to PDF annotation
            upsertAnnotation(for: sig, on: page)
            
            // Mark as committed
            sig.isCommitted = true
            sig.annotationID = sig.id.uuidString
            updated[i] = sig
        }
        signatures[pageIndex] = updated
    }
    
    renderSignatureOverlays()  // Now renders nothing (all committed)
}

// Lines 385-398
func saveToDisk(url: URL) -> Bool {
    // 1. Commit all to PDF first
    commitAllToPDF()
    
    // 2. Write PDFDocument to disk (preserves annotations)
    let ok = document.write(to: url)
    
    if ok {
        hasPendingChangesSubject.send(false)
    }
    return ok
}
```

### What Happens:
1. **`commitAllToPDF()`** converts all `SignatureModel` objects to `ImageStampAnnotation` objects
2. **Annotations added to PDF pages** via `upsertAnnotation()`
3. **`isCommitted = true`** for all signatures
4. **`renderSignatureOverlays()`** no longer renders them (they're PDF annotations now)
5. **`saveToDisk()`** writes the PDF with annotations to disk

**State Change:**
- Before: `SignatureModel` with `isCommitted = false` (in memory)
- After: `SignatureModel` with `isCommitted = true` (also in PDF as annotation)

---

## 5. User Taps Saved Signature (After Re-entry) - KEY DIFFERENCE

### Code Path:
```swift
// PDFSignatureEditorController.swift - Lines 642-675
@objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let document = pdfDocument,
          let page = document.page(at: currentPageIndex) else { return }
    
    let location = gesture.location(in: pdfView)
    let pdfPoint = PDFCoordinateConverter.viewToPDF(location, page: page, pdfView: pdfView)
    
    // ✅ Find signature at tap location (check all signatures on current page)
    let pageSignatures = signatures[currentPageIndex] ?? []
    
    // Check from top to bottom (reverse order) to get the topmost signature
    for signature in pageSignatures.reversed() {
        let pdfRect = signature.pdfRect(for: page)
        let center = CGPoint(x: pdfRect.midX, y: pdfRect.midY)
        
        // ✅ Use distance-to-center bounding circle for hit-testing
        let dx = pdfPoint.x - center.x
        let dy = pdfPoint.y - center.y
        let radius = hypot(pdfRect.width, pdfRect.height) / 2
        
        if hypot(dx, dy) <= radius {
            // ✅ Set as active (triggers selection box)
            activeSignatureID = signature.id
            activeSignatureIDSubject.send(activeSignatureID)
            renderSignatureOverlays()
            return
        }
    }
    
    // No signature hit - deselect
    activeSignatureID = nil
    activeSignatureIDSubject.send(nil)
    renderSignatureOverlays()
}
```

### What Happens:
1. **UIKit `UITapGestureRecognizer`** fires when user taps PDFView
2. **Convert tap location** from view coordinates to PDF coordinates
3. **Iterate through `signatures[currentPageIndex]`** (both committed and uncommitted)
4. **Hit-test using bounding circle** (accounts for rotation)
5. **Set `activeSignatureID`** if hit found
6. **SwiftUI `SelectionBoxView` appears** because `activeSignatureID` is set

**KEY DIFFERENCE from Main Branch:**
- **Main:** Uses SwiftUI `SavedSignatureOverlay` with invisible buttons
- **Refactor:** Uses UIKit gesture recognizer directly on PDFView
- **Main:** Separate state for committed (`activeAnnotation`) vs uncommitted (`activePlacementID`)
- **Refactor:** Unified state (`activeSignatureID`) works for both

---

## 6. Document Review Page Reopened

### Code Path:
```swift
// PDFEditorRepresentable.swift - Lines 29-41
func makeUIViewController(context: Context) -> PDFSignatureEditorController {
    let controller = PDFSignatureEditorController()
    controller.loadDocument(pdfDocument)  // ✅ Triggers loadSignaturesFromAnnotations()
    // ...
}

// PDFSignatureEditorController.swift - Lines 191-201
func loadDocument(_ document: PDFDocument) {
    pdfView.document = document
    
    if let page = document.page(at: currentPageIndex) {
        pdfView.go(to: page)
    }
    
    // ✅ Load existing signatures from annotations
    loadSignaturesFromAnnotations()
}

// Lines 595-619
private func loadSignaturesFromAnnotations() {
    guard let document = pdfDocument else { return }
    
    var loadedSignatures: [Int: [SignatureModel]] = [:]
    
    for pageIndex in 0..<document.pageCount {
        guard let page = document.page(at: pageIndex) else { continue }
        
        let pageSignatures = page.annotations.compactMap { annotation -> SignatureModel? in
            // ✅ Ensure annotation is editable when loading
            if let stamp = annotation as? ImageStampAnnotation {
                stamp.isReadOnly = false  // ✅ Make editable on load
            } else {
                annotation.isReadOnly = false  // ✅ Make editable on load
            }
            // ✅ Convert PDFAnnotation → SignatureModel
            return SignatureModel.fromAnnotation(annotation, page: page)
        }
        
        if !pageSignatures.isEmpty {
            loadedSignatures[pageIndex] = pageSignatures
        }
    }
    
    signatures = loadedSignatures  // ✅ Restore in-memory state
}
```

### What Happens:
1. **`loadDocument()`** called when view appears
2. **`loadSignaturesFromAnnotations()`** reads all PDF annotations
3. **Converts each annotation to `SignatureModel`** via `SignatureModel.fromAnnotation()`
4. **All loaded signatures have `isCommitted = true`**
5. **Stored in `signatures` dictionary** (same structure as uncommitted)
6. **User can tap** → `handleTap()` finds signature → sets `activeSignatureID`

---

## 7. Selection on Re-entry (Complete Flow)

### Step-by-Step:

1. **View Appears:**
   ```swift
   PDFEditorRepresentable.makeUIViewController()
   → controller.loadDocument(pdfDocument)
   → loadSignaturesFromAnnotations()
   ```

2. **Signatures Loaded:**
   - All PDF annotations converted to `SignatureModel` objects
   - All have `isCommitted = true`
   - Stored in `signatures[currentPageIndex]` array

3. **PDF Rendered:**
   - PDFKit automatically renders all `PDFAnnotation` objects (including signatures)
   - No CALayer overlays (all signatures are committed)

4. **User Taps Signature:**
   - UIKit `UITapGestureRecognizer` fires
   - `handleTap(_:)` called

5. **Hit-Testing:**
   ```swift
   for signature in pageSignatures.reversed() {
       let pdfRect = signature.pdfRect(for: page)
       let center = CGPoint(x: pdfRect.midX, y: pdfRect.midY)
       let radius = hypot(pdfRect.width, pdfRect.height) / 2
       
       if hypot(dx, dy) <= radius {
           activeSignatureID = signature.id  // ✅ Found!
           return
       }
   }
   ```

6. **Selection Box Appears:**
   ```swift
   // DocumentReviewView.swift
   if let activeID = activeSignatureID,
      let activeSignature = signatures[currentPageIndex]?.first(where: { $0.id == activeID }) {
       // ✅ Show selection box and toolbar
       SelectionBoxView(...)
       FloatingToolbarView(...)
   }
   ```

7. **User Can Now Edit:**
   - Move, resize, rotate via `SelectionBoxView` gestures
   - Changes update `SignatureModel` in `signatures` array
   - If committed, also updates PDF annotation via `updateAnnotationBounds()` + remove/add

---

## Key Advantages of Refactor Architecture

### 1. Unified State Model
- **Single `activeSignatureID`** works for both committed and uncommitted
- **No separate state variables** (`activePlacementID` vs `activeAnnotation`)
- **Simpler mental model**

### 2. Direct Gesture Handling
- **UIKit gesture recognizer** directly on PDFView (no invisible buttons)
- **More reliable hit-testing** (works with PDFKit's coordinate system)
- **No z-index issues** with overlay buttons

### 3. Unified Rendering
- **CALayer overlays** for uncommitted (consistent with committed)
- **Same `SignatureModel` structure** for both states
- **Easier to maintain**

### 4. Better Re-entry Handling
- **`loadSignaturesFromAnnotations()`** rebuilds state from annotations
- **All signatures in same array** (`signatures[currentPageIndex]`)
- **Hit-testing works immediately** (no need to create tap layers)

---

## Potential Issues in Refactor Branch

### Issue 1: Hit-Testing May Miss Rotated Signatures
**Current Implementation:**
```swift
// Uses bounding circle (simple but may miss rotated rectangles)
let radius = hypot(pdfRect.width, pdfRect.height) / 2
if hypot(dx, dy) <= radius { ... }
```

**Potential Fix:**
- Use proper rotated rectangle hit-testing
- Account for actual signature bounds with rotation

### Issue 2: Annotations Not Loaded Correctly
**Current Implementation:**
```swift
return SignatureModel.fromAnnotation(annotation, page: page)
```

**Potential Issues:**
- `SignatureModel.fromAnnotation()` may return `nil` if image can't be recovered
- Annotation metadata may be missing or corrupted
- `isReadOnly = false` may not persist after save

### Issue 3: Selection Box Not Appearing
**Possible Causes:**
- `activeSignatureID` not being set correctly
- `signatures` array not populated on load
- SwiftUI `SelectionBoxView` not receiving correct `activeSignatureID` binding

---

## Comparison: Main vs Refactor Selection

| Aspect | Main Branch | Refactor Branch |
|--------|-------------|-----------------|
| **State Model** | `SignaturePlacement` | `SignatureModel` |
| **Uncommitted Selection** | `activePlacementID[Int: UUID?]` | `activeSignatureID: UUID?` |
| **Committed Selection** | `activeAnnotation: PDFAnnotation?` + `editingPlacement` | `activeSignatureID: UUID?` (same!) |
| **Tap Detection** | SwiftUI `SavedSignatureOverlay` (invisible buttons) | UIKit `UITapGestureRecognizer` |
| **Hit-Testing** | Button frame over annotation | Bounding circle distance check |
| **Re-entry Loading** | Manual `beginEditing()` call | Automatic `loadSignaturesFromAnnotations()` |
| **Rendering Uncommitted** | SwiftUI `InlineSignatureOverlay` | CALayer overlay |
| **Rendering Committed** | PDFKit annotation + SwiftUI selection box | PDFKit annotation + SwiftUI selection box |

---

## Summary

**Refactor Branch Selection Flow:**
1. **New Signature:** `addNewSignature()` → `activeSignatureID` set → CALayer overlay + SwiftUI selection box
2. **Saved Signature:** Tap → `handleTap()` → hit-test → `activeSignatureID` set → SwiftUI selection box
3. **Re-entry:** `loadSignaturesFromAnnotations()` → rebuilds `SignatureModel` array → tap works immediately

**Key Improvement:**
- **Unified architecture** - same `activeSignatureID` and `SignatureModel` for both committed/uncommitted
- **Simpler code** - no separate state management
- **More reliable** - direct gesture handling, no overlay button positioning issues

