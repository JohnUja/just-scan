# Debug Logging Quick Start

## Setup

1. **Start the debug server** (on your Mac):
   ```bash
   python3 debug_server.py
   ```
   This will:
   - Listen on `0.0.0.0:7242` (all network interfaces)
   - Display your Mac's IP address
   - Accept POST requests from your iPhone app
   - Write logs to `.cursor/debug.log`

2. **Start the log monitor** (in a separate terminal on your Mac):
   ```bash
   python3 monitor_debug_logs.py
   ```
   This will:
   - Tail the log file in real-time
   - Display formatted, color-coded logs
   - Show all events from your iPhone app

## How It Works

- **iPhone app** → POSTs logs to `http://192.168.40.130:7242/ingest/...`
- **Python server** → Receives POST, writes NDJSON to `.cursor/debug.log`
- **Monitor script** → Tails log file, displays formatted output

## Testing

1. Make sure both scripts are running
2. Open your app on iPhone
3. Perform actions (tap signatures, open documents, save, etc.)
4. Watch logs appear in real-time in the monitor terminal

## Troubleshooting

- **No logs appearing?** Check that:
  - `debug_server.py` is running
  - iPhone and Mac are on the same WiFi network
  - Mac's IP is `192.168.40.130` (update in `DebugLogger.swift` if different)
  - Firewall allows connections on port 7242

- **Connection refused?** Make sure the server is running and listening on `0.0.0.0:7242`
