//
//  DashboardView.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//

import SwiftUI
import CoreLocation

struct DashboardView: View {
    @StateObject private var obdManager = OBDManager.shared
    @StateObject private var locationManager = LocationManager.shared
    @State private var hasRequestedLocationPermission = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection Status Cards
                    connectionStatusSection
                    
                    // Vehicle Data if available
                    if let data = obdManager.currentVehicleData {
                        vehicleDataSection(data: data)
                    }
                    
                    // Control Buttons
                    controlButtonsSection
                    
                    // Last Upload Status
                    lastUploadSection
                }
                .padding()
            }
            .navigationTitle("Toomti Tracker")
            .onAppear {
                requestLocationPermissionOnce()
                obdManager.startBackgroundMonitoring()
            }
        }
    }
    
    // MARK: - View Components
    
    private var connectionStatusSection: some View {
        VStack(spacing: 12) {
            Text("Connection Status")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 12) {
                StatusCard(
                    title: "OBD",
                    status: obdManager.connectionStatus,
                    isConnected: obdManager.isConnected,
                    icon: "car.circle"
                )
                
                StatusCard(
                    title: "Location",
                    status: locationManager.authorizationStatus,
                    isConnected: locationManager.isAuthorized,
                    icon: "location.circle"
                )
            }
            
            // Permission buttons if needed
            if locationManager.authorizationStatus == "Not Determined" {
                Button("Request Location Permission") {
                    locationManager.forceRequestPermission()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            
            if locationManager.authorizationStatus.contains("Denied") {
                Button("Open Settings") {
                    if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsUrl)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
    
    private func vehicleDataSection(data: VehicleData) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Vehicle Data")
                    .font(.headline)
                Spacer()
                Text("Protocol: \(data.protocolName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Primary Metrics
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                MetricCard(title: "RPM", value: "\(Int(data.rpm))", unit: "")
                MetricCard(title: "Speed", value: "\(Int(data.speed))", unit: "km/h")
                MetricCard(title: "Engine Load", value: "\(Int(data.engineLoad))", unit: "%")
                MetricCard(title: "Coolant", value: "\(Int(data.coolantTemp))", unit: "°C")
            }
            
            // Secondary Metrics (Expandable)
            DisclosureGroup("Advanced Metrics") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                    MetricCard(title: "Throttle", value: "\(Int(data.throttlePosition))", unit: "%")
                    MetricCard(title: "Voltage", value: String(format: "%.1f", data.voltage), unit: "V")
                    MetricCard(title: "Intake Temp", value: "\(Int(data.intakeAirTemp))", unit: "°C")
                    MetricCard(title: "Fuel Level", value: "\(Int(data.fuelLevel))", unit: "%")
                    MetricCard(title: "MAF Rate", value: String(format: "%.1f", data.mafRate), unit: "g/s")
                    MetricCard(title: "Runtime", value: "\(data.engineRuntime / 60)", unit: "min")
                }
                .padding(.top, 12)
            }
            .accentColor(.blue)
            
            // Diagnostic Info
            if data.milOn || data.dtcCount > 0 {
                DiagnosticCard(data: data)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var controlButtonsSection: some View {
        VStack(spacing: 12) {
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
            
            HStack(spacing: 12) {
                Button("Send Test Data") {
                    obdManager.sendTestData()
                }
                .buttonStyle(TertiaryButtonStyle())
                
                Button("Clear DTCs") {
                    obdManager.clearTroubleCodes()
                }
                .buttonStyle(TertiaryButtonStyle())
                .disabled(!obdManager.isConnected)
            }
        }
    }
    
    private var lastUploadSection: some View {
        VStack(spacing: 8) {
            Text("Last Upload")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(obdManager.lastUploadTime)
                .font(.caption)
                .foregroundColor(.primary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    
    // MARK: - Helper Methods
    
    private func requestLocationPermissionOnce() {
        if !hasRequestedLocationPermission {
            hasRequestedLocationPermission = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                locationManager.requestPermission()
            }
        }
    }
}
