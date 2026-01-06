#!/usr/bin/env python3
"""
Simple Debug Log Server
Listens on Mac's IP address for POST requests from iPhone app
Writes NDJSON logs to .cursor/debug.log
Run: python3 debug_server.py
"""

import json
import http.server
import socketserver
from pathlib import Path
import sys
from datetime import datetime

# Configuration
PORT = 7243  # Using 7243 because Cursor uses 7242
LOG_FILE = Path(__file__).parent / ".cursor" / "debug.log"
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

class DebugLogHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP handler that accepts POST requests and writes to log file"""
    
    def do_POST(self):
        """Handle POST requests - write JSON payload to log file"""
        try:
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            
            # Parse JSON
            try:
                payload = json.loads(body.decode('utf-8'))
            except json.JSONDecodeError:
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'Invalid JSON')
                return
            
            # Write to log file (append mode)
            with open(LOG_FILE, 'a') as f:
                f.write(json.dumps(payload) + '\n')
            
            # Send success response
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            
            # Print to console for immediate feedback
            location = payload.get('location', 'unknown')
            message = payload.get('message', '')
            print(f"[{datetime.now().strftime('%H:%M:%S')}] {location}: {message}")
            
        except Exception as e:
            print(f"ERROR handling request: {e}", file=sys.stderr)
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f'Error: {str(e)}'.encode())
    
    def log_message(self, format, *args):
        """Override to suppress default request logging"""
        pass  # We'll print our own formatted messages

def get_local_ip():
    """Get the local network IP address"""
    import socket
    try:
        # Connect to a remote address to determine local IP
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "0.0.0.0"

def main():
    """Start the debug log server"""
    local_ip = get_local_ip()
    
    print("=" * 60)
    print("DEBUG LOG SERVER")
    print("=" * 60)
    print(f"Listening on: {local_ip}:{PORT}")
    print(f"Log file: {LOG_FILE}")
    print(f"Endpoint: http://{local_ip}:{PORT}/ingest/e1b5a635-d792-4adb-a984-1f1e8f6d202d")
    print(f"Note: Using port {PORT} (Cursor uses 7242)")
    print()
    print("Server is ready to receive logs from iPhone app")
    print("Press Ctrl+C to stop")
    print("=" * 60)
    print()
    
    # Create server that listens on all interfaces (0.0.0.0)
    with socketserver.TCPServer(("0.0.0.0", PORT), DebugLogHandler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n\nStopping server...")
            httpd.shutdown()

if __name__ == "__main__":
    main()

