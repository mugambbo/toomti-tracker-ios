//
//  DeviceSettingsView.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 12/08/2025.
//

import SwiftUI

struct DeviceSettingsView: View {
    @StateObject private var deviceManager = DeviceSettingsManager()
    @State private var showingAddDevice = false
    @State private var showingEditDevice: OBDDevice?
    @State private var showingDeleteAlert = false
    @State private var deviceToDelete: OBDDevice?

    var body: some View {
        NavigationView {
            List {
                // Current Device Section
                Section {
                    if let currentDevice = deviceManager.currentDevice {
                        currentDeviceCard(currentDevice)
                    } else {
                        noDeviceCard
                    }
                } header: {
                    Text("Current Device")
                }

                // Device List Section
                Section {
                    if deviceManager.hasDevices() {
                        ForEach(deviceManager.devices) { device in
                            DeviceRowView(
                                device: device,
                                isSelected: device.id == deviceManager.currentDevice?.id,
                                onSelect: { deviceManager.setAsDefault(device) },
                                onEdit: { showingEditDevice = device },
                                onDelete: {
                                    deviceToDelete = device
                                    showingDeleteAlert = true
                                }
                            )
                        }
                    } else {
                        emptyListView
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .listRowInsets(EdgeInsets())
                    }
                } header: {
                    Text("All Devices")
                }
            }
            .navigationTitle("OBD Devices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddDevice = true
                    } label: {
                        Label("Add Device", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddDevice) {
            AddDeviceView(deviceManager: deviceManager)
        }
        .sheet(item: $showingEditDevice) { device in
            EditDeviceView(device: device, deviceManager: deviceManager)
        }
        .alert("Delete Device", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let device = deviceToDelete {
                    deviceManager.removeDevice(device)
                    deviceToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deviceToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete '\(deviceToDelete?.name ?? "")'?")
        }
    }

    // MARK: - Subviews

    private func currentDeviceCard(_ device: OBDDevice) -> some View {
        HStack {
            Image(systemName: device.type.icon)
                .foregroundColor(.blue)
                .font(.title2)

            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.headline)
                Text(device.type.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Edit button
            Button("Edit") { showingEditDevice = device }
                .buttonStyle(.bordered)
                .controlSize(.small)

            // Delete button
            Button(role: .destructive) {
                deviceToDelete = device
                showingDeleteAlert = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }


    private var noDeviceCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.largeTitle)
            Text("No Device Selected")
                .font(.headline)
            Text("Add a device to get started")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Add First Device") { showingAddDevice = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var emptyListView: some View {
        VStack(spacing: 12) {
            Image(systemName: "car.circle.fill")
                .foregroundColor(.gray)
                .font(.system(size: 50))
            Text("No Devices Added")
                .font(.headline)
            Text("Add your OBD devices to manage them easily")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Add Your First Device") { showingAddDevice = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    // MARK: - Current Device Section
    
    private var currentDeviceSection: some View {
        VStack(spacing: 16) {
            if let currentDevice = deviceManager.currentDevice {
                VStack(spacing: 8) {
                    Label("Current Device", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    HStack {
                        Image(systemName: currentDevice.type.icon)
                            .foregroundColor(.blue)
                            .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentDevice.name)
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text(currentDevice.type.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Edit") {
                            showingEditDevice = currentDevice
                        }
                        .buttonStyle(BorderedButtonStyle())
                        .controlSize(.small)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(12)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundColor(.orange)
                    
                    Text("No Device Selected")
                        .font(.headline)
                    
                    Text("Add a device to get started")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Add First Device") {
                        showingAddDevice = true
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - Device List Section
    
    private var deviceListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if deviceManager.hasDevices() {
                HStack {
                    Text("All Devices")
                        .font(.headline)
                    Spacer()
                    Text("\(deviceManager.getDeviceCount()) device\(deviceManager.getDeviceCount() == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                
                LazyVStack(spacing: 8) {
                    ForEach(deviceManager.devices) { device in
                        DeviceRowView(
                            device: device,
                            isSelected: device.id == deviceManager.currentDevice?.id,
                            onSelect: {
                                deviceManager.setAsDefault(device)
                            },
                            onEdit: {
                                showingEditDevice = device
                            },
                            onDelete: {
                                deviceToDelete = device
                                showingDeleteAlert = true
                            }
                        )
                    }
                }
                .padding(.horizontal)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    
                    Image(systemName: "car.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    
                    Text("No Devices Added")
                        .font(.title2)
                        .fontWeight(.medium)
                    
                    Text("Add your OBD devices to manage them easily")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Add Your First Device") {
                        showingAddDevice = true
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.large)
                    
                    Spacer()
                }
                .padding()
            }
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Device Row View

struct DeviceRowView: View {
    let device: OBDDevice
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Device Icon
            Image(systemName: device.type.icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            // Device Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    
                    if device.isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                
                HStack {
                    Text(device.type.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Added \(device.dateAdded.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Action Buttons
            HStack(spacing: 8) {
                if !isSelected {
                    Button("Select") {
                        onSelect()
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .controlSize(.small)
                }
                
                Menu {
                    Button("Edit", action: onEdit)
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding()
        .background(isSelected ? Color.green.opacity(0.1) : Color(.systemGray6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.green : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Add Device View

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    let deviceManager: DeviceSettingsManager
    
    @State private var deviceName = ""
    @State private var deviceType: OBDDevice.DeviceType = .wifi
    @State private var showingValidationError = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add New Device")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Device Name")
                            .font(.headline)
                        
                        TextField("Enter device name (e.g., TOOMTI123456)", text: $deviceName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        Text("Enter the exact device name from your OBD adapter")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connection Type")
                            .font(.headline)
                        
                        Picker("Device Type", selection: $deviceType) {
                            ForEach(OBDDevice.DeviceType.allCases, id: \.self) { type in
                                Label(type.rawValue, systemImage: type.icon)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                }
                
                Spacer()
                
                VStack(spacing: 12) {
                    Button("Add Device") {
                        addDevice()
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.large)
                    .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
            }
            .padding()
            .navigationBarHidden(true)
        }
        .alert("Invalid Device Name", isPresented: $showingValidationError) {
            Button("OK") { }
        } message: {
            Text("Please enter a valid device name.")
        }
    }
    
    private func addDevice() {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedName.isEmpty else {
            showingValidationError = true
            return
        }
        
        deviceManager.addDevice(name: trimmedName, type: deviceType)
        dismiss()
    }
}

// MARK: - Edit Device View

struct EditDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    let device: OBDDevice
    let deviceManager: DeviceSettingsManager
    
    @State private var deviceName: String
    @State private var deviceType: OBDDevice.DeviceType
    @State private var showingValidationError = false
    
    init(device: OBDDevice, deviceManager: DeviceSettingsManager) {
        self.device = device
        self.deviceManager = deviceManager
        self._deviceName = State(initialValue: device.name)
        self._deviceType = State(initialValue: device.type)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Edit Device")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Device Name")
                            .font(.headline)
                        
                        TextField("Device name", text: $deviceName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connection Type")
                            .font(.headline)
                        
                        Picker("Device Type", selection: $deviceType) {
                            ForEach(OBDDevice.DeviceType.allCases, id: \.self) { type in
                                Label(type.rawValue, systemImage: type.icon)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    
                    if device.isDefault {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("This is your default device")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        .padding(.top, 8)
                    }
                }
                
                Spacer()
                
                VStack(spacing: 12) {
                    Button("Save Changes") {
                        saveChanges()
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .controlSize(.large)
                    .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
            }
            .padding()
            .navigationBarHidden(true)
        }
        .alert("Invalid Device Name", isPresented: $showingValidationError) {
            Button("OK") { }
        } message: {
            Text("Please enter a valid device name.")
        }
    }
    
    private func saveChanges() {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedName.isEmpty else {
            showingValidationError = true
            return
        }
        
        deviceManager.updateDevice(device, newName: trimmedName, newType: deviceType)
        dismiss()
    }
}
