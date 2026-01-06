# Debug Mode Instructions

## Setup

### 1. Start the Python Monitoring Script

**On your Mac**, open Terminal and run:

```bash
cd "/Users/johnuja/Desktop/Just Scan"
python3 monitor_debug_logs.py
```

This will:
- Start an HTTP server on port 7242 to receive logs from your iOS app
- Display your Mac's IP address (for configuring the iOS app)
- Monitor the debug log file in real-time
- Display colored, formatted log entries

**Keep this terminal window open** - it will show all debug logs in real-time.

### 2. Configure iOS App Network Access

The iOS app needs to send logs to your Mac. The app is configured to use:
- **Local (same Mac):** `http://127.0.0.1:7242/ingest/e1b5a635-d792-4adb-a984-1f1e8f6d202d`
- **Network (from iPhone):** `http://<YOUR_MAC_IP>:7242/ingest/e1b5a635-d792-4adb-a984-1f1e8f6d202d`

**If testing on iPhone**, you may need to update `DebugLogger.swift` to use your Mac's IP address instead of `127.0.0.1`.

### 3. Build and Run the App

Build and run the app on your device (iPhone or Simulator). The app will automatically send debug logs to the monitoring script.

## Test Scenarios

### Test 1: Selection Box Visibility on Tap
1. Open a document with saved signatures
2. **Tap on a signature** (don't drag)
3. **Observe:** Does the selection box appear immediately?
4. **Check logs:** Look for:
   - `handleAnnotationTap` entry
   - `activeSignatureID` state changes
   - `getActiveSignatureScreenRect` calls and results
   - `Selection box appeared` messages

### Test 2: Selection Box on Drag
1. Open a document with saved signatures
2. **Tap and drag a signature**
3. **Observe:** Does the selection box appear during drag?
4. **Check logs:** Compare timing of state changes vs. view rendering

### Test 3: Fixed Toolbar/Rotation Handle Positions
1. Select a signature
2. **Observe:** Are toolbar and rotation handle at fixed positions (not scaling)?
3. Resize the signature
4. **Observe:** Do toolbar and rotation handle stay at same distance from selection box?

### Test 4: State Synchronization
1. Tap a signature
2. **Check logs:** Look for sequence:
   - `setActiveSignature` called
   - `activeSignatureID` state change in controller
   - Combine publisher emission
   - SwiftUI `didSet` observer
   - `getActiveSignatureScreenRect` called
   - Selection box rendering

### Test 5: Coordinate Conversion
1. Select a signature
2. **Check logs:** Look for:
   - PDF rect calculations
   - Screen rect calculations
   - View bounds at conversion time
3. Move the signature
4. **Check logs:** Verify coordinate deltas are correct

## Log Analysis

### Hypothesis A: State Synchronization
Look for logs with `hypothesisId: "A"`:
- `setActiveSignature` entry/exit
- `activeSignatureID` state changes
- Combine publisher emissions
- SwiftUI binding updates

**Key Questions:**
- Is `activeSignatureID` set in controller before SwiftUI queries it?
- Are Combine publishers firing immediately?
- Is there a race condition between state update and view query?

### Hypothesis B: View Rendering Conditions
Look for logs with `hypothesisId: "B"`:
- `getActiveSignatureScreenRect` calls
- Return values (nil vs. valid rect)
- View rendering conditions in `DocumentReviewView`

**Key Questions:**
- Does `getActiveSignatureScreenRect` return a valid rect?
- Are all view rendering conditions met?
- Is the view actually being created but invisible?

### Hypothesis C: Coordinate System
Look for logs with `hypothesisId: "C"`:
- PDF rect calculations
- Screen rect calculations
- View bounds

**Key Questions:**
- Are coordinates in the correct space?
- Is the selection box rendering off-screen?
- Is there a coordinate transform issue?

### Hypothesis E: Race Conditions
Look for logs with `hypothesisId: "E"`:
- Async dispatch timing
- State updates after async blocks

**Key Questions:**
- Is SwiftUI querying state before async blocks complete?
- Are there timing issues with `DispatchQueue.main.async`?

## Log File Location

Logs are written to:
```
/Users/johnuja/Desktop/Just Scan/.cursor/debug.log
```

The file is in NDJSON format (one JSON object per line). You can also view it directly:
```bash
tail -f "/Users/johnuja/Desktop/Just Scan/.cursor/debug.log"
```

## Stopping Debug Mode

1. Press `Ctrl+C` in the terminal running `monitor_debug_logs.py`
2. The app will continue to send logs, but they won't be displayed
3. To completely stop logging, remove debug instrumentation from code

## Troubleshooting

### No logs appearing
- Check that the Python script is running
- Verify network connectivity (if testing on iPhone)
- Check that `DebugLogger.swift` has the correct server endpoint
- Verify the app has network permissions

### Logs appearing but not formatted
- The Python script should handle formatting automatically
- Check that the log file exists and is readable
- Verify NDJSON format (one JSON object per line)

### Server connection errors
- Make sure port 7242 is not in use by another application
- Check firewall settings
- Verify the Mac's IP address is correct (if testing on iPhone)

