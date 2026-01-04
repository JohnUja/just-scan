# Architecture Comparison: Main vs Refactor Branch

## Quick Reference

This document compares the signature selection and management architecture between the **main branch** (current production) and the **refactor branch** (new unified architecture).

---

## State Management

### Main Branch:
```swift
// Separate state for uncommitted vs committed
@State private var signaturePlacements: [Int: [SignaturePlacement]] = [:]
@State private var activePlacementID: [Int: UUID?] = [:]  // Uncommitted
@State private var activeAnnotation: PDFAnnotation? = nil  // Committed
@State private var editingPlacement: SignaturePlacement? = nil  // Committed
```

### Refactor Branch:
```swift
// Unified state for both committed and uncommitted
private var signatures: [Int: [SignatureModel]] = [:]
private var activeSignatureID: UUID?  // Works for both!
```

**Advantage:** Refactor has simpler, unified state management.

---

## Selection Mechanism

### Main Branch:
1. **Uncommitted:** Tap on `UnsavedSignatureOverlay` → sets `activePlacementID`
2. **Committed:** Tap on `SavedSignatureOverlay` invisible button → `beginEditing()` → sets `activeAnnotation` + `editingPlacement`

### Refactor Branch:
1. **Both:** UIKit `UITapGestureRecognizer` on PDFView → `handleTap()` → sets `activeSignatureID`

**Advantage:** Refactor has single, consistent selection path.

---

## Rendering

### Main Branch:
- **Uncommitted:** SwiftUI `InlineSignatureOverlay` (image + selection box)
- **Committed:** PDFKit renders image, SwiftUI `SavedSignatureSelectionOverlay` renders selection box only

### Refactor Branch:
- **Uncommitted:** CALayer overlay (image) + SwiftUI `SelectionBoxView` (selection box)
- **Committed:** PDFKit renders image, SwiftUI `SelectionBoxView` renders selection box

**Advantage:** Refactor uses consistent rendering approach (CALayer for images, SwiftUI for UI).

---

## Re-entry Handling

### Main Branch:
```swift
// Manual conversion on tap
SavedSignatureOverlay → onEdit(annotation) → beginEditing() → 
  placement(from:annotation:) → activeAnnotation + editingPlacement
```

### Refactor Branch:
```swift
// Automatic loading on view appear
loadDocument() → loadSignaturesFromAnnotations() → 
  SignatureModel.fromAnnotation() → signatures array populated
// Then tap works immediately via handleTap()
```

**Advantage:** Refactor automatically loads all signatures, making them immediately tappable.

---

## Why the Analysis Document is Useful

### 1. **Understanding Evolution**
- Shows how the architecture evolved from main → refactor
- Documents the problems the refactor solved

### 2. **Debugging Reference**
- If issues arise in refactor, compare with main branch approach
- Understand why certain design decisions were made

### 3. **Migration Guide**
- If merging refactor to main, understand what needs to change
- See what state variables need to be migrated

### 4. **Feature Parity Check**
- Ensure refactor branch has all features from main
- Verify selection behavior matches expectations

---

## Recommended Next Steps

1. **Keep both analysis documents:**
   - `SELECTION_ANALYSIS.md` - Documents main branch (reference)
   - `SELECTION_ANALYSIS_REFACTOR.md` - Documents refactor branch (current)

2. **Use for debugging:**
   - If selection doesn't work on re-entry, compare with main branch approach
   - Check if `loadSignaturesFromAnnotations()` is being called
   - Verify `SignatureModel.fromAnnotation()` is working correctly

3. **Consider improvements:**
   - Refactor's hit-testing could be improved (rotated rectangle instead of circle)
   - Main branch's invisible button approach might be more reliable for complex shapes

4. **Test both approaches:**
   - Compare selection reliability between branches
   - Measure performance differences
   - Check edge cases (rotated signatures, overlapping signatures, etc.)

---

## Conclusion

**Yes, the analysis document is useful!** It provides:
- ✅ Reference for understanding the old architecture
- ✅ Comparison point for debugging the new architecture
- ✅ Documentation of the evolution and improvements
- ✅ Guide for ensuring feature parity

**Recommendation:** Keep both documents and use them as reference when debugging selection issues or planning further improvements.

