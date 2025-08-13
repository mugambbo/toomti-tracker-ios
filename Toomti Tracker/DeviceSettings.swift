//
//  DeviceSettings.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 12/08/2025.
//

import Foundation
import UIKit

struct OBDDevice: Identifiable, Codable {
    let id = UUID()
    var name: String
    var type: DeviceType
    var isDefault: Bool
    var dateAdded: Date
    
    enum DeviceType: String, CaseIterable, Codable {
        case wifi = "WiFi"
        case bluetooth = "Bluetooth"
        case unknown = "Unknown"
        
        var icon: String {
            switch self {
            case .wifi: return "wifi"
            case .bluetooth: return "bluetooth"
            case .unknown: return "questionmark.circle"
            }
        }
    }
}

class DeviceSettingsManager: ObservableObject {
    @Published var devices: [OBDDevice] = []
    @Published var currentDevice: OBDDevice?
    
    private let userDefaults = UserDefaults.standard
    private let devicesKey = "SavedOBDDevices"
    private let currentDeviceKey = "CurrentOBDDevice"
    
    init() {
        loadDevices()
        loadCurrentDevice()
    }
    
    // MARK: - Device Management
    
    func addDevice(name: String, type: OBDDevice.DeviceType) {
        let newDevice = OBDDevice(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            isDefault: devices.isEmpty, // First device becomes default
            dateAdded: Date()
        )
        
        // If this is the first device or set as default, update others
        if newDevice.isDefault {
            devices = devices.map { device in
                var updatedDevice = device
                updatedDevice.isDefault = false
                return updatedDevice
            }
        }
        
        devices.append(newDevice)
        
        if newDevice.isDefault {
            currentDevice = newDevice
        }
        
        saveDevices()
        saveCurrentDevice()
    }
    
    func removeDevice(_ device: OBDDevice) {
        devices.removeAll { $0.id == device.id }
        
        // If we removed the current device, set a new one
        if currentDevice?.id == device.id {
            currentDevice = devices.first { $0.isDefault } ?? devices.first
        }
        
        // If we removed the default device, make the first one default
        if device.isDefault && !devices.isEmpty {
            setAsDefault(devices.first!)
        }
        
        saveDevices()
        saveCurrentDevice()
    }
    
    func setAsDefault(_ device: OBDDevice) {
        // Remove default from all devices
        devices = devices.map { device in
            var updatedDevice = device
            updatedDevice.isDefault = false
            return updatedDevice
        }
        
        // Set new default
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].isDefault = true
            currentDevice = devices[index]
        }
        
        saveDevices()
        saveCurrentDevice()
    }
    
    func updateDevice(_ device: OBDDevice, newName: String, newType: OBDDevice.DeviceType) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            devices[index].type = newType
            
            if devices[index].isDefault {
                currentDevice = devices[index]
            }
        }
        
        saveDevices()
        saveCurrentDevice()
    }
    
    // MARK: - Persistence
    
    private func saveDevices() {
        if let encoded = try? JSONEncoder().encode(devices) {
            userDefaults.set(encoded, forKey: devicesKey)
        }
    }
    
    private func loadDevices() {
        if let data = userDefaults.data(forKey: devicesKey),
           let decoded = try? JSONDecoder().decode([OBDDevice].self, from: data) {
            devices = decoded
        }
    }
    
    private func saveCurrentDevice() {
        if let currentDevice = currentDevice,
           let encoded = try? JSONEncoder().encode(currentDevice) {
            userDefaults.set(encoded, forKey: currentDeviceKey)
        }
    }
    
    private func loadCurrentDevice() {
        if let data = userDefaults.data(forKey: currentDeviceKey),
           let decoded = try? JSONDecoder().decode(OBDDevice.self, from: data) {
            currentDevice = decoded
        }
    }
    
    // MARK: - Helper Methods
    
    func getDeviceName() -> String {
        return currentDevice?.name ?? UIDevice.current.name
    }
    
    func hasDevices() -> Bool {
        return !devices.isEmpty
    }
    
    func getDeviceCount() -> Int {
        return devices.count
    }
}
