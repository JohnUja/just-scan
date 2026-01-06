# Debug & Fix Plan

## ✅ Completed
1. **Fixed activeSignatureID clearing** - Added `hasSyncedInitialState` flag to prevent multiple syncs
2. **Selection without saving** - Already works, no changes needed

## 🔧 To Fix

### Priority 1: Critical Bugs
1. **Document thumbnail not updating after save**
   - Issue: Thumbnail doesn't reflect signature changes
   - Fix: Regenerate thumbnail after save in Document model
   - Location: `Document.swift` or `HomeView.swift`

2. **Signature bouncing within selection box after save**
   - Issue: Signature position shifts after save
   - Likely cause: Coordinate conversion mismatch between PDF space and view space
   - Location: `PDFCoordinateConverter.swift` or `saveToDisk()`

3. **Signature bouncing while rotating after save**
   - Issue: Signature jumps during rotation after save
   - Likely cause: Rotation center calculation or coordinate conversion
   - Location: `handleRotation()` in `PDFSignatureEditorController.swift`

### Priority 2: Performance & UX
4. **Laggy signatures**
   - Issue: Signatures feel sluggish during interaction
   - Likely causes: Too many re-renders, inefficient coordinate conversions
   - Location: `renderSignatureOverlays()`, gesture handlers

5. **Move icon jittering**
   - Issue: Floating toolbar move icon causes jittery movement
   - Likely cause: Gesture conflict or coordinate update frequency
   - Location: `FloatingToolbarView` or `handlePan()`

6. **Signature flipping on color change**
   - Issue: Signature flips on x/y axis when color changes
   - Likely cause: Image transformation or coordinate system issue
   - Location: `changeActiveSignatureColor()` or image processing

### Priority 3: Features
7. **Share modes (flatten & secured)**
   - Issue: Share functionality not working correctly
   - Location: `DocumentReviewView.swift` share methods

8. **Memory leak testing**
   - Need to check: Combine subscriptions, closures, weak references
   - Location: All files with Combine or closures

## Next Steps
1. Start with Priority 1 bugs (thumbnail, bouncing)
2. Add instrumentation for each issue
3. Test and verify fixes
4. Move to Priority 2 (performance)
5. Finally Priority 3 (features)

