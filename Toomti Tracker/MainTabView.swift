//
//  MainTabView.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Image(systemName: "car.fill")
                    Text("Dashboard")
                }
            
            LogsView()
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("Logs")
                }
            
            DeviceSettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
        .accentColor(.blue)
    }
}
