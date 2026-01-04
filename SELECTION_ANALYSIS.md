# Signature Selection Analysis - Main Branch

## Overview
This document explains how signature selection works in the current main branch codebase, including initial selection and re-entry behavior.

---

## 1. Initial Selection (When User Inserts New Signature)

### Code Path:
```swift
// DocumentReviewView.swift - Lines 252-253
Button("Insert Signature") {
    appendNewPlacement()  // Creates new signature
}

// Lines 1118-1140 (appendNewPlacement)
private func appendNewPlacement(using image: UIImage? = nil) {
    let signatureImage = image ?? signatureService.signatureImage
    guard let img = signatureImage else { return }
    
    let aspectRatio = img.size.width / max(img.size.height, 1)
    let newPlacement = SignaturePlacement(
        center: CGPoint(x: 0.5, y: 0.5),
        widthRatio: 0.3,
        rotation: 0,
        color: .black,
        aspectRatio: aspectRatio,
        signatureImage: img
    )
    
    // Add to in-memory array (NOT committed to PDF yet)
    signaturePlacements[currentPageIndex, default: []].append(newPlacement)
    
    // ✅ Set as active (triggers selection box)
    activePlacementID[currentPageIndex] = newPlacement.id
    isPlacingSignature = true
    hasPendingChanges = true
}
```

### What Happens:
1. **New `SignaturePlacement` created** with `isCommitted = false` (implicitly, since it's not in PDF)
2. **Added to `signaturePlacements[currentPageIndex]`** array (in-memory only)
3. **`activePlacementID[currentPageIndex] = newPlacement.id`** sets it as active
4. **Rendered as SwiftUI overlay** via `signatureOverlay()` → `InlineSignatureOverlay`

---

## 2. Rendering (Uncommitted Signatures)

### Code Path:
```swift
// DocumentReviewView.swift - Lines 440-526
private func signatureOverlay(pdfDocument: PDFDocument) -> some View {
    let placements = signaturePlacements[currentPageIndex] ?? []
    let activeID = activePlacementID[currentPageIndex] ?? nil
    
    ZStack {
        // Check if editing saved annotation (different path)
        if let activeAnnotation = activeAnnotation,
           activeAnnotationPageIndex == currentPageIndex,
           let placement = editingPlacement {
            // Saved signature editing path (see section 4)
            SavedSignatureSelectionOverlay(...)
        } else {
            // ✅ Uncommitted signatures path
            ForEach(placements, id: \.id) { placement in
                let isActive = placement.id == activeID
                
                if isActive {
                    // Active signature: show with selection box
                    InlineSignatureOverlay(
                        pageIndex: currentPageIndex,
                        pdfDocument: pdfDocument,
                        signatureImage: placement.signatureImage,
                        placement: signatureBinding(...),
                        isActive: true,  // ✅ Shows selection box
                        onSave: { ... },
                        onDelete: { ... }
                    )
                } else {
                    // Inactive signature: show image only
                    UnsavedSignatureOverlay(
                        pageIndex: currentPageIndex,
                        pdfDocument: pdfDocument,
                        signatureImage: placement.signatureImage,
                        placement: placement,
                        showImage: true
                    )
                    .onTapGesture {
                        // ✅ Tap to select inactive signature
                        activePlacementID[currentPageIndex] = placement.id
                        isPlacingSignature = true
                    }
                }
            }
        }
    }
}
```

### What Happens:
- **Active signature** (`isActive = true`): Rendered with `InlineSignatureOverlay` which shows selection box/handles
- **Inactive signatures**: Rendered with `UnsavedSignatureOverlay` (image only) with `.onTapGesture` to select
- **Selection box appears** when `activePlacementID` matches a placement's `id`

---

## 3. Move/Scale/Rotate (Uncommitted)

### Code Path:
```swift
// InlineSignatureOverlay.swift - Gesture handlers
.onMove: { delta in
    // Updates placement.center via binding
    placement.center.x += delta.width
    placement.center.y += delta.height
}

.onResize: { scaleFactor in
    // Updates placement.widthRatio via binding
    placement.widthRatio *= scaleFactor
}

.onRotate: { angle in
    // Updates placement.rotation via binding
    placement.rotation += angle
}
```

### What Happens:
- Gestures update `SignaturePlacement` properties via `@Binding`
- Changes are **in-memory only** (not in PDF)
- SwiftUI automatically re-renders overlay with new transform

---

## 4. After Save Operation

### Code Path:
```swift
// DocumentReviewView.swift - Lines 1006-1056
private func saveSignatureToPage(pageIndex: Int, persistToDisk: Bool = true) {
    guard let pdfDocument = pdfDocument,
          let page = pdfDocument.page(at: pageIndex) else { return }
    
    let unsaved = signaturePlacements[pageIndex] ?? []
    
    // ✅ Convert each SignaturePlacement to PDFAnnotation
    for placement in unsaved {
        if let annotation = makeAnnotation(from: placement, on: page) {
            page.addAnnotation(annotation)  // Add to PDF
        }
    }
    
    // ✅ Save to disk if requested
    if persistToDisk, let data = pdfDocument.dataRepresentation() {
        try? data.write(to: activeFileURL, options: .atomic)
    }
    
    // ✅ Clear overlay state (signatures now in PDF)
    signaturePlacements[pageIndex] = []
    activePlacementID[pageIndex] = nil
    isPlacingSignature = false
    hasPendingChanges = false
}
```

### What Happens:
1. **Each `SignaturePlacement` → `PDFAnnotation`** via `makeAnnotation()`
2. **Annotations added to PDF page** (`page.addAnnotation()`)
3. **PDF written to disk** (if `persistToDisk = true`)
4. **Overlay state cleared** (`signaturePlacements[pageIndex] = []`)
5. **Signatures now rendered by PDFKit** (not SwiftUI overlays)

**State Change:**
- Before: `SignaturePlacement` in memory (`signaturePlacements` array)
- After: `PDFAnnotation` in PDF document (rendered by PDFKit)

---

## 5. User Taps Saved Signature (After Re-entry)

### Code Path:
```swift
// DocumentReviewView.swift - Lines 403-414
SavedSignatureOverlay(
    pdfDocument: pdfDocument,
    pageIndex: currentPageIndex,
    selectedSignature: .constant(nil),
    currentlyEditingAnnotation: activeAnnotation,
    onDelete: { _ in },
    onEdit: { annotation in
        commitActiveEditInMemory()
        beginEditing(annotation: annotation, pageIndex: currentPageIndex)  // ✅ KEY
    }
)

// SavedSignatureOverlay.swift - Lines 1665-1704
struct SavedSignatureOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            if let page = pdfDocument.page(at: pageIndex) {
                let transform = DocumentReviewView.PDFPageTransform(...)
                
                // ✅ Find all signature annotations
                let signatureAnnotations = page.annotations.filter {
                    $0.userName == "Signature" && $0 !== currentlyEditingAnnotation
                }
                
                ForEach(signatureAnnotations, id: \.0) { _, annotation in
                    let bounds = annotation.bounds
                    let center = transform.viewPoint(from: normalizedCenter)
                    let visualWidth = bounds.width * transform.scale
                    let visualHeight = bounds.height * transform.scale
                    
                    // ✅ Invisible button over each signature
                    Button {
                        onEdit(annotation)  // Calls beginEditing()
                    } label: {
                        Color.black.opacity(0.001)  // Invisible hit area
                    }
                    .frame(width: visualWidth + 20, height: visualHeight + 20)
                    .position(center)
                }
            }
        }
    }
}
```

### What Happens:
1. **`SavedSignatureOverlay`** creates invisible buttons over each saved signature
2. **User taps** → `Button` action fires → `onEdit(annotation)` called
3. **`beginEditing(annotation: pageIndex:)`** is called (line 412)

---

## 6. beginEditing() - Selection of Saved Signature

### Code Path:
```swift
// DocumentReviewView.swift - Lines 880-915
private func beginEditing(annotation: PDFAnnotation, pageIndex: Int) {
    // 1. Commit any current edits
    commitActiveEditInMemory()
    
    guard let pdfDocument = pdfDocument,
          let page = pdfDocument.page(at: pageIndex) else { return }
    
    // 2. ✅ Verify it's a signature annotation
    guard annotation.userName == "Signature" else { return }
    
    // 3. ✅ Convert PDFAnnotation → SignaturePlacement
    guard let placement = placement(from: annotation, on: page) else { return }
    
    // 4. ✅ Ensure annotation is editable (convert if needed)
    let targetAnnotation: PDFAnnotation
    if let stamp = annotation as? ImageStampAnnotation {
        targetAnnotation = stamp
    } else if let converted = makeAnnotation(from: placement, on: page) {
        page.removeAnnotation(annotation)
        page.addAnnotation(converted)  // Replace with editable type
        targetAnnotation = converted
    } else {
        return
    }
    
    // 5. ✅ Set editing state (triggers selection box)
    activeAnnotation = targetAnnotation
    activeAnnotationPageIndex = pageIndex
    editingPlacement = placement  // ✅ Stored separately (NOT in signaturePlacements)
    isPlacingSignature = false
    hasPendingChanges = false
    registerSavedAnnotationUndoSnapshot(for: pageIndex, placement: placement)
    savedAnnotationRedoStack[pageIndex] = []
    redoStack[pageIndex] = []
    pdfRefreshID = UUID()  // Trigger view refresh
}
```

### What Happens:
1. **`placement(from:annotation:on:page:)`** converts `PDFAnnotation` → `SignaturePlacement`
   - Extracts bounds, rotation, color, aspectRatio from annotation
   - Recovers image from `ImageStampAnnotation.imageSnapshot` or JSON `imageDataB64`
2. **Annotation converted to `ImageStampAnnotation`** if needed (for editability)
3. **State variables set:**
   - `activeAnnotation = targetAnnotation` (the PDF annotation being edited)
   - `activeAnnotationPageIndex = pageIndex`
   - `editingPlacement = placement` (the converted placement, stored separately)
4. **Selection box appears** because `signatureOverlay()` checks:
   ```swift
   if let activeAnnotation = activeAnnotation,
      activeAnnotationPageIndex == currentPageIndex,
      let placement = editingPlacement {
       SavedSignatureSelectionOverlay(...)  // ✅ Shows selection box
   }
   ```

---

## 7. Rendering Selected Saved Signature

### Code Path:
```swift
// DocumentReviewView.swift - Lines 447-486
if let activeAnnotation = activeAnnotation,
   activeAnnotationPageIndex == currentPageIndex,
   let placement = editingPlacement {
    // ✅ Show selection box ONLY (no image overlay - PDFKit renders it)
    SavedSignatureSelectionOverlay(
        pageIndex: currentPageIndex,
        pdfDocument: pdfDocument,
        placement: Binding(
            get: { placement },
            set: { newValue in
                editingPlacement = newValue
                // ✅ Immediately apply changes to PDF annotation
                if let page = pdfDocument.page(at: currentPageIndex),
                   let annotation = self.activeAnnotation {
                    _ = applyPlacement(newValue, to: annotation, on: page)
                    hasPendingChanges = true
                    pdfRefreshID = UUID()
                }
            }
        ),
        onDelete: { ... },
        onGestureStart: {
            registerSavedAnnotationUndoSnapshot(for: currentPageIndex)
        }
    )
}
```

### What Happens:
- **PDFKit renders the signature image** (from `PDFAnnotation`)
- **SwiftUI renders selection box/handles** via `SavedSignatureSelectionOverlay`
- **Binding updates** `editingPlacement` and immediately applies to annotation via `applyPlacement()`

---

## 8. Document Review Page Closed

### Code Path:
```swift
// DocumentReviewView.swift - Lines 580-594
Button("Done") {
    // Save any pending edits
    if hasPendingChanges || (activeAnnotation != nil) || !(signaturePlacements[currentPageIndex]?.isEmpty ?? true) {
        saveSignatureToPage(pageIndex: currentPageIndex, persistToDisk: true)
    }
    
    // Clear editing state
    activeAnnotation = nil
    activeAnnotationPageIndex = nil
    editingPlacement = nil
    dismiss()
}
```

### What Happens:
1. **Any unsaved signatures** → saved to PDF as annotations
2. **Any active editing** → committed via `saveSignatureToPage()`
3. **State cleared** (`activeAnnotation = nil`, etc.)
4. **View dismissed**

---

## 9. Document Review Page Reopened

### Code Path:
```swift
// DocumentReviewView.swift - Lines 299-301
.onAppear {
    loadPDF()  // ✅ Loads PDF from disk
}

// Lines 933-941
private func loadPDF() {
    let fileURL = activeFileURL
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    let savedPageIndex = currentPageIndex
    if let newPDF = PDFDocument(url: fileURL), newPDF.pageCount > 0 {
        pdfDocument = newPDF  // ✅ PDF loaded with annotations
        currentPageIndex = min(savedPageIndex, newPDF.pageCount - 1)
    }
}
```

### What Happens:
1. **`loadPDF()`** loads `PDFDocument` from disk
2. **PDF contains annotations** (signatures saved previously)
3. **`signaturePlacements` is empty** (no unsaved signatures)
4. **`activeAnnotation = nil`** (nothing selected yet)
5. **`SavedSignatureOverlay`** creates invisible buttons over each signature annotation
6. **User can tap** any signature to select it

---

## 10. Selection on Re-entry (Complete Flow)

### Step-by-Step:

1. **View Appears:**
   ```swift
   .onAppear { loadPDF() }  // Loads PDF with annotations
   ```

2. **PDF Rendered:**
   - PDFKit automatically renders all `PDFAnnotation` objects (including signatures)
   - No SwiftUI overlays yet (no unsaved signatures)

3. **Tap Layer Created:**
   ```swift
   SavedSignatureOverlay(
       pdfDocument: pdfDocument,
       pageIndex: currentPageIndex,
       onEdit: { annotation in
           beginEditing(annotation: annotation, pageIndex: currentPageIndex)
       }
   )
   ```
   - Creates invisible `Button` over each signature annotation
   - Button frame = annotation bounds + 20pt padding

4. **User Taps Signature:**
   - `Button` action fires → `onEdit(annotation)` called
   - `beginEditing(annotation: pageIndex:)` called

5. **beginEditing() Executes:**
   - Converts `PDFAnnotation` → `SignaturePlacement` via `placement(from:annotation:on:page:)`
   - Sets `activeAnnotation = annotation`
   - Sets `editingPlacement = placement`
   - Sets `activeAnnotationPageIndex = pageIndex`

6. **Selection Box Appears:**
   ```swift
   if let activeAnnotation = activeAnnotation,
      activeAnnotationPageIndex == currentPageIndex,
      let placement = editingPlacement {
       SavedSignatureSelectionOverlay(...)  // ✅ Renders selection box
   }
   ```

7. **User Can Now Edit:**
   - Move, resize, rotate via `SavedSignatureSelectionOverlay` gestures
   - Changes update `editingPlacement` binding
   - Binding setter immediately applies to `activeAnnotation` via `applyPlacement()`

---

## Key Differences: Uncommitted vs Committed

### Uncommitted (Before Save):
- **State:** `SignaturePlacement` in `signaturePlacements` array
- **Rendering:** SwiftUI `InlineSignatureOverlay` (image + selection box)
- **Selection:** `activePlacementID[currentPageIndex] = placement.id`
- **Storage:** In-memory only

### Committed (After Save):
- **State:** `PDFAnnotation` in PDF document
- **Rendering:** PDFKit renders image, SwiftUI renders selection box only
- **Selection:** `activeAnnotation = annotation`, `editingPlacement = placement`
- **Storage:** In PDF file on disk

---

## Potential Issues on Re-entry

### Issue 1: Annotations Not Tappable
**Possible Causes:**
- `SavedSignatureOverlay` not rendering (z-index issue)
- Annotation `userName != "Signature"` (filter fails)
- Coordinate transform incorrect (button position wrong)
- Hit-testing disabled somewhere

### Issue 2: Selection Box Doesn't Appear
**Possible Causes:**
- `beginEditing()` not being called
- `placement(from:annotation:on:page:)` returns `nil` (can't recover image)
- `activeAnnotation` or `editingPlacement` not set correctly
- View refresh not triggered (`pdfRefreshID` not updated)

### Issue 3: Selection Box Appears But Signature Doesn't Move
**Possible Causes:**
- `applyPlacement()` not working correctly
- Annotation bounds not updating
- PDFKit not refreshing (`pdfRefreshID` not triggering redraw)

---

## Summary

**Selection Flow:**
1. **New Signature:** `appendNewPlacement()` → `activePlacementID` set → `InlineSignatureOverlay` shows selection box
2. **Saved Signature:** Tap → `SavedSignatureOverlay` button → `beginEditing()` → `activeAnnotation` + `editingPlacement` set → `SavedSignatureSelectionOverlay` shows selection box

**Re-entry Flow:**
1. `loadPDF()` loads PDF with annotations
2. `SavedSignatureOverlay` creates tap targets
3. User taps → `beginEditing()` → selection box appears
4. User edits → changes applied to annotation via `applyPlacement()`

