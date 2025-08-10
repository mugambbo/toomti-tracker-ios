//
//  ContentView.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//

import SwiftUI
import CoreLocation

struct ContentView: View {
    @StateObject private var obdManager = OBDManager.shared
    @StateObject private var locationManager = LocationManager()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Connection Status
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle()
                            .fill(obdManager.isConnected ? .green : .red)
                            .frame(width: 12, height: 12)
                        Text("OBD Status: \(obdManager.connectionStatus)")
                            .font(.headline)
                    }
                    
                    HStack {
                        Circle()
                            .fill(locationManager.isAuthorized ? .green : .orange)
                            .frame(width: 12, height: 12)
                        Text("Location: \(locationManager.authorizationStatus)")
                            .font(.headline)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                
                // OBD Data Display
                if obdManager.isConnected {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vehicle Data")
                            .font(.title2)
                            .bold()
                        
                        if let data = obdManager.currentVehicleData {
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 10) {
                                DataCard(title: "RPM", value: "\(Int(data.rpm))")
                                DataCard(title: "Speed", value: "\(Int(data.speed)) km/h")
                                DataCard(title: "Engine Load", value: "\(Int(data.engineLoad))%")
                                DataCard(title: "Coolant Temp", value: "\(Int(data.coolantTemp))°C")
                                DataCard(title: "Throttle", value: "\(Int(data.throttlePosition))%")
                                DataCard(title: "Voltage", value: String(format: "%.1fV", data.voltage))
                            }
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)
                }
                
                // Control Buttons
                VStack(spacing: 10) {
                    if !obdManager.isConnected {
                        Button("Connect to OBD") {
                            obdManager.connect()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Disconnect") {
                            obdManager.disconnect()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    
                    Button("Send Test Data") {
                        obdManager.sendTestData()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!obdManager.isConnected)
                }
                
                Spacer()
                
                // Status Log
                Text("Last Upload: \(obdManager.lastUploadTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .navigationTitle("OBD Tracker")
            .onAppear {
                locationManager.requestPermission()
                obdManager.startBackgroundMonitoring()
            }
        }
    }
}

struct DataCard: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .bold()
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(radius: 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.blue)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}
