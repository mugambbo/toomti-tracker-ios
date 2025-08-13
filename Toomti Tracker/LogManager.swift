//
//  LogManager.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//

import Foundation
import SwiftUI

// MARK: - Log Models
enum LogLevel: String, CaseIterable {
    case all = "All"
    case info = "Info"
    case warning = "Warning"
    case error = "Error"
    case debug = "Debug"
    
    var displayName: String { rawValue }
    
    var color: Color {
        switch self {
        case .all: return .primary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .debug: return .purple
        }
    }
}

struct LogEntry {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let source: String
    let message: String
}

// MARK: - Log Manager
class LogManager: ObservableObject {
    static let shared = LogManager()
    
    @Published var logs: [LogEntry] = []
    private let maxLogCount = 1000
    
    private init() {}
    
    func log(_ level: LogLevel, source: String, message: String) {
        DispatchQueue.main.async {
            let entry = LogEntry(
                timestamp: Date(),
                level: level,
                source: source,
                message: message
            )
            
            self.logs.append(entry)
            
            // Keep only the most recent logs
            if self.logs.count > self.maxLogCount {
                self.logs.removeFirst(self.logs.count - self.maxLogCount)
            }
        }
        
        // Also print to console for debugging
        print("[\(level.rawValue.uppercased())] \(source): \(message)")
    }
    
    func clearLogs() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

// MARK: - Convenience Extensions
extension LogManager {
    func info(_ source: String, _ message: String) {
        log(.info, source: source, message: message)
    }
    
    func warning(_ source: String, _ message: String) {
        log(.warning, source: source, message: message)
    }
    
    func error(_ source: String, _ message: String) {
        log(.error, source: source, message: message)
    }
    
    func debug(_ source: String, _ message: String) {
        log(.debug, source: source, message: message)
    }
}
