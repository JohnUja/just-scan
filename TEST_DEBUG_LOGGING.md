# Testing Debug Logging - Step by Step

## What You Should See

When everything is working, you should see logs appearing in:
1. **Terminal** (if monitoring script is running)
2. **`.cursor/debug.log` file**

## Current Issue

The log file is **empty**, which means either:
- App isn't sending logs (network/connection issue)
- App hasn't reached code paths with DebugLogger calls yet
- HTTP requests are failing silently

## Quick Test Steps

### 1. Check if Monitoring Script is Running

**In Terminal, run:**
```bash
ps aux | grep monitor_debug_logs.py | grep -v grep
```

If nothing shows, start it:
```bash
cd "/Users/johnuja/Desktop/Just Scan"
python3 monitor_debug_logs.py
```

### 2. Check if Server is Running

**In Terminal, run:**
```bash
lsof -ti:7242
```

Should show a process ID (currently: 20875)

### 3. Test with Simulator First (Easier)

**If testing on Simulator:**
- `127.0.0.1` should work automatically
- Build and run on Simulator
- Open a document
- **You should immediately see a log** when `DocumentReviewView` appears (I just added a test log)

### 4. Test with iPhone (Requires IP Update)

**If testing on iPhone:**

1. **Find your Mac's IP:**
   ```bash
   ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1
   ```

2. **Update `DebugLogger.swift` line 16:**
   Replace `127.0.0.1` with your Mac's IP (e.g., `192.168.1.100`)

3. **Rebuild the app**

4. **Make sure iPhone and Mac are on same WiFi**

### 5. What to Look For

**When you open a document, you should see:**
```
[HH:MM:SS] DocumentReviewView.swift:164
  DocumentReviewView appeared [HYP: A]
  Data: {
    "document": "your-document-name.pdf"
  }
```

**When you tap a signature, you should see:**
```
[HH:MM:SS] DocumentReviewView.swift:35
  STATE_CHANGE: activeSignatureID [HYP: A]
  Data: {
    "oldValue": "nil",
    "newValue": "UUID-here"
  }
```

## If Still Nothing Appears

1. **Check Xcode console** - Look for `⚠️ DebugLogger HTTP error:` messages
2. **Check network** - Try pinging from iPhone to Mac
3. **Check firewall** - Make sure port 7242 isn't blocked
4. **Verify app is running** - Make sure it didn't crash on launch

## Next Steps

Once you see logs appearing, we can analyze them to debug the selection box issue!

