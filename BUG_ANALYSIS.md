# Bug Analysis Report - DocumentReviewView

## Critical Bugs (High Priority)

### 1. **Memory Leak: NotificationCenter Observer Never Removed**
**Location:** `PDFViewRepresentable.Coordinator.setupZoomObserver()` (Line ~2453)

**Problem:**
```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleScaleChange),
    name: .PDFViewScaleChanged,
    object: pdfView
)
```
The observer is added but **never removed**. When the view is deallocated, the observer remains and can cause:
- Crashes when notifications fire on deallocated objects
- Memory leaks (Coordinator retained by NotificationCenter)
- Zombie object crashes

**Fix:**
```swift
deinit {
    NotificationCenter.default.removeObserver(self)
}
```

---

### 2. **Force Unwrapping Crash Risk**
**Location:** `UnifiedSignatureOverlay.onResize` (Line ~1755)

**Problem:**
```swift
if initialWidthRatio == nil { initialWidthRatio = placement.widthRatio }
let newWidthRatio = max(0.05, min(0.8, initialWidthRatio! * factor))
```
Even though we check for nil and set it, there's a **race condition** where `initialWidthRatio` could theoretically be nil if the closure executes before the assignment completes. Also, the force unwrap `!` is dangerous.

**Fix:**
```swift
let baseRatio = initialWidthRatio ?? placement.widthRatio
if initialWidthRatio == nil { initialWidthRatio = baseRatio }
let newWidthRatio = max(0.05, min(0.8, baseRatio * factor))
```

---

### 3. **Insufficient Coordinate Validation**
**Location:** Multiple places using `pdfView.convert()` (Lines ~1710, 1967, etc.)

**Problem:**
```swift
let screenPoint = pdfView.convert(pdfPoint, from: page)
if screenPoint != .zero {
    // Use screenPoint
}
```
This check is **insufficient**. `pdfView.convert()` can return:
- `CGPoint(x: NaN, y: NaN)` - Invalid calculations
- `CGPoint(x: Infinity, y: Infinity)` - Overflow cases
- `CGPoint(x: -Infinity, y: -Infinity)` - Underflow cases
- Valid coordinates that happen to be `(0,0)` - Edge case where signature is at origin

**Fix:**
```swift
let screenPoint = pdfView.convert(pdfPoint, from: page)
guard screenPoint.x.isFinite && screenPoint.y.isFinite,
      screenPoint.x >= -10000 && screenPoint.x <= 10000,
      screenPoint.y >= -10000 && screenPoint.y <= 10000 else {
    return EmptyView()
}
```

---

### 4. **Race Condition in State Updates**
**Location:** `PDFViewRepresentable.updateUIView()` (Line ~2417)

**Problem:**
```swift
DispatchQueue.main.async {
    self.pdfViewInstance = uiView
}
```
This async dispatch can execute **after the view is deallocated**, causing:
- Setting state on deallocated view
- Memory access violations
- Unpredictable behavior

**Fix:**
```swift
// Direct assignment is safe in updateUIView - it's already on main thread
self.pdfViewInstance = uiView
```

---

### 5. **Thread Safety Issue in Zoom Handler**
**Location:** `Coordinator.handleScaleChange()` (Line ~2461)

**Problem:**
```swift
@objc func handleScaleChange() {
    refreshTrigger = UUID()
}
```
Even though `@MainActor` is on the class, `@objc` selectors are **not guaranteed** to execute on the main thread. This can cause:
- State updates from background thread
- SwiftUI crashes
- UI inconsistencies

**Fix:**
```swift
@objc func handleScaleChange() {
    Task { @MainActor in
        refreshTrigger = UUID()
    }
}
```

---

## Medium Priority Bugs

### 6. **Lifecycle Hook Timing Issues**
**Location:** `UnifiedSignatureOverlay.onAppear/onDisappear` (Lines ~1884-1897)

**Problem:**
The `.onAppear` and `.onDisappear` hooks can fire at unexpected times:
- During rapid zoom changes
- When view hierarchy changes
- During page transitions

This can cause the PDF annotation to flicker or disappear unexpectedly.

**Fix:**
Add guards to prevent unnecessary updates:
```swift
.onAppear {
    guard activeAnnotation?.shouldDisplay != false else { return }
    activeAnnotation?.shouldDisplay = false
    pdfView.setNeedsDisplay()
}
```

---

### 7. **Multiple Async Dispatches Race**
**Location:** `PDFViewRepresentable.makeUIView()` (Line ~2396)

**Problem:**
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    UIView.animate(withDuration: 0.2) {
        pdfView.alpha = 1
    }
    let fitScale = pdfView.scaleFactorForSizeToFit
    pdfView.scaleFactor = fitScale
    pdfView.minScaleFactor = fitScale * 0.2
    self.pdfViewInstance = pdfView
}
```
Multiple state updates in async block can race with SwiftUI updates, causing:
- Zoom level conflicts
- View state inconsistencies
- Animation glitches

**Fix:**
Use a single, coordinated update or use `UIView.performWithoutAnimation` for non-animated changes.

---

### 8. **Weak Reference Not Checked**
**Location:** `Coordinator.pdfViewInstance` usage

**Problem:**
`weak var pdfViewInstance: PDFView?` is used but not always checked before use. If the PDFView is deallocated, accessing it causes crashes.

**Fix:**
Always guard:
```swift
guard let pdfView = pdfViewInstance else { return }
```

---

## Low Priority / Edge Cases

### 9. **Division by Zero Risk**
**Location:** `UnifiedSignatureOverlay` (Line ~1715)

**Problem:**
```swift
let visualHeight = visualWidth / placement.aspectRatio
```
If `placement.aspectRatio` is 0 or very small, this causes infinity or NaN.

**Fix:**
```swift
let aspectRatio = max(0.01, placement.aspectRatio) // Prevent division by zero
let visualHeight = visualWidth / aspectRatio
```

---

### 10. **Coordinate System Confusion**
**Location:** Multiple coordinate conversions

**Problem:**
PDF uses bottom-left origin, SwiftUI uses top-left. Some conversions might not account for this properly, especially in edge cases.

**Recommendation:**
Add comprehensive unit tests for coordinate conversion at various zoom levels.

---

## Summary

**Critical Issues:** 5
**Medium Priority:** 3
**Low Priority:** 2

**Most Dangerous:**
1. NotificationCenter memory leak (#1)
2. Force unwrapping crash (#2)
3. Invalid coordinate handling (#3)

**Recommended Fix Order:**
1. Fix NotificationCenter observer removal
2. Replace force unwraps with safe unwrapping
3. Add comprehensive coordinate validation
4. Fix thread safety issues
5. Add lifecycle guards

