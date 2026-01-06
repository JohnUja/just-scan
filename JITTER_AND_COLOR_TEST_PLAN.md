# Jittering and Color Change Test Plan

## Test Objectives
1. Identify root cause of selection box jittering during gestures
2. Identify root cause of signature flipping/inverting after color change

---

## Hypotheses to Test

### Jittering Hypotheses

**H1: getActiveSignatureScreenRect() called too frequently**
- **Test:** Log call frequency during drag/rotate/resize
- **Expected:** Should be called once per frame (~60fps max)
- **If confirmed:** Throttle or cache results

**H2: SwiftUI re-rendering SelectionBoxView on every frame**
- **Test:** Log SelectionBoxView render count
- **Expected:** Should render once per frame, not multiple times
- **If confirmed:** Use @State to prevent unnecessary re-renders

**H3: PDFView.setNeedsDisplay() causing layout recalculations**
- **Test:** Log setNeedsDisplay calls and measure time between calls
- **Expected:** Should not be called every frame during gestures
- **If confirmed:** Batch setNeedsDisplay calls or throttle

**H4: Coordinate conversion happening multiple times per frame**
- **Test:** Log PDFCoordinateConverter calls
- **Expected:** Should convert once per rect calculation
- **If confirmed:** Cache conversion results

**H5: Selection box position recalculated from different sources**
- **Test:** Log whether using annotation.bounds vs model.pdfRect
- **Expected:** Should consistently use same source for committed signatures
- **If confirmed:** Ensure consistent source selection

**H6: Transaction modifier not working**
- **Test:** Verify transaction.animation = nil is applied
- **Expected:** No implicit animations should occur
- **If confirmed:** Try alternative animation disabling methods

### Color Change Flipping Hypotheses

**C1: baseImageData corrupted during color change**
- **Test:** Log baseImageData state before/after color change
- **Expected:** baseImageData should remain unchanged
- **If confirmed:** Ensure baseImageData is never modified

**C2: Image orientation lost when loading baseImageData**
- **Test:** Log image.imageOrientation before/after loading
- **Expected:** Orientation should be preserved
- **If confirmed:** Preserve orientation when loading image

**C3: Annotation bounds recalculated incorrectly**
- **Test:** Log bounds before/after color change
- **Expected:** Bounds should not change (only color metadata)
- **If confirmed:** Don't recalculate bounds on color change

**C4: storedImageData modified when it shouldn't be**
- **Test:** Log storedImageData state before/after
- **Expected:** storedImageData should remain base (untinted)
- **If confirmed:** Ensure storedImageData is never written to during color change

**C5: draw() method applying rotation incorrectly**
- **Test:** Log rotation values in draw() method
- **Expected:** Rotation should match originalRotation
- **If confirmed:** Verify rotation calculation in draw()

---

## Test Procedures

### Test 1: Jittering During Drag
1. Open document with committed signature
2. Start dragging signature
3. Observe logs for:
   - getActiveSignatureScreenRect call frequency
   - SelectionBoxView render frequency
   - setNeedsDisplay call frequency
   - Coordinate conversion frequency
4. Measure time between calls
5. Check if calls are synchronized or overlapping

### Test 2: Jittering During Resize
1. Open document with committed signature
2. Start pinching to resize
3. Observe same metrics as Test 1
4. Compare with drag test

### Test 3: Jittering During Rotation
1. Open document with committed signature
2. Start rotating signature
3. Observe same metrics as Test 1
4. Compare with drag/resize tests

### Test 4: Color Change - Before Save
1. Open document with committed signature
2. Change signature color
3. Observe logs for:
   - baseImageData state
   - storedImageData state
   - Annotation bounds
   - Image orientation
   - Rotation values
4. Check if signature flips visually

### Test 5: Color Change - After Save
1. Perform Test 4
2. Save document
3. Reopen document
4. Check if signature is still flipped
5. Compare logs from Test 4

### Test 6: Color Change - Multiple Changes
1. Change color multiple times in succession
2. Observe if flipping gets worse
3. Check if baseImageData accumulates errors

---

## Success Criteria

### Jittering Fixed When:
- getActiveSignatureScreenRect called ≤ 60 times/second
- SelectionBoxView renders ≤ 60 times/second
- No overlapping/conflicting updates
- Smooth visual movement without jitter

### Color Change Fixed When:
- Signature does not flip/invert on color change
- baseImageData remains unchanged
- Image orientation preserved
- Bounds do not change unexpectedly
- Works consistently before and after save

---

## Log Analysis Guide

### Key Metrics to Track:
1. **Call Frequency:** Calls per second (should be ≤ 60)
2. **Time Between Calls:** Should be consistent (~16ms for 60fps)
3. **State Changes:** Should be minimal during gestures
4. **Data Integrity:** baseImageData, storedImageData should not change unexpectedly

### Red Flags:
- getActiveSignatureScreenRect called > 100 times/second
- SelectionBoxView renders > 100 times/second
- baseImageData modified during color change
- Image orientation changes unexpectedly
- Bounds change during color change (when they shouldn't)

---

## Next Steps After Testing

1. Analyze logs to identify confirmed hypotheses
2. Implement fixes for confirmed issues
3. Re-test to verify fixes
4. Remove instrumentation after confirmation

