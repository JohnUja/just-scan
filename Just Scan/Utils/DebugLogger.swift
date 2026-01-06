//
//  DebugLogger.swift
//  Just Scan
//
//  Debug logging utility for runtime instrumentation
//

import Foundation

/// Centralized debug logging that writes to NDJSON file
/// Logs are sent via HTTP POST to debug server, which writes to .cursor/debug.log
@MainActor
class DebugLogger {
    static let shared = DebugLogger()
    
    // Server endpoint - iPhone connects to Mac's IP, Simulator uses localhost
    // Using port 7243 because Cursor's ndjson server uses 7242
    private var serverEndpoint: String {
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:7243/ingest/e1b5a635-d792-4adb-a984-1f1e8f6d202d"
        #else
        // iPhone: connect to Mac's IP on same network
        return "http://192.168.40.130:7243/ingest/e1b5a635-d792-4adb-a984-1f1e8f6d202d"
        #endif
    }
    
    private let sessionId = UUID().uuidString
    
    private init() {}
    
    /// Log a debug message with structured data
    func log(
        location: String,
        message: String,
        data: [String: Any] = [:],
        hypothesisId: String? = nil,
        runId: String = "run1"
    ) {
        let payload: [String: Any] = [
            "id": "log_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "location": location,
            "message": message,
            "data": data,
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId ?? ""
        ]
        
        // Send HTTP POST to debug server on Mac
        guard let url = URL(string: serverEndpoint),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("⚠️ DebugLogger: Failed to create request")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        // Fire and forget - server writes to log file
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("⚠️ DebugLogger HTTP error: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("⚠️ DebugLogger HTTP status: \(httpResponse.statusCode)")
            }
        }.resume()
    }
    
    
    /// Convenience method for function entry
    func logEntry(_ function: String, file: String = #file, line: Int = #line, params: [String: Any] = [:], hypothesisId: String? = nil) {
        let location = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        log(location: location, message: "ENTRY: \(function)", data: params, hypothesisId: hypothesisId)
    }
    
    /// Convenience method for function exit
    func logExit(_ function: String, file: String = #file, line: Int = #line, result: Any? = nil, hypothesisId: String? = nil) {
        let location = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        var data: [String: Any] = [:]
        if let result = result {
            data["result"] = String(describing: result)
        }
        log(location: location, message: "EXIT: \(function)", data: data, hypothesisId: hypothesisId)
    }
    
    /// Convenience method for state changes
    func logStateChange(_ key: String, oldValue: Any?, newValue: Any?, file: String = #file, line: Int = #line, hypothesisId: String? = nil) {
        let location = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        log(
            location: location,
            message: "STATE_CHANGE: \(key)",
            data: [
                "oldValue": String(describing: oldValue ?? "nil"),
                "newValue": String(describing: newValue ?? "nil")
            ],
            hypothesisId: hypothesisId
        )
    }
    
    /// Convenience method for hypothesis testing
    func logHypothesis(_ hypothesisId: String, message: String, data: [String: Any] = [:], file: String = #file, line: Int = #line) {
        let location = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        log(location: location, message: message, data: data, hypothesisId: hypothesisId)
    }
}

