#!/usr/bin/env python3
"""
Debug Log Monitor Script
Monitors debug.log file and displays real-time logs from iOS app
The ndjson ingest server is already running - this script just tails the log file
Run this script in terminal: python3 monitor_debug_logs.py
"""

import json
import os
import sys
import time
from pathlib import Path
import queue
from threading import Thread

# Configuration
LOG_FILE = Path(__file__).parent / ".cursor" / "debug.log"
# Note: The ndjson ingest server is already running on port 7242
# This script just monitors the log file that the server writes to

# Color codes for terminal output
COLORS = {
    "ENTRY": "\033[94m",      # Blue
    "EXIT": "\033[92m",       # Green
    "STATE_CHANGE": "\033[93m", # Yellow
    "ERROR": "\033[91m",      # Red
    "HYPOTHESIS": "\033[95m", # Magenta
    "RESET": "\033[0m"        # Reset
}

# Note: The ndjson ingest server is already running and handling HTTP POST requests
# This script just monitors the log file that the server writes to

def tail_log_file(log_file, log_queue):
    """Monitor log file for new entries (tail -f style)"""
    if not log_file.exists():
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_file.touch()
    
    # Read existing logs first
    with open(log_file, 'r') as f:
        lines = f.readlines()
        for line in lines:
            if line.strip():
                log_queue.put(line.strip())
    
    # Monitor for new lines
    with open(log_file, 'r') as f:
        # Seek to end
        f.seek(0, 2)
        
        while True:
            line = f.readline()
            if line:
                log_queue.put(line.strip())
            else:
                time.sleep(0.1)

def format_log_entry(entry):
    """Format log entry for display"""
    try:
        data = json.loads(entry)
        location = data.get('location', 'unknown')
        message = data.get('message', '')
        log_data = data.get('data', {})
        hypothesis_id = data.get('hypothesisId', '')
        timestamp = data.get('timestamp', 0)
        
        # Format timestamp
        time_str = time.strftime('%H:%M:%S', time.localtime(timestamp / 1000))
        
        # Determine color based on message type
        color = COLORS["RESET"]
        if "ENTRY" in message:
            color = COLORS["ENTRY"]
        elif "EXIT" in message:
            color = COLORS["EXIT"]
        elif "STATE_CHANGE" in message:
            color = COLORS["STATE_CHANGE"]
        elif "ERROR" in message or "❌" in message:
            color = COLORS["ERROR"]
        elif hypothesis_id:
            color = COLORS["HYPOTHESIS"]
        
        # Build output
        output = f"{color}[{time_str}] {location}\n"
        output += f"  {message}"
        
        if hypothesis_id:
            output += f" [HYP: {hypothesis_id}]"
        
        if log_data:
            data_str = json.dumps(log_data, indent=2)
            output += f"\n  Data: {data_str}"
        
        output += COLORS["RESET"]
        return output
    except Exception as e:
        return f"[ERROR] Failed to parse log entry: {e}\n  Raw: {entry}"

def display_logs(log_queue):
    """Display logs from queue"""
    while True:
        try:
            entry = log_queue.get(timeout=1)
            print(format_log_entry(entry))
            print()  # Blank line between entries
        except queue.Empty:
            continue
        except KeyboardInterrupt:
            break

# Server is already running - no need to start it here

def main():
    """Main entry point"""
    print("=" * 60)
    print("DEBUG LOG MONITOR")
    print("=" * 60)
    print(f"Log file: {LOG_FILE}")
    print("Note: Make sure debug_server.py is running first!")
    print("      Run: python3 debug_server.py")
    print("      This script monitors the log file in real-time")
    print()
    print("Starting monitor...")
    print("Press Ctrl+C to stop")
    print("=" * 60)
    print()
    
    # Create log queue
    log_queue = queue.Queue()
    
    # Start log file monitor in background thread
    tail_thread = Thread(target=tail_log_file, args=(LOG_FILE, log_queue), daemon=True)
    tail_thread.start()
    
    # Display logs in main thread
    try:
        display_logs(log_queue)
    except KeyboardInterrupt:
        print("\n\nStopping monitor...")
        sys.exit(0)

if __name__ == "__main__":
    main()

