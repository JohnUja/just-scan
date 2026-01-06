# Debug Log Analysis - All Issues

## Issue 1: Signature Switching (SWITCH) - NOT WORKING

**Evidence from logs:**
- ALL switching logs show `previousSignatureID: "nil"`
- This means when you tap a second signature, the first one is already deselected
- The tap handler runs AFTER deselection happens

**Root Cause:**
The "No hit - deselect" logic (Phase 3) runs BEFORE the signature hit detection completes, causing premature deselection.

**Fix Needed:**
Reorder the logic so deselection only happens if NO signature is hit, not before checking.

---

## Issue 2: Signature Bouncing After Save (C) - CONFIRMED

**Evidence from logs:**
```
Before save: center: "(0.28425135644310473, 0.4378456946039036)"
After save:  center: "(0.28425135644310473, 0.43784575200918485)"  // Tiny Y change
Later:        center: "(0.29052769404672196, 0.5812787600459243)"  // Significant change
```

**Root Cause:**
Coordinate conversion when reloading from PDF annotations has rounding errors or coordinate system mismatch.

**Fix Needed:**
Ensure `SignatureModel.fromAnnotation` uses exact same coordinate conversion as when saving.

---

## Issue 3: Color Change Flipping (COLOR) - NOT COORDINATE ISSUE

**Evidence from logs:**
```
centerChanged: false
rotationChanged: false
```

**Root Cause:**
Coordinates don't change, so flipping is likely a visual rendering issue (image transform or annotation bounds).

**Fix Needed:**
Check image transformation when applying color - might be flipping the image during color application.

---

## Issue 4: Share Modes (SHARE) - WORKING ✅

**Evidence from logs:**
- Both secure and flattened share work correctly
- PDFs created successfully
- Share sheets presented

**Status:** No fix needed.

---

## Issue 5: Move Jittering (MOVE) - NO LOGS

**Evidence:** No MOVE logs found in debug output.

**Possible Causes:**
1. Gesture not triggering debug logs
2. User didn't test this scenario
3. Logging frequency too low (every 10th frame)

**Fix Needed:** Add more frequent logging or check if gesture is being recognized.

---

## Issue 6: Rotation Bouncing (ROTATE) - NO LOGS

**Evidence:** No ROTATE logs found in debug output.

**Possible Causes:**
1. Gesture not triggering
2. User didn't test this scenario
3. Logging condition not met

**Fix Needed:** Add entry logging to verify gesture is recognized.

