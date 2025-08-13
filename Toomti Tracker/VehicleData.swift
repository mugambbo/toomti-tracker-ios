//
//  VehicleData.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//

import Foundation

struct VehicleData {
    // Core engine data
    var rpm: Double = 0
    var speed: Double = 0
    var engineLoad: Double = 0
    var throttlePosition: Double = 0
    var coolantTemp: Double = 0
    var voltage: Double = 0
    
    // Additional engine parameters
    var intakeAirTemp: Double = 0
    var mafRate: Double = 0
    var fuelLevel: Double = 0
    var shortFuelTrim1: Double = 0
    var longFuelTrim1: Double = 0
    var shortFuelTrim2: Double = 0
    var longFuelTrim2: Double = 0
    var ambientAirTemp: Double = 0
    var fuelPressure: Double = 0
    var timingAdvance: Double = 0
    var engineRuntime: Int = 0
    var fuelRate: Double = 0
    var relativeThrottlePos: Double = 0
    
    var obdStandards: String = ""
    
    // Status flags
    var dataValid: Bool = false
    var milOn: Bool = false
    var dtcCount: Int = 0
    var rawDTC: String = ""
    
    var currentProtocolNumber: Int = 6  // Default to CAN
    var protocolName: String = ""
    
    var timestamp: Date = Date()
    
    var isValid: Bool {
        return rpm > 0 || speed > 0 || engineLoad > 0
    }
}
