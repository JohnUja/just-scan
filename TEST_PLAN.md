# Debug Test Plan

## Test Instructions

### Test 1: Signature Switching Without Save (SWITCH)
**Goal:** Verify you can select signature A, then immediately select signature B without saving

**Steps:**
1. Open a document with at least 2 signatures on the same page
2. Tap on signature A - should see selection box appear
3. **IMMEDIATELY** tap on signature B (without saving) - should switch selection
4. Check logs for "SWITCH" hypothesis entries

**Expected Logs:**
- `handleAnnotationTap` entry with `currentActiveID` showing signature A
- `✅ Switching signature selection` with both IDs
- Selection box should switch to signature B

---

### Test 2: Signature Bouncing After Save (C)
**Goal:** Identify why signature position shifts after save

**Steps:**
1. Insert a new signature (or select existing)
2. Move it to a specific position
3. **SAVE** the document
4. Observe if signature position changes/bounces
5. Check logs for coordinate changes

**Expected Logs:**
- `saveToDisk` with "Reloading PDF after save"
- `After reload - checking if signatures moved` with coordinate data
- Compare `center` values before/after reload

---

### Test 3: Signature Bouncing During Rotation (ROTATE)
**Goal:** Identify why signature bounces while rotating after save

**Steps:**
1. Insert a signature and **SAVE**
2. Select the saved signature
3. Rotate it using the rotation handle
4. Observe if signature bounces/jumps during rotation
5. Check logs for rotation coordinate changes

**Expected Logs:**
- `handleRotation` entry with `isCommitted: true`
- `Rotation gesture changed` entries showing rotation values
- `Updating committed annotation during rotation` entries
- Check if `center` changes unexpectedly during rotation

---

### Test 4: Move Icon Jittering (MOVE)
**Goal:** Identify why floating toolbar move icon causes jittery movement

**Steps:**
1. Select a signature
2. Drag the move icon on the floating toolbar
3. Observe if movement is jittery/not smooth
4. Check logs for pan gesture updates

**Expected Logs:**
- `handlePan` entry
- `Pan gesture changed` entries (logged every 10th frame)
- Check `velocity` values for sudden changes
- Check if `location` updates are smooth

---

### Test 5: Signature Flipping on Color Change (COLOR)
**Goal:** Identify why signature flips on x/y axis when color changes

**Steps:**
1. Select a signature
2. Change its color using the color picker
3. Observe if signature flips or transforms unexpectedly
4. Check logs for coordinate/rotation changes

**Expected Logs:**
- `changeActiveSignatureColor` entry
- `Before color change` with `center` and `rotation`
- `After color change` with `centerChanged` and `rotationChanged` flags
- If flags are true, investigate why coordinates changed

---

### Test 6: Share Modes (SHARE)
**Goal:** Verify share flatten and share secured work correctly

**Steps:**
1. Add signatures to document
2. Tap menu (three dots) → "Share Secured PDF"
3. Verify share sheet appears
4. Cancel and try "Share Flattened PDF"
5. Verify share sheet appears
6. Check logs for errors

**Expected Logs:**
- `performSecureShare` or `performFlattenedShare` entry
- `Created secured PDF` or `Created flattened PDF`
- `PDF written to temp file` with `fileExists: true`
- `✅ Presenting share sheet`
- No error logs

---

### Test 7: Memory Leak Check
**Goal:** Check for memory leaks during signature operations

**Steps:**
1. Open document
2. Add 5+ signatures
3. Switch between signatures multiple times
4. Rotate, move, resize signatures
5. Save and reload
6. Repeat steps 2-5 several times
7. Check Xcode memory profiler for leaks

**Expected:** No memory leaks, memory should stabilize

---

### Test 8: Performance (Laggy Signatures)
**Goal:** Identify performance bottlenecks

**Steps:**
1. Add 10+ signatures to a page
2. Try to move/rotate/resize signatures
3. Observe frame rate and responsiveness
4. Check logs for excessive render calls

**Expected:** Smooth 60fps, no lag

---

## Log Analysis

After running tests, check logs for:
- **SWITCH**: Signature switching without save
- **C**: Coordinate changes after save
- **ROTATE**: Rotation bouncing
- **MOVE**: Move jittering
- **COLOR**: Color change flipping
- **SHARE**: Share functionality errors

Each hypothesis has a unique ID in the logs for easy filtering.

