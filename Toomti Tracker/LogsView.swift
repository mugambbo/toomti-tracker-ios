//
//  LogsView.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//

import SwiftUI

struct LogsView: View {
    @StateObject private var logManager = LogManager.shared
    @State private var selectedFilter: LogLevel = .all
    @State private var searchText = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search and Filter
                VStack(spacing: 12) {
                    SearchBar(text: $searchText)
                    
                    LogFilterPicker(selectedFilter: $selectedFilter)
                }
                .padding()
                .background(Color(.systemGray6))
                
                // Logs List
                List {
                    ForEach(filteredLogs, id: \.id) { log in
                        LogEntryView(log: log)
                    }
                }
                .listStyle(PlainListStyle())
            }
            .navigationTitle("System Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Clear All Logs") {
                            logManager.clearLogs()
                        }
                        
                        Button("Export Logs") {
                            // TODO: Implement log export
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
    
    private var filteredLogs: [LogEntry] {
        var logs = logManager.logs
        
        if selectedFilter != .all {
            logs = logs.filter { $0.level == selectedFilter }
        }
        
        if !searchText.isEmpty {
            logs = logs.filter { log in
                log.message.localizedCaseInsensitiveContains(searchText) ||
                log.source.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return logs.reversed() // Show newest first
    }
}

// MARK: - Log Components
struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search logs...", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
        }
    }
}

struct LogFilterPicker: View {
    @Binding var selectedFilter: LogLevel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Button(level.displayName) {
                        selectedFilter = level
                    }
                    .buttonStyle(FilterButtonStyle(isSelected: selectedFilter == level))
                }
            }
            .padding(.horizontal)
        }
    }
}

struct FilterButtonStyle: ButtonStyle {
    let isSelected: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct LogEntryView: View {
    let log: LogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(log.source)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(log.level.color)
                
                Spacer()
                
                Text(log.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(log.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
