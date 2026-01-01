# Current Issues Analysis - Just Scan App

## Date: December 17, 2024

---

## 🔴 CRITICAL ISSUES

### Issue #1: Files Not Appearing in HomeView After Save

**Status:** Partially Fixed (may still occur)

**Files Affected:**
- `Just Scan/Views/HomeView.swift` (lines 213-233)
- `Just Scan/Services/DocumentService.swift` (lines 26-46, 48-67, 69-103)

**Problem Description:**
After scanning and saving documents, the PDF files are created on disk but thumbnails don't appear in the HomeView grid immediately. User reports files "still don't save or appear to be saved."

**Why I Think It's Happening:**
1. **Timing Issue:** File system write might not be flushed before `loadDocuments()` is called
2. **SwiftUI Observation:** `@StateObject` might not be detecting the `@Published` change properly
3. **Threading:** `loadDocuments()` might be called before file is fully written to disk
4. **File System Cache:** iOS file system might cache directory listings

**Current Fix Attempts:**
- Added 0.1 second delay after save
- Added `objectWillChange.send()` to force UI refresh
- Wrapped in `Task { @MainActor in }`

**Questions for Expert:**
1. Is there a better way to ensure file system writes are complete before reading directory?
2. Should we use `FileManager.default.synchronize()` or similar?
3. Is there a SwiftUI-specific pattern for observing file system changes?
4. Should we use Combine's `PassthroughSubject` instead of `@Published` for more control?
5. Would `NSFileCoordinator` help with file system synchronization?

---

### Issue #2: Edit Mode Shows Black Screen

**Status:** Partially Fixed (may still occur)

**Files Affected:**
- `Just Scan/Views/HomeView.swift` (lines 235-250, 96-110)
- `Just Scan/Services/DocumentService.swift` (lines 118-136)
- `Just Scan/Views/IntegratedScannerView.swift` (lines 27-36)

**Problem Description:**
When user taps a saved document thumbnail to edit, the screen goes black instead of showing the edit interface with pages.

**Why I Think It's Happening:**
1. **State Race Condition:** `showEditMode = true` is set before `editImages` array is populated
2. **PDF Extraction Failure:** `images(from:)` might be returning empty array silently
3. **Init Timing:** `IntegratedScannerView` init checks `existingImages.isEmpty` - if empty, shows camera (black screen)
4. **Async Extraction:** PDF to UIImage conversion might be failing or taking too long
5. **FullScreenCover Binding:** The `if let document = editDocument` guard might be failing

**Current Fix Attempts:**
- Added loading state with spinner
- Made extraction async with `Task`
- Added guard to prevent showing if images empty
- Added debug logging

**Questions for Expert:**
1. Is there a better pattern for async data loading before showing SwiftUI views?
2. Should we use `@State` with optional binding instead of separate flags?
3. How do we properly handle PDF extraction errors that might return empty arrays?
4. Is `fullScreenCover` the right presentation mode, or should we use `NavigationStack`?
5. Should we pre-extract images when document is selected, not when edit mode opens?

---

### Issue #3: Reorder Step Not Visible/Working in Scan Mode

**Status:** Partially Fixed (UX issue)

**Files Affected:**
- `Just Scan/Views/IntegratedScannerView.swift` (lines 42-114, 127-200)
- `Just Scan/Views/IntegratedScannerView.swift` (lines 220-250 - ReorderDelegate)

**Problem Description:**
After scanning completes, user doesn't see or understand they can reorder pages. The review/reorder interface exists but isn't obvious enough. User asks: "no step still in the scannable mode to sort or order drag and drop scanned pages"

**Why I Think It's Happening:**
1. **UX Clarity:** Transition from camera to review mode isn't obvious
2. **Visual Hierarchy:** Review tray might be too subtle
3. **User Expectation:** User expects reorder DURING scan (like Evernote), not AFTER
4. **Timing:** Original `PageReorderView` was a separate full-screen view - more obvious
5. **Instructions:** Text instructions might not be clear enough

**Current Fix Attempts:**
- Added prominent "Review & Reorder" header
- Added instructions with icons
- Added animations for transition
- Made tray more visually prominent

**Questions for Expert:**
1. Should we show a modal/interstitial screen between scan and review to make it clear?
2. Is there a way to show horizontal tray OVER the camera (hybrid approach)?
3. Should we use a different presentation style (sheet vs fullScreenCover)?
4. Would haptic feedback help indicate reorder is available?
5. Should we add a tutorial/onboarding for first-time users?

---

## 🟡 MEDIUM PRIORITY ISSUES

### Issue #4: Signature Flow Confusion

**Status:** Partially Fixed

**Files Affected:**
- `Just Scan/Views/DocumentReviewView.swift` (lines 82-112)
- `Just Scan/Views/IntegratedScannerView.swift` (lines 400-500 - VectorSignaturePlacementView)

**Problem Description:**
User confusion about signature flow: "preview signature works, however once the user creates a signature its not meant to preview the signature, its meant to appear as the layer on the users open file no??"

**Why I Think It's Happening:**
1. **Flow Logic:** After creating signature, it shows preview instead of going to placement
2. **User Expectation:** User expects signature to appear on document immediately
3. **State Management:** Multiple signature-related states might be conflicting

**Current Fix Attempts:**
- Changed flow to go directly to edit mode after signature creation
- Added "Place Signature" option

**Questions for Expert:**
1. What's the best UX pattern for signature creation → placement flow?
2. Should signature auto-place on current page, or always require user placement?
3. Should we save signature placement state separately from the document?

---

### Issue #5: Document Thumbnail Tap Behavior

**Status:** Fixed (but user reported it wasn't working)

**Files Affected:**
- `Just Scan/Views/HomeView.swift` (lines 45-51, 235-250)
- `Just Scan/Views/DocumentGridView.swift` (lines 32-34)

**Problem Description:**
User asked: "the edit tap thumbnail to edit pulls up a black screen every time, questions is it because i asked you to use a page instead of a view??"

**Why I Think It's Happening:**
- Related to Issue #2 (black screen)
- User confusion about "page vs view" - this is likely not the cause
- The black screen is from edit mode not loading properly

**Questions for Expert:**
1. Is there a semantic difference between using `.sheet` vs `.fullScreenCover` for edit mode?
2. Should edit mode be a NavigationStack instead of fullScreenCover?
3. Does SwiftUI have issues with fullScreenCover and async data loading?

---

## 🟢 ARCHITECTURAL QUESTIONS

### Question #1: Should We Use SwiftData?

**Context:**
User mentioned: "i know we are not saving in the conventional way is using swift data, but just as a thumbnail on the ui isnt that bare minimum and implementable?"

**Current Approach:**
- Using `FileManager` to scan directory
- Using `@Published` array in `DocumentService`
- No database/persistence layer

**Questions for Expert:**
1. Would SwiftData help with UI refresh issues?
2. Is FileManager + @Published sufficient for this use case?
3. Should we use Core Data or SwiftData for document metadata?
4. Would a database help with thumbnail caching and performance?

---

### Question #2: Custom Scanner vs VisionKit

**Context:**
User asked about building custom scanner like Evernote with horizontal tray during scan.

**Current Approach:**
- Using `VNDocumentCameraViewController` (VisionKit)
- Shows review/reorder AFTER scan completes

**Questions for Expert:**
1. Can we overlay UI on top of VisionKit's camera view?
2. Should we build custom scanner with AVFoundation for more control?
3. What's the performance impact of custom edge detection vs VisionKit?
4. Is there a hybrid approach (VisionKit + custom overlay)?

---

### Question #3: State Management Pattern

**Context:**
We've had issues with state synchronization between views.

**Current Approach:**
- `@StateObject` for services
- `@State` for local view state
- `@Binding` for parent-child communication
- In-memory `[UIImage]` arrays for editing

**Questions for Expert:**
1. Should we use a state management library (TCA, Redux, etc.)?
2. Is our current pattern sufficient but just needs better error handling?
3. Should we use `@Observable` macro instead of `ObservableObject`?
4. How do we properly handle async state updates in SwiftUI?

---

### Question #4: PDF Extraction Performance

**Context:**
PDF to UIImage extraction might be slow or failing.

**Files Affected:**
- `Just Scan/Services/DocumentService.swift` (lines 118-136)

**Questions for Expert:**
1. Is rendering PDF pages to UIImage the best approach?
2. Should we cache extracted images?
3. How do we handle large PDFs (100+ pages)?
4. Should we extract on background thread and show loading?
5. Is there a way to extract thumbnails instead of full-resolution images for editing?

---

## 📋 SUMMARY OF FILES WITH ISSUES

### High Priority Files:
1. **HomeView.swift** - Save/refresh logic, edit mode opening
2. **DocumentService.swift** - File I/O, document loading, PDF extraction
3. **IntegratedScannerView.swift** - Review/reorder UI, state management

### Medium Priority Files:
1. **DocumentReviewView.swift** - Signature flow
2. **DocumentGridView.swift** - Thumbnail tap handling

---

## 🎯 RECOMMENDED EXPERT CONSULTATION TOPICS

1. **SwiftUI State Management & File System Observation**
   - Best practices for observing file system changes
   - Proper async state loading patterns
   - When to use @Published vs other observation patterns

2. **PDF Handling & Performance**
   - Efficient PDF to UIImage conversion
   - Caching strategies for large documents
   - Background processing patterns

3. **VisionKit vs Custom Scanner**
   - Limitations of VisionKit for custom UI
   - AVFoundation implementation complexity
   - Hybrid approaches

4. **SwiftUI Presentation & Navigation**
   - fullScreenCover vs sheet vs NavigationStack
   - Handling async data loading before presentation
   - State synchronization across view hierarchy

5. **File System & Persistence**
   - FileManager best practices
   - When to use SwiftData/Core Data vs FileManager
   - Ensuring file writes complete before reads

---

## 🔍 DEBUGGING SUGGESTIONS

1. Add more comprehensive logging throughout the save/load flow
2. Add file existence checks before/after save operations
3. Add timing measurements for PDF extraction
4. Add state dump logging to see what values are when black screen appears
5. Test on physical device (not just simulator) - file system behavior differs

---

## 📝 NOTES

- All fixes have been attempted but issues may persist due to underlying architecture
- User wants expert consultation before further implementation
- Some issues might be UX/design problems rather than technical bugs
- Need to distinguish between "not working" vs "not obvious to user"




