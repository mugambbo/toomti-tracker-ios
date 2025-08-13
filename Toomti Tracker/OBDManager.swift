import Foundation
import UIKit
import Network
import CoreBluetooth
import CoreLocation
import BackgroundTasks

class OBDManager: NSObject, ObservableObject {
    static let shared = OBDManager()
    private let logger = LogManager.shared
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var currentVehicleData: VehicleData?
    @Published var lastUploadTime = "Never"
    @Published var deviceSettings = DeviceSettingsManager()
    
    private var tcpConnection: NWConnection?
    private var bluetoothManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var obdCharacteristic: CBCharacteristic?
    
    private var dataTimer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // Configuration
    private let serverHost = "54.242.108.224"
    private let serverPort: UInt16 = 8090
    private let obdWiFiHost = "192.168.0.10"
    private let obdWiFiPort: UInt16 = 35000
    private let deviceName = UIDevice.current.name
    
    // OBD Data Collection
    private var currentCycle = 0
    private var pendingResponses: [String: (String) -> Void] = [:]
    private var responseBuffer: String = ""
    private var obdDeviceName: String = ""
    
    // Complete PID list matching Arduino implementation
    private let pidCommands: [(command: String, description: String, pid: UInt8, interval: Int)] = [
        ("010C", "Engine RPM", 0x0C, 1),
        ("010D", "Vehicle Speed", 0x0D, 1),
        ("0104", "Engine Load", 0x04, 1),
        ("0111", "Throttle Position", 0x11, 1),
        ("0105", "Coolant Temperature", 0x05, 2),
        ("010F", "Intake Air Temperature", 0x0F, 2),
        ("0110", "MAF Rate", 0x10, 2),
        ("012F", "Fuel Level", 0x2F, 2),
        ("0106", "Short Term Fuel Trim - Bank 1", 0x06, 3),
        ("0107", "Long Term Fuel Trim - Bank 1", 0x07, 3),
        ("0108", "Short Term Fuel Trim - Bank 2", 0x08, 3),
        ("0109", "Long Term Fuel Trim - Bank 2", 0x09, 3),
        ("015E", "Engine Fuel Rate", 0x5E, 4),
        ("010A", "Fuel Pressure", 0x0A, 4),
        ("010E", "Timing Advance", 0x0E, 5),
        ("011F", "Engine Runtime", 0x1F, 5),
        ("0146", "Ambient Air Temperature", 0x46, 5),
        ("0145", "Relative Throttle Position", 0x45, 5),
        ("011C", "OBD Standards", 0x1C, 10),
        ("ATRV", "Battery Voltage", 0x00, 1)
    ]
    
    private override init() {
        super.init()
        logger.info("OBD", "OBDManager initialized")
        setupBackgroundTask()
    }
    
    // MARK: - Connection Management
    
    func connect() {
        print("🔌 Connect button pressed")
        logger.info("OBD", "Connect button pressed - starting connection attempt")
        connectionStatus = "Connecting..."
        
        // Reset connection state
        isConnected = false
        
        // Try WiFi first with explicit timeout
        print("🔄 Trying WiFi connection first...")
        logger.debug("OBD", "Attempting WiFi connection first")
        connectWiFi { [weak self] wifiSuccess in
            if wifiSuccess {
                print("✅ WiFi connection successful")
                self?.logger.info("OBD", "WiFi connection established successfully")
            } else {
                print("❌ WiFi failed, trying Bluetooth...")
                self?.logger.warning("OBD", "WiFi connection failed, attempting Bluetooth fallback")
                DispatchQueue.main.async {
                    self?.connectBluetooth()
                }
            }
        }
    }
    
    func disconnect() {
        print("Disconnect button pressed")
        logger.info("OBD", "Disconnect button pressed - terminating connections")
        tcpConnection?.cancel()
        bluetoothManager?.stopScan()
        
        if let peripheral = connectedPeripheral, let characteristic = obdCharacteristic {
            peripheral.setNotifyValue(false, for: characteristic)
            logger.debug("OBD", "Disabled notifications for Bluetooth characteristic")
        }
        
        isConnected = false
        connectionStatus = "Disconnected"
        stopDataCollection()
        logger.info("OBD", "Disconnection completed")
    }
    
    func sendTestData() {
        print("Send Test Data button pressed")
        logger.info("OBD", "Send Test Data button pressed - generating test vehicle data")
        
        // Create test vehicle data
        let testData = VehicleData(
            rpm: 1500.0,
            speed: 60.0,
            engineLoad: 45.0,
            throttlePosition: 30.0,
            coolantTemp: 85.0,
            voltage: 12.4,
            intakeAirTemp: 25.0,
            mafRate: 15.5,
            fuelLevel: 75.0,
            shortFuelTrim1: 2.5,
            longFuelTrim1: -1.0,
            shortFuelTrim2: 1.8,
            longFuelTrim2: -0.5,
            ambientAirTemp: 22.0,
            fuelPressure: 300.0,
            timingAdvance: 12.0,
            engineRuntime: 3600,
            fuelRate: 8.5,
            relativeThrottlePos: 28.0,
            obdStandards: "OBD-II",
            dataValid: true
        )
        
        logger.debug("OBD", "Test data created with RPM: \(testData.rpm), Speed: \(testData.speed)")
        
        // Update the current vehicle data for UI display
        DispatchQueue.main.async {
            self.currentVehicleData = testData
        }
        
        // Send to server
        uploadDataToServer(testData)
        
        print("Test data created and upload initiated")
        logger.info("OBD", "Test data created and upload initiated successfully")
    }
    
    // MARK: - WiFi Connection
    
    private func connectWiFi(completion: @escaping (Bool) -> Void) {
        print("🔄 Attempting WiFi connection to \(obdWiFiHost):\(obdWiFiPort)")
        logger.info("OBD", "Attempting WiFi connection to \(obdWiFiHost):\(obdWiFiPort)")
        
        let host = NWEndpoint.Host(obdWiFiHost)
        let port = NWEndpoint.Port(rawValue: obdWiFiPort)!
        
        // Create connection with timeout
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10 // 10 second timeout
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        tcpConnection = NWConnection(host: host, port: port, using: parameters)
        
        // Set up timeout timer
        var timeoutTimer: Timer?
        var hasCompleted = false
        
        tcpConnection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                print("📡 WiFi connection state: \(state)")
                self?.logger.debug("OBD", "WiFi connection state changed to: \(state)")
                
                guard !hasCompleted else { return }
                
                switch state {
                case .ready:
                    self?.logger.info("OBD", "WiFi connection established successfully")
                    hasCompleted = true
                    timeoutTimer?.invalidate()
                    print("✅ WiFi connection established")
                    self?.isConnected = true
                    self?.connectionStatus = "Connected (WiFi)"
                    // Extract device name from WiFi network name
                    self?.extractDeviceNameFromWiFi()
                    self?.initializeELM327()
                    completion(true)
                    
                case .failed(let error):
                    self?.logger.error("OBD", "WiFi connection failed: \(error.localizedDescription)")
                    hasCompleted = true
                    timeoutTimer?.invalidate()
                    print("❌ WiFi connection failed: \(error)")
                    self?.connectionStatus = "WiFi Failed"
                    self?.tcpConnection?.cancel()
                    self?.tcpConnection = nil
                    completion(false)
                    
                case .cancelled:
                    self?.logger.warning("OBD", "WiFi connection cancelled")
                    if !hasCompleted {
                        hasCompleted = true
                        timeoutTimer?.invalidate()
                        print("🚫 WiFi connection cancelled")
                        self?.connectionStatus = "WiFi Cancelled"
                        completion(false)
                    }
                    
                case .waiting(let error):
                    self?.logger.warning("OBD", "WiFi connection waiting: \(error.localizedDescription)")
                    print("⏳ WiFi connection waiting: \(error)")
                    // Don't complete yet, let timeout handle this
                    
                case .preparing:
                    print("🔄 WiFi connection preparing...")
                    self?.logger.debug("OBD", "WiFi connection in preparing state")
                    // Don't complete yet, let timeout handle this
                    
                case .setup:
                    print("🔧 WiFi connection setup...")
                    self?.logger.debug("OBD", "WiFi connection in setup phase")
                    // Don't complete yet, let setup complete
                    
                @unknown default:
                    print("📡 WiFi connection state: \(state)")
                    self?.logger.warning("OBD", "Unknown WiFi connection state: \(state)")
                    break
                }
            }
        }
        
        // Start connection
        tcpConnection?.start(queue: .global())
        logger.debug("OBD", "WiFi connection attempt started")
        
        // Set up timeout timer (15 seconds total)
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
            DispatchQueue.main.async {
                guard !hasCompleted else { return }
                hasCompleted = true
                
                print("⏰ WiFi connection timeout after 15 seconds")
                self.logger.warning("OBD", "WiFi connection timeout after 15 seconds")
                self.connectionStatus = "WiFi Timeout"
                self.tcpConnection?.cancel()
                self.tcpConnection = nil
                completion(false)
            }
        }
    }
    
    private func extractDeviceNameFromWiFi() {
        // Try to get device name from settings first
        if deviceSettings.hasDevices() {
            obdDeviceName = deviceSettings.getDeviceName()
            logger.debug("OBD", "Using configured device name: \(obdDeviceName)")
        } else {
            // Fallback to auto-detection or prompt user
            obdDeviceName = "TOOMTI\(deviceName.suffix(8))"
            logger.debug("OBD", "Using fallback WiFi device name: \(obdDeviceName)")
        }
    }
    
    // MARK: - Bluetooth Connection
    
    private func connectBluetooth() {
        print("🔵 Attempting Bluetooth connection")
        logger.info("OBD", "Starting Bluetooth connection attempt")
        connectionStatus = "Scanning Bluetooth..."
        
        // Reset bluetooth state
        connectedPeripheral = nil
        obdCharacteristic = nil
        
        // Initialize or restart Bluetooth manager
        if bluetoothManager == nil {
            logger.debug("OBD", "Initializing new Bluetooth central manager")
            bluetoothManager = CBCentralManager(delegate: self, queue: nil)
        } else {
            // If manager already exists, check its state
            logger.debug("OBD", "Using existing Bluetooth central manager")
            centralManagerDidUpdateState(bluetoothManager!)
        }
        
        // Set scanning timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
            if !self.isConnected && self.connectionStatus.contains("Bluetooth") {
                print("⏰ Bluetooth scan timeout")
                self.logger.warning("OBD", "Bluetooth scan timeout after 30 seconds")
                self.bluetoothManager?.stopScan()
                self.connectionStatus = "Connection Failed"
            }
        }
    }
    
    // MARK: - Enhanced ELM327 Initialization
    
    private func initializeELM327() {
        print("Initializing ELM327...")
        logger.info("OBD", "Starting ELM327 initialization sequence")
        
        let initCommands = [
            "ATZ",      // Reset
            "ATE0",     // Echo off
            "ATL0",     // Linefeeds off
            "ATS0",     // Spaces off
            "ATH0",     // Headers off
            "ATSPA0",   // Set protocol auto - this will cause SEARCHING
            "0100"      // Test command - this will fail if no vehicle
        ]
        
        logger.debug("OBD", "Sending \(initCommands.count) initialization commands")
        
        sendInitCommands(initCommands, index: 0) { [weak self] success in
            // Even if initialization "fails", we can still try to collect data
            print("ELM327 initialization completed (success: \(success))")
            self?.logger.info("OBD", "ELM327 initialization completed with success: \(success)")
            
            // Check if we can at least get battery voltage (this works even without vehicle protocol)
            self?.testBasicConnection { basicConnectionWorks in
                if basicConnectionWorks {
                    print("Basic ELM327 connection working, starting data collection")
                    self?.logger.info("OBD", "Basic ELM327 connection verified, starting data collection")
                    self?.startDataCollection()
                } else {
                    print("ELM327 not responding properly")
                    self?.logger.error("OBD", "ELM327 not responding properly to basic commands")
                    self?.connectionStatus = "ELM327 Not Responding"
                }
            }
        }
    }

    private func testBasicConnection(completion: @escaping (Bool) -> Void) {
        print("Testing basic ELM327 connection...")
        logger.debug("OBD", "Testing basic ELM327 connection with voltage command")
        
        sendOBDCommand("ATRV") { response in
            print("Battery voltage test response: \(response)")
            self.logger.debug("OBD", "Battery voltage test response: '\(response)'")
            
            // If we get a voltage reading, the adapter is working
            if self.parseVoltage(response) != nil {
                print("ELM327 basic connection confirmed")
                self.logger.info("OBD", "ELM327 basic connection confirmed via voltage reading")
                completion(true)
            } else if response.uppercased().contains("UNABLE TO CONNECT") {
                print("ELM327 connected but no vehicle detected")
                self.logger.warning("OBD", "ELM327 connected but no vehicle detected")
                completion(true) // Adapter works, just no vehicle
            } else {
                print("ELM327 basic connection failed")
                self.logger.error("OBD", "ELM327 basic connection failed with response: '\(response)'")
                completion(false)
            }
        }
    }
    
    private func sendInitCommands(_ commands: [String], index: Int, completion: @escaping (Bool) -> Void) {
        guard index < commands.count else {
            logger.info("OBD", "All initialization commands completed")
            completion(true)
            return
        }
        
        let command = commands[index]
        print("Sending init command \(index + 1)/\(commands.count): \(command)")
        logger.debug("OBD", "Sending init command \(index + 1)/\(commands.count): '\(command)'")
        
        sendOBDCommand(command) { [weak self] response in
            print("Init command \(command) response: \(response)")
            self?.logger.debug("OBD", "Init command '\(command)' response: '\(response)'")
            
            let isSuccess = !response.isEmpty &&
                           !response.uppercased().contains("ERROR") &&
                           response != "TIMEOUT"
            
            if !isSuccess && command == "ATZ" {
                print("Reset command failed, but this is often normal. Continuing...")
                self?.logger.info("OBD", "Reset command failed but continuing (this is normal)")
            }
            
            // Longer delay between init commands, especially after reset and protocol detection
            let delay: TimeInterval = (command == "ATZ" || command == "ATSPA0") ? 15.0 : 1.0
            self?.logger.debug("OBD", "Waiting \(delay) seconds before next init command")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.sendInitCommands(commands, index: index + 1, completion: completion)
            }
        }
    }
    
    // MARK: - OBD Data Collection
    
    private func startDataCollection() {
        print("🚀 Starting data collection...")
        logger.info("OBD", "Starting OBD data collection system")
        
        // Invalidate any existing timer first
        dataTimer?.invalidate()
        dataTimer = nil
        
        // Set timer to collect data every 30 seconds continuously
        dataTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] timer in
            print("⏰ Timer fired! Starting next collection cycle...")
            self?.logger.debug("OBD", "Data collection timer fired for cycle")
            guard timer.isValid else {
                print("❌ Timer is invalid, stopping collection")
                self?.logger.warning("OBD", "Data collection timer is invalid, stopping")
                return
            }
            self?.collectOBDData()
        }
        
        // Ensure timer is added to the run loop
        if let timer = dataTimer {
            RunLoop.current.add(timer, forMode: .common)
            print("✅ Timer scheduled - next collection in 30 seconds")
            logger.info("OBD", "Data collection timer scheduled successfully")
        }
        
        // Collect initial data immediately
        print("🔄 Starting initial data collection...")
        logger.debug("OBD", "Starting initial data collection cycle")
        collectOBDData()
    }
    
    private func stopDataCollection() {
        print("Stopping data collection...")
        logger.info("OBD", "Stopping OBD data collection system")
        dataTimer?.invalidate()
        dataTimer = nil
    }
    
    private func collectOBDData() {
        guard isConnected else {
            print("Not connected, skipping data collection")
            logger.warning("OBD", "Skipping data collection - not connected")
            return
        }
        
        print("🔄 Starting OBD data collection cycle \(currentCycle + 1)...")
        logger.info("OBD", "Starting OBD data collection cycle \(currentCycle + 1)")
        currentCycle += 1
        
        var vehicleData = currentVehicleData ?? VehicleData()
        var successCount = 0
        
        // Get battery voltage first
        sendOBDCommand("ATRV") { response in
            if let voltage = self.parseVoltage(response) {
                vehicleData.voltage = voltage
                successCount += 1
                print("✅ Battery voltage: \(voltage)V")
                self.logger.debug("OBD", "Battery voltage read successfully: \(voltage)V")
            } else {
                print("❌ Failed to get battery voltage")
                self.logger.warning("OBD", "Failed to read battery voltage from response: '\(response)'")
            }
            
            // Detect protocol (every 10th cycle or first cycle)
            if self.currentCycle == 1 || self.currentCycle % 10 == 0 {
                self.logger.debug("OBD", "Detecting protocol for cycle \(self.currentCycle)")
                self.detectCurrentProtocol { protocolNumber in
                    vehicleData.currentProtocolNumber = protocolNumber
                    vehicleData.protocolName = self.getProtocolName(protocolNumber)
                    self.logger.info("OBD", "Protocol detected: \(protocolNumber) (\(vehicleData.protocolName))")
                    
                    // After voltage, collect PIDs sequentially
                    print("📊 Starting PID collection (using newly detected protocol)...")
                    self.logger.debug("OBD", "Starting PID collection with detected protocol")
                    self.collectPIDsSequentially(vehicleData: vehicleData, successCount: successCount, pidIndex: 0)
                }
            } else {
                // Use previously detected protocol
                vehicleData.currentProtocolNumber = self.currentVehicleData?.currentProtocolNumber ?? 6
                vehicleData.protocolName = self.currentVehicleData?.protocolName ?? ""
                
                // After voltage, collect PIDs sequentially
                print("📊 Starting PID collection (using previously detected protocol)...")
                self.logger.debug("OBD", "Starting PID collection with cached protocol info")
                self.collectPIDsSequentially(vehicleData: vehicleData, successCount: successCount, pidIndex: 0)
            }
        }
    }

    private func collectPIDsSequentially(vehicleData: VehicleData, successCount: Int, pidIndex: Int) {
        var data = vehicleData
        var count = successCount
        
        // PRESERVE PREVIOUS DATA: Initialize with existing data to avoid overriding
        if let existingData = currentVehicleData {
            // Copy previous values that shouldn't be reset
            data.rpm = existingData.rpm
            data.speed = existingData.speed
            data.engineLoad = existingData.engineLoad
            data.throttlePosition = existingData.throttlePosition
            data.coolantTemp = existingData.coolantTemp
            data.intakeAirTemp = existingData.intakeAirTemp
            data.mafRate = existingData.mafRate
            data.fuelLevel = existingData.fuelLevel
            data.shortFuelTrim1 = existingData.shortFuelTrim1
            data.longFuelTrim1 = existingData.longFuelTrim1
            data.shortFuelTrim2 = existingData.shortFuelTrim2
            data.longFuelTrim2 = existingData.longFuelTrim2
            data.fuelRate = existingData.fuelRate
            data.fuelPressure = existingData.fuelPressure
            data.timingAdvance = existingData.timingAdvance
            data.engineRuntime = existingData.engineRuntime
            data.ambientAirTemp = existingData.ambientAirTemp
            data.relativeThrottlePos = existingData.relativeThrottlePos
            data.obdStandards = existingData.obdStandards
            // Keep the voltage and protocol info from the current collection
        }
        
        
        
        // Filter PIDs to collect based on cycle interval
        let pidsToCollect = pidCommands.filter { pidCommand in
            pidCommand.command != "ATRV" && // Skip voltage (already collected)
            (currentCycle == 1 || currentCycle % pidCommand.interval == 0)
        }
        
        // Check if we've finished all PIDs
        guard pidIndex < pidsToCollect.count else {
            // All PIDs collected, now check for DTCs
            print("📋 PID collection complete, checking for trouble codes...")
            logger.info("OBD", "PID collection complete, checking for diagnostic trouble codes")
            
            // Check for DTCs every 5th cycle or on first cycle
            if currentCycle == 1 || currentCycle % 5 == 0 {
                logger.debug("OBD", "Collecting DTCs for cycle \(currentCycle)")
                self.collectDTCs(vehicleData: data, successCount: count)
            } else {
                logger.debug("OBD", "Skipping DTC collection for cycle \(currentCycle)")
                self.finalizDataCollection(vehicleData: data, successCount: count)
            }
            return
        }
        
        let pidCommand = pidsToCollect[pidIndex]
        print("📋 Reading \(pidCommand.description) (\(pidCommand.command)) - \(pidIndex + 1)/\(pidsToCollect.count)")
        logger.debug("OBD", "Reading PID \(pidCommand.description) (\(pidCommand.command)) - \(pidIndex + 1)/\(pidsToCollect.count)")
        
        sendOBDCommand(pidCommand.command) { response in
            if let value = self.parseOBDResponse(command: pidCommand.command, response: response, pid: pidCommand.pid) {
                self.updateVehicleData(&data, pid: pidCommand.pid, value: value)
                count += 1
                print("✅ \(pidCommand.description): \(value)")
                self.logger.debug("OBD", "Successfully parsed \(pidCommand.description): \(value)")
            } else {
                print("❌ Failed to parse \(pidCommand.description) - Response: \(response)")
                self.logger.warning("OBD", "Failed to parse \(pidCommand.description) from response: '\(response)'")
            }
            
            // Small delay between commands to avoid overwhelming ELM327
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.collectPIDsSequentially(vehicleData: data, successCount: count, pidIndex: pidIndex + 1)
            }
        }
    }
    
    private func collectDTCs(vehicleData: VehicleData, successCount: Int) {
        var data = vehicleData
        let count = successCount
        
        print("🔧 Checking MIL status and DTC count...")
        logger.debug("OBD", "Checking MIL status and DTC count")
        
        // First, check MIL status and DTC count (Mode 01, PID 01)
        sendOBDCommand("0101") { response in
            self.parseMILStatus(response: response, data: &data)
            
            // If there are DTCs, read them
            if data.milOn || data.dtcCount > 0 {
                print("⚠️ Found \(data.dtcCount) trouble codes, reading DTCs...")
                self.logger.warning("OBD", "Found \(data.dtcCount) trouble codes, MIL: \(data.milOn ? "ON" : "OFF")")
                
                // Read stored DTCs (Mode 03)
                self.sendOBDCommand("03") { dtcResponse in
                    self.parseDTCs(response: dtcResponse, data: &data)
                    self.finalizDataCollection(vehicleData: data, successCount: count)
                }
            } else {
                print("✅ No trouble codes found")
                self.logger.info("OBD", "No diagnostic trouble codes found")
                self.finalizDataCollection(vehicleData: data, successCount: count)
            }
        }
    }

    // MARK: - DTC (Diagnostic Trouble Code) Functions

    private func parseMILStatus(response: String, data: inout VehicleData) {
        let cleanResponse = response.replacingOccurrences(of: " ", with: "").uppercased()
        print("🔍 MIL Status Response: \(cleanResponse)")
        logger.debug("OBD", "Parsing MIL status from response: '\(cleanResponse)'")
        
        // Look for Mode 01 PID 01 response: 4101XXXXXXXX
        if cleanResponse.hasPrefix("4101") && cleanResponse.count >= 8 {
            let firstByte = String(cleanResponse[cleanResponse.index(cleanResponse.startIndex, offsetBy: 4)..<cleanResponse.index(cleanResponse.startIndex, offsetBy: 6)])
            
            if let firstByteValue = UInt8(firstByte, radix: 16) {
                // Bit 7 = MIL status, Bits 0-6 = DTC count
                data.milOn = (firstByteValue & 0x80) != 0
                data.dtcCount = Int(firstByteValue & 0x7F)
                
                print("🔧 MIL Status: \(data.milOn ? "ON" : "OFF"), DTC Count: \(data.dtcCount)")
                logger.info("OBD", "MIL Status: \(data.milOn ? "ON" : "OFF"), DTC Count: \(data.dtcCount)")
            }
        } else if cleanResponse.contains("NODATA") || cleanResponse.contains("ERROR") {
            print("⚠️ Could not read MIL status: \(response)")
            logger.warning("OBD", "Could not read MIL status from response: '\(response)'")
            data.milOn = false
            data.dtcCount = 0
        }
    }

    private func parseDTCs(response: String, data: inout VehicleData) {
        let cleanResponse = response.replacingOccurrences(of: " ", with: "").uppercased()
        print("🔍 DTC Response: \(cleanResponse)")
        logger.debug("OBD", "Parsing DTCs from response: '\(cleanResponse)'")
        
        data.rawDTC = response // Store raw response
        
        // Parse Mode 03 response: 43XXXXXXXXXX
        if cleanResponse.hasPrefix("43") && cleanResponse.count > 4 {
            let dtcData = String(cleanResponse.dropFirst(2)) // Remove "43"
            let dtcCodes = parseDTCCodes(dtcData: dtcData)
            
            if !dtcCodes.isEmpty {
                print("⚠️ Parsed DTCs: \(dtcCodes.joined(separator: ", "))")
                logger.warning("OBD", "Parsed DTCs: \(dtcCodes.joined(separator: ", "))")
            }
        } else if cleanResponse.contains("NODATA") {
            print("✅ No stored DTCs")
            logger.info("OBD", "No stored DTCs found")
            data.rawDTC = ""
            data.dtcCount = 0
        }
    }

    private func parseDTCCodes(dtcData: String) -> [String] {
        var dtcCodes: [String] = []
        
        // Each DTC is 4 hex characters (2 bytes)
        let cleanData = dtcData.replacingOccurrences(of: " ", with: "")
        logger.debug("OBD", "Parsing DTC codes from data: '\(cleanData)'")
        
        for i in stride(from: 0, to: cleanData.count - 3, by: 4) {
            let startIndex = cleanData.index(cleanData.startIndex, offsetBy: i)
            let endIndex = cleanData.index(startIndex, offsetBy: 4)
            let dtcHex = String(cleanData[startIndex..<endIndex])
            
            if let dtcCode = convertHexToDTC(hex: dtcHex) {
                dtcCodes.append(dtcCode)
                logger.debug("OBD", "Converted DTC hex '\(dtcHex)' to code '\(dtcCode)'")
            }
        }
        
        return dtcCodes
    }

    private func convertHexToDTC(hex: String) -> String? {
        guard hex.count == 4, let value = UInt16(hex, radix: 16) else {
            logger.warning("OBD", "Invalid DTC hex format: '\(hex)'")
            return nil
        }
        
        // Skip empty DTCs (0000)
        if value == 0 { return nil }
        
        // Extract the first two bits to determine the system
        let firstTwoBits = (value >> 14) & 0x03
        let systemLetter: String
        
        switch firstTwoBits {
        case 0: systemLetter = "P" // Powertrain
        case 1: systemLetter = "C" // Chassis
        case 2: systemLetter = "B" // Body
        case 3: systemLetter = "U" // Network
        default: systemLetter = "P"
        }
        
        // Extract the remaining 14 bits for the code number
        let codeNumber = value & 0x3FFF
        
        let dtcCode = String(format: "%@%04X", systemLetter, codeNumber)
        logger.debug("OBD", "Converted DTC: system=\(systemLetter), number=\(codeNumber), final=\(dtcCode)")
        
        return dtcCode
    }

    private func finalizDataCollection(vehicleData: VehicleData, successCount: Int) {
        var data = vehicleData
        data.dataValid = successCount > 0
        
        DispatchQueue.main.async {
            self.currentVehicleData = data
            print("✅ Data collection cycle \(self.currentCycle) complete. Valid parameters: \(successCount)")
            self.logger.info("OBD", "Data collection cycle \(self.currentCycle) complete. Valid parameters: \(successCount)")
                       
                       if data.milOn || data.dtcCount > 0 {
                           print("⚠️ Check Engine Light: \(data.milOn ? "ON" : "OFF"), DTCs: \(data.dtcCount)")
                           self.logger.warning("OBD", "Check Engine Light: \(data.milOn ? "ON" : "OFF"), DTCs: \(data.dtcCount)")
                       }
                       
                       print("⏰ Next collection in 30 seconds...")
                       self.logger.debug("OBD", "Next data collection scheduled in 30 seconds")
                       
                       if data.dataValid {
                           print("📤 Uploading data to server...")
                           self.logger.info("OBD", "Uploading valid data to server")
                           self.uploadDataToServer(data)
                       } else {
                           print("⚠️ No valid data to upload")
                           self.logger.warning("OBD", "No valid data collected, skipping upload")
                       }
                   }
               }
               
               private func clearDTCs(completion: @escaping (Bool) -> Void) {
                   print("🔧 Clearing diagnostic trouble codes...")
                   logger.info("OBD", "Clearing diagnostic trouble codes")
                   
                   sendOBDCommand("04") { response in
                       let cleanResponse = response.uppercased()
                       print("🔍 Clear DTCs response: \(cleanResponse)")
                       self.logger.debug("OBD", "Clear DTCs response: '\(cleanResponse)'")
                       
                       // Mode 04 successful response is "44" or contains "OK"
                       let success = cleanResponse.contains("44") || cleanResponse.contains("OK")
                       
                       if success {
                           print("✅ DTCs cleared successfully")
                           self.logger.info("OBD", "DTCs cleared successfully")
                       } else {
                           print("❌ Failed to clear DTCs: \(response)")
                           self.logger.error("OBD", "Failed to clear DTCs: '\(response)'")
                       }
                       
                       completion(success)
                   }
               }

               // Add this method to be called from UI if needed
               func clearTroubleCodes() {
                   guard isConnected else {
                       print("❌ Not connected to OBD adapter")
                       logger.warning("OBD", "Cannot clear trouble codes - not connected to OBD adapter")
                       return
                   }
                   
                   clearDTCs { success in
                       DispatchQueue.main.async {
                           if success {
                               self.logger.info("OBD", "Trouble codes cleared, refreshing data")
                               // Refresh data after clearing
                               self.collectOBDData()
                           }
                       }
                   }
               }
               
               // MARK: - Enhanced OBD Communication with SEARCHING Handling
               
               private func sendOBDCommand(_ command: String, completion: @escaping (String) -> Void) {
                   sendOBDCommandWithRetry(command, maxRetries: 3, completion: completion)
               }
               
               private func sendOBDCommandWithRetry(_ command: String, maxRetries: Int, completion: @escaping (String) -> Void) {
                   print("Sending OBD command: \(command) (retries left: \(maxRetries))")
                   logger.debug("OBD", "Sending OBD command: '\(command)' with \(maxRetries) retries remaining")
                   let commandWithCR = command + "\r"
                   
                   if let tcpConnection = tcpConnection {
                       // WiFi connection
                       let data = commandWithCR.data(using: .utf8)!
                       tcpConnection.send(content: data, completion: .contentProcessed { error in
                           if let error = error {
                               print("Send error for \(command): \(error)")
                               self.logger.error("OBD", "Send error for command '\(command)': \(error.localizedDescription)")
                               completion("")
                               return
                           }
                           
                           // Read response with extended timeout for SEARCHING
                           self.readTCPResponseWithSearching(from: tcpConnection, command: command, maxRetries: maxRetries, completion: completion)
                       })
                       
                   } else if let peripheral = connectedPeripheral, let characteristic = obdCharacteristic {
                       // Bluetooth connection
                       sendBluetoothCommandWithRetry(command, characteristic: characteristic, peripheral: peripheral, maxRetries: maxRetries, completion: completion)
                       
                   } else {
                       logger.error("OBD", "Cannot send command '\(command)' - no active connection")
                       completion("NOT_CONNECTED")
                   }
               }
               
               private func readTCPResponseWithSearching(from connection: NWConnection, command: String, maxRetries: Int, completion: @escaping (String) -> Void) {
                   var responseData = Data()
                   let startTime = Date()
                   let initialTimeout: TimeInterval = 10.0
                   
                   func readNextChunk() {
                       connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                           if let data = data {
                               responseData.append(data)
                               
                               if let responseString = String(data: responseData, encoding: .utf8) {
                                   print("Raw TCP response: \(responseString)")
                                   self.logger.info("OBD", "Raw TCP response: '\(responseString)'")
                                   
                                   // Check for complete response first (including successful SEARCHING responses)
                                   if responseString.contains(">") {
                                       let cleanResponse = responseString
                                           .replacingOccurrences(of: "\r", with: "\n")
                                           .replacingOccurrences(of: ">", with: "")
                                           .trimmingCharacters(in: .whitespacesAndNewlines)
                                       
                                       print("Complete response for \(command): \(cleanResponse)")
                                       self.logger.debug("OBD", "Complete TCP response for '\(command)': '\(cleanResponse)'")
                                       completion(cleanResponse)
                                       return
                                   }
                                   
                                   // Check for other complete responses without ">"
                                   if responseString.contains("OK") ||
                                      responseString.contains("ERROR") ||
                                      responseString.contains("NO DATA") ||
                                      responseString.contains("BUS INIT") {
                                       
                                       let cleanResponse = responseString
                                           .replacingOccurrences(of: "\r", with: "\n")
                                           .replacingOccurrences(of: ">", with: "")
                                           .trimmingCharacters(in: .whitespacesAndNewlines)
                                       
                                       print("Complete response for \(command): \(cleanResponse)")
                                       self.logger.debug("OBD", "Complete TCP response for '\(command)': '\(cleanResponse)'")
                                       completion(cleanResponse)
                                       return
                                   }
                                   
                                   // Handle SEARCHING that's still in progress (without complete data yet)
                                   if responseString.uppercased().contains("SEARCHING") &&
                                      !responseString.contains(">") &&
                                      !responseString.contains("41") { // No valid response data yet
                                       
                                       print("ELM327 is SEARCHING for protocol...")
                                       self.logger.info("OBD", "ELM327 is SEARCHING for protocol...")
                                       
                                       // Check for explicit error conditions during searching
                                       if responseString.uppercased().contains("UNABLE TO CONNECT") ||
                                          responseString.uppercased().contains("STOPPED") ||
                                          responseString.uppercased().contains("BUS ERROR") ||
                                          responseString.uppercased().contains("CAN ERROR") {
                                           
                                           print("SEARCHING completed with error condition")
                                           self.logger.warning("OBD", "SEARCHING completed with error condition")
                                           let cleanResponse = responseString
                                               .replacingOccurrences(of: "\r", with: "\n")
                                               .replacingOccurrences(of: ">", with: "")
                                               .trimmingCharacters(in: .whitespacesAndNewlines)
                                           
                                           completion(cleanResponse)
                                           return
                                       }
                                       
                                       // Continue waiting for SEARCHING to complete (up to 30 seconds)
                                       if Date().timeIntervalSince(startTime) < 30.0 {
                                           DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                                               readNextChunk()
                                           }
                                           return
                                       } else {
                                           print("SEARCHING timeout after 30 seconds")
                                           self.logger.warning("OBD", "SEARCHING timeout after 30 seconds")
                                           completion("SEARCHING_TIMEOUT")
                                           return
                                       }
                                   }
                               }
                           }
                           
                           // Check normal timeout
                           if Date().timeIntervalSince(startTime) > initialTimeout {
                               let partialResponse = String(data: responseData, encoding: .utf8) ?? "TIMEOUT"
                               print("Normal timeout for \(command): \(partialResponse)")
                               self.logger.warning("OBD", "Normal timeout for command '\(command)': '\(partialResponse)'")
                               completion(partialResponse)
                               return
                           }
                           
                           // Continue reading if not complete and not timed out
                           if !isComplete && error == nil {
                               DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                                   readNextChunk()
                               }
                           } else {
                               let finalResponse = String(data: responseData, encoding: .utf8) ?? "ERROR"
                               print("Final response for \(command): \(finalResponse)")
                               self.logger.debug("OBD", "Final TCP response for '\(command)': '\(finalResponse)'")
                               completion(finalResponse)
                           }
                       }
                   }
                   
                   readNextChunk()
               }
               
               // MARK: - FIXED Bluetooth Command Sending
               
               private func sendBluetoothCommandWithRetry(_ command: String, characteristic: CBCharacteristic, peripheral: CBPeripheral, maxRetries: Int, completion: @escaping (String) -> Void) {
                   logger.debug("OBD", "Sending Bluetooth command '\(command)' with \(maxRetries) retries remaining")
                   
                   pendingResponses[command] = { response in
                       print("Bluetooth response for \(command): \(response)")
                       self.logger.debug("OBD", "Bluetooth response for '\(command)': '\(response)'")
                       
                       if self.shouldRetryCommand(response) && maxRetries > 0 {
                           print("Bluetooth response indicates retry needed for \(command), waiting 5 seconds...")
                           self.logger.warning("OBD", "Bluetooth response indicates retry needed for '\(command)', waiting 5 seconds")
                           DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                               self.sendBluetoothCommandWithRetry(command, characteristic: characteristic, peripheral: peripheral, maxRetries: maxRetries - 1, completion: completion)
                           }
                       } else {
                           completion(response)
                       }
                   }
                   
                   responseBuffer = ""
                   
                   let data = (command + "\r").data(using: .utf8)!
                   print("[DEBUG] OBD: Writing data: '\(command + "\r")' to characteristic: \(characteristic.uuid)")
                   logger.debug("OBD", "Writing data to Bluetooth characteristic: '\(command + "\r")'")
                   
                   // FIXED: Check characteristic properties and use appropriate write type
                   if characteristic.properties.contains(.writeWithoutResponse) {
                       print("[DEBUG] OBD: Using writeWithoutResponse")
                       logger.debug("OBD", "Using writeWithoutResponse for Bluetooth command")
                       peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                       // For writeWithoutResponse, we don't get a write confirmation, so assume success
                       print("[INFO] OBD: Bluetooth write without response sent")
                       logger.info("OBD", "Bluetooth write without response sent successfully")
                   } else if characteristic.properties.contains(.write) {
                       print("[DEBUG] OBD: Using write with response")
                       logger.debug("OBD", "Using write with response for Bluetooth command")
                       peripheral.writeValue(data, for: characteristic, type: .withResponse)
                   } else {
                       print("[ERROR] OBD: Characteristic doesn't support writing!")
                       logger.error("OBD", "Characteristic doesn't support writing - no valid write properties")
                       if let completion = pendingResponses.removeValue(forKey: command) {
                           completion("CHARACTERISTIC_NOT_WRITABLE")
                       }
                       return
                   }
                   
                   // Set extended timeout for SEARCHING
                   DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                       if let storedCompletion = self.pendingResponses.removeValue(forKey: command) {
                           let response = self.responseBuffer.isEmpty ? "TIMEOUT" : self.responseBuffer
                           print("Bluetooth timeout for \(command): \(response)")
                           self.logger.warning("OBD", "Bluetooth timeout for command '\(command)': '\(response)'")
                           
                           if self.shouldRetryCommand(response) && maxRetries > 0 {
                               print("Bluetooth timeout, retrying \(command)...")
                               self.logger.info("OBD", "Bluetooth timeout, retrying command '\(command)'")
                               DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                   self.sendBluetoothCommandWithRetry(command, characteristic: characteristic, peripheral: peripheral, maxRetries: maxRetries - 1, completion: completion)
                               }
                           } else {
                               storedCompletion(response)
                           }
                           self.responseBuffer = ""
                       }
                   }
               }
               
               private func shouldRetryCommand(_ response: String) -> Bool {
                   let cleanResponse = response.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                   
                   // Empty responses should be retried
                   if cleanResponse.isEmpty {
                       logger.debug("OBD", "Empty response, should retry")
                       return true
                   }
                   
                   // For initialization commands, some "errors" are acceptable
                   let initializationErrors = [
                       "UNABLE TO CONNECT",
                       "NO DATA"
                   ]
                   
                   // Check if this is an initialization command that failed due to no vehicle
                   if cleanResponse.contains("SEARCHING") &&
                      initializationErrors.contains(where: { cleanResponse.contains($0) }) {
                       print("Initialization failed due to no vehicle connection - this is acceptable")
                       logger.info("OBD", "Initialization failed due to no vehicle connection - this is acceptable")
                       return false // Don't retry - this is normal when car is off
                   }
                   
                   // Explicit error conditions that require retry
                   if cleanResponse.contains("SEARCHING") && !cleanResponse.contains("UNABLE TO CONNECT") ||
                      cleanResponse.contains("BUS INIT") ||
                      cleanResponse.contains("ERROR") ||
                      cleanResponse.contains("TIMEOUT") ||
                      cleanResponse.contains("CAN ERROR") ||
                      cleanResponse.contains("BUFFER FULL") ||
                      cleanResponse.contains("WRITE_ERROR") ||
                      cleanResponse.contains("CHARACTERISTIC_NOT_WRITABLE") ||
                      cleanResponse == "?" {
                       print("Retry condition detected: \(cleanResponse)")
                       logger.warning("OBD", "Retry condition detected: '\(cleanResponse)'")
                       return true
                   }
                   
                   // Everything else (including "OK", "UNABLE TO CONNECT", and PID responses) is acceptable
                   print("Response accepted: \(response)")
                   logger.debug("OBD", "Response accepted: '\(response)'")
                   return false
               }
               
               // MARK: - Enhanced Response Parsing
               
               private func parseOBDResponse(command: String, response: String, pid: UInt8) -> Double? {
                   let cleanResponse = response.replacingOccurrences(of: " ", with: "").uppercased()
                   
                   // Handle different response formats
                   print("Parsing command: \(command), PID: 0x\(String(pid, radix: 16)), Response: \(cleanResponse)")
                   logger.debug("OBD", "Parsing command '\(command)', PID: 0x\(String(pid, radix: 16)), Response: '\(cleanResponse)'")
                   
                   switch pid {
                   case 0x0C: // RPM
                       return parseSpecificPID(cleanResponse, pid: 0x0C, bytes: 2).map { Double($0) / 4.0 }
                   case 0x0D: // Speed
                       return parseSpecificPID(cleanResponse, pid: 0x0D, bytes: 1).map { Double($0) }
                   case 0x04: // Engine Load
                       return parseSpecificPID(cleanResponse, pid: 0x04, bytes: 1).map { Double($0) * 100.0 / 255.0 }
                   case 0x11: // Throttle Position
                       return parseSpecificPID(cleanResponse, pid: 0x11, bytes: 1).map { Double($0) * 100.0 / 255.0 }
                   case 0x05: // Coolant Temperature
                       return parseSpecificPID(cleanResponse, pid: 0x05, bytes: 1).map { Double($0) - 40.0 }
                   case 0x0F: // Intake Air Temperature
                       return parseSpecificPID(cleanResponse, pid: 0x0F, bytes: 1).map { Double($0) - 40.0 }
                   case 0x10: // MAF Rate
                       return parseSpecificPID(cleanResponse, pid: 0x10, bytes: 2).map { Double($0) / 100.0 }
                   case 0x2F: // Fuel Level
                       return parseSpecificPID(cleanResponse, pid: 0x2F, bytes: 1).map { Double($0) * 100.0 / 255.0 }
                   case 0x06, 0x07, 0x08, 0x09: // Fuel Trims
                       return parseSpecificPID(cleanResponse, pid: pid, bytes: 1).map { value in
                           let a = Int(value)
                           guard a <= 255 else { return nil }
                           let fuelTrim = max(-100.0, min(100.0, Double(a - 128) * 100.0 / 128.0))
                           logger.debug("OBD", "Parsed fuel trim for PID 0x\(String(pid, radix: 16)): \(fuelTrim)%")
                           return fuelTrim
                       } ?? nil
                   case 0x5E: // Engine Fuel Rate
                       return parseSpecificPID(cleanResponse, pid: 0x5E, bytes: 2).map { Double($0) / 20.0 }
                   case 0x0A: // Fuel Pressure
                       return parseSpecificPID(cleanResponse, pid: 0x0A, bytes: 1).map { Double($0) * 3.0 }
                   case 0x0E: // Timing Advance
                       return parseSpecificPID(cleanResponse, pid: 0x0E, bytes: 1).map { (Double($0) - 128.0) / 2.0 }
                   case 0x1F: // Engine Runtime
                       return parseSpecificPID(cleanResponse, pid: 0x1F, bytes: 2).map { Double($0) }
                   case 0x46: // Ambient Air Temperature
                       return parseSpecificPID(cleanResponse, pid: 0x46, bytes: 1).map { value in
                           let temp = Double(value) - 40.0
                           let isValid = temp >= -50.0 && temp <= 60.0
                           if !isValid {
                               logger.warning("OBD", "Ambient air temperature out of range: \(temp)°C")
                           }
                           return isValid ? temp : nil
                       } ?? nil
                   case 0x45: // Relative Throttle Position
                       return parseSpecificPID(cleanResponse, pid: 0x45, bytes: 1).map { Double($0) * 100.0 / 255.0 }
                   case 0x1C: // OBD Standards
                       return parseSpecificPID(cleanResponse, pid: 0x1C, bytes: 1).map { Double($0) }
                   default:
                       logger.warning("OBD", "Unknown PID: 0x\(String(pid, radix: 16))")
                       return nil
                   }
               }
               
               private func parseSpecificPID(_ response: String, pid: UInt8, bytes: Int) -> UInt32? {
                   let expectedPrefix = String(format: "41%02X", pid)
                   
                   // Method 1: Look for exact prefix match
                   if let range = response.range(of: expectedPrefix) {
                       let startIndex = range.upperBound
                       let endIndex = response.index(startIndex, offsetBy: bytes * 2, limitedBy: response.endIndex) ?? response.endIndex
                       
                       let hexData = String(response[startIndex..<endIndex])
                       
                       if hexData.count == bytes * 2 {
                           let result = UInt32(hexData, radix: 16)
                           print("Found PID 0x\(String(pid, radix: 16)): \(hexData) = \(result ?? 0)")
                           logger.debug("OBD", "Found PID 0x\(String(pid, radix: 16)): hex='\(hexData)' value=\(result ?? 0)")
                           return result
                       }
                   }
                   
                   // Method 2: Handle multi-line responses - split by newlines and find matching line
                   let lines = response.components(separatedBy: CharacterSet.newlines)
                   for line in lines {
                       let cleanLine = line.replacingOccurrences(of: " ", with: "").uppercased()
                       if cleanLine.hasPrefix(expectedPrefix) && cleanLine.count >= expectedPrefix.count + (bytes * 2) {
                           let dataStart = expectedPrefix.count
                           let dataEnd = dataStart + (bytes * 2)
                           let hexData = String(cleanLine[cleanLine.index(cleanLine.startIndex, offsetBy: dataStart)..<cleanLine.index(cleanLine.startIndex, offsetBy: dataEnd)])
                           
                           let result = UInt32(hexData, radix: 16)
                           print("Found PID 0x\(String(pid, radix: 16)) in line: \(hexData) = \(result ?? 0)")
                           logger.debug("OBD", "Found PID 0x\(String(pid, radix: 16)) in line: hex='\(hexData)' value=\(result ?? 0)")
                           return result
                       }
                   }
                   
                   print("Could not find PID 0x\(String(pid, radix: 16)) in response: \(response)")
                   logger.warning("OBD", "Could not find PID 0x\(String(pid, radix: 16)) in response: '\(response)'")
                   return nil
               }
               
               private func parseVoltage(_ response: String) -> Double? {
                   // Handle different voltage response formats
                   let cleanResponse = response
                       .replacingOccurrences(of: "V", with: "")
                       .replacingOccurrences(of: "v", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
                   
                   // Try to extract first number that looks like voltage
                   let components = cleanResponse.components(separatedBy: CharacterSet.whitespaces)
                   for component in components {
                       if let voltage = Double(component), voltage > 5.0 && voltage < 20.0 {
                           print("Parsed voltage: \(voltage)V from response: \(response)")
                           logger.debug("OBD", "Successfully parsed voltage: \(voltage)V from response: '\(response)'")
                           return voltage
                       }
                   }
                   
                   print("Could not parse voltage from response: \(response)")
                   logger.warning("OBD", "Could not parse voltage from response: '\(response)'")
                   return nil
               }
               
               private func updateVehicleData(_ data: inout VehicleData, pid: UInt8, value: Double) {
                   logger.debug("OBD", "Updating vehicle data for PID 0x\(String(pid, radix: 16)) with value: \(value)")
                   
                   switch pid {
                   case 0x0C: data.rpm = value
                   case 0x0D: data.speed = value
                   case 0x04: data.engineLoad = value
                   case 0x11: data.throttlePosition = value
                   case 0x05: data.coolantTemp = value
                   case 0x0F: data.intakeAirTemp = value
                   case 0x10: data.mafRate = value
                   case 0x2F: data.fuelLevel = value
                   case 0x06: data.shortFuelTrim1 = value
                   case 0x07: data.longFuelTrim1 = value
                   case 0x08: data.shortFuelTrim2 = value
                   case 0x09: data.longFuelTrim2 = value
                   case 0x5E: data.fuelRate = value
                   case 0x0A: data.fuelPressure = value
                   case 0x0E: data.timingAdvance = value
                   case 0x1F: data.engineRuntime = Int(value)
                   case 0x46: data.ambientAirTemp = value
                   case 0x45: data.relativeThrottlePos = value
                   case 0x1C: data.obdStandards = getOBDStandardString(Int(value))
                   case 0x00: data.voltage = value
                   default:
                       logger.warning("OBD", "Unknown PID in updateVehicleData: 0x\(String(pid, radix: 16))")
                       break
                   }
               }
               
               private func getOBDStandardString(_ standard: Int) -> String {
                   let standardString: String
                   switch standard {
                   case 0x01: standardString = "OBD-II"
                   case 0x02: standardString = "OBD"
                   case 0x03: standardString = "OBD_OBD-II"
                   case 0x04: standardString = "OBD-I"
                   case 0x05: standardString = "NONE"
                   case 0x06: standardString = "EOBD"
                   case 0x07: standardString = "EOBD_OBD-II"
                   case 0x08: standardString = "EOBD_OBD"
                   case 0x09: standardString = "EOBD_OBD_OBD-II"
                   case 0x0A: standardString = "JOBD"
                   case 0x0B: standardString = "JOBD_OBD-II"
                   case 0x0C: standardString = "JOBD_EOBD"
                   case 0x0D: standardString = "JOBD_EOBD_OBD-II"
                   default: standardString = "UNKNOWN"
                   }
                   
                   logger.debug("OBD", "OBD standard \(standard) mapped to: \(standardString)")
                   return standardString
               }
               
               // MARK: - Server Communication
               
               private func uploadDataToServer(_ data: VehicleData) {
                   // Run upload in background - don't block data collection
                   DispatchQueue.global(qos: .background).async {
                       print("📡 Starting upload to server...")
                       self.logger.info("OBD", "Starting data upload to server")
                       
                       let location = LocationManager.shared.currentLocation
                       let message = self.formatOBDMessage(data: data, location: location)
                       
                       print("📝 Formatted message: \(message)")
                       self.logger.debug("OBD", "Formatted upload message: '\(message)'")
                       
                       // Try uploading with retry logic (but don't block main thread)
                       self.uploadWithRetry(message: message, maxRetries: 3)
                   }
               }

               private func uploadWithRetry(message: String, maxRetries: Int, currentAttempt: Int = 1) {
                   print("🔄 Upload attempt \(currentAttempt)/\(maxRetries)")
                   logger.info("OBD", "Upload attempt \(currentAttempt) of \(maxRetries)")
                   
                   let host = NWEndpoint.Host(serverHost)
                   let port = NWEndpoint.Port(rawValue: serverPort)!
                   
                   // Create connection with custom parameters
                   let tcpOptions = NWProtocolTCP.Options()
                   tcpOptions.connectionTimeout = 10 // 10 second connection timeout
                   tcpOptions.noDelay = true
                   
                   let parameters = NWParameters(tls: nil, tcp: tcpOptions)
                   parameters.requiredInterfaceType = .other // Allow any interface (WiFi/Cellular)
                   
                   let connection = NWConnection(host: host, port: port, using: parameters)
                   
                   // Set up state handler with timeout
                   var connectionTimeoutTimer: Timer?
                   
                   connection.stateUpdateHandler = { [weak self] state in
                       switch state {
                       case .ready:
                           connectionTimeoutTimer?.invalidate()
                           print("✅ Server connection established, sending data...")
                           self?.logger.info("OBD", "Server connection established, sending data")
                           
                           let messageData = message.data(using: .utf8)!
                           connection.send(content: messageData, completion: .contentProcessed { error in
                               DispatchQueue.main.async {
                                   if let error = error {
                                       print("❌ Send error: \(error)")
                                       self?.logger.error("OBD", "Data send error: \(error.localizedDescription)")
                                       self?.handleUploadFailure(message: message, maxRetries: maxRetries, currentAttempt: currentAttempt, error: "Send failed: \(error.localizedDescription)")
                                   } else {
                                       print("✅ Data sent successfully!")
                                       self?.logger.info("OBD", "Data uploaded successfully to server")
                                       let formatter = DateFormatter()
                                       formatter.timeStyle = .medium
                                       self?.lastUploadTime = formatter.string(from: Date())
                                   }
                               }
                               connection.cancel()
                           })
                           
                       case .failed(let error):
                           connectionTimeoutTimer?.invalidate()
                           print("❌ Server connection failed: \(error)")
                           self?.logger.error("OBD", "Server connection failed: \(error.localizedDescription)")
                           self?.handleUploadFailure(message: message, maxRetries: maxRetries, currentAttempt: currentAttempt, error: "Connection failed: \(error.localizedDescription)")
                           connection.cancel()
                           
                       case .cancelled:
                           connectionTimeoutTimer?.invalidate()
                           print("🚫 Server connection cancelled")
                           self?.logger.warning("OBD", "Server connection cancelled")
                           
                       case .waiting(let error):
                           print("⏳ Server connection waiting: \(error)")
                           self?.logger.debug("OBD", "Server connection waiting: \(error.localizedDescription)")
                           // Don't fail immediately on waiting state
                           
                       default:
                           print("📡 Server connection state: \(state)")
                           self?.logger.debug("OBD", "Server connection state: \(state)")
                           break
                       }
                   }
                   
                   // Start connection with overall timeout
                   connection.start(queue: .global(qos: .background))
                   
                   // Set a backup timeout timer
                   connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
                       print("⏰ Connection timeout after 15 seconds")
                       self.logger.warning("OBD", "Server connection timeout after 15 seconds")
                       connection.cancel()
                       self.handleUploadFailure(message: message, maxRetries: maxRetries, currentAttempt: currentAttempt, error: "Connection timeout")
                   }
               }

    private func handleUploadFailure(message: String, maxRetries: Int, currentAttempt: Int, error: String) {
           if currentAttempt < maxRetries {
               print("🔄 Upload failed, retrying in 5 seconds... (\(currentAttempt)/\(maxRetries))")
               logger.warning("OBD", "Upload failed, retrying in 5 seconds (attempt \(currentAttempt)/\(maxRetries)): \(error)")
               DispatchQueue.main.async {
                   self.lastUploadTime = "Retrying... (\(currentAttempt)/\(maxRetries))"
               }
               
               DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 5.0) {
                   self.uploadWithRetry(message: message, maxRetries: maxRetries, currentAttempt: currentAttempt + 1)
               }
           } else {
               print("❌ Upload failed after \(maxRetries) attempts: \(error)")
               logger.error("OBD", "Upload failed after \(maxRetries) attempts: \(error)")
               DispatchQueue.main.async {
                   self.lastUploadTime = "Failed: \(error)"
               }
           }
       }
       
       func testServerConnection() {
           print("Testing server connectivity...")
           logger.info("OBD", "Testing server connectivity to \(serverHost):\(serverPort)")
           
           let host = NWEndpoint.Host(serverHost)
           let port = NWEndpoint.Port(rawValue: serverPort)!
           let connection = NWConnection(host: host, port: port, using: .tcp)
           
           connection.stateUpdateHandler = { state in
               print("Test connection state: \(state)")
               self.logger.debug("OBD", "Server test connection state: \(state)")
               switch state {
               case .ready:
                   print("✅ Server is reachable")
                   self.logger.info("OBD", "Server connectivity test successful")
                   connection.cancel()
               case .failed(let error):
                   print("❌ Server not reachable: \(error)")
                   self.logger.error("OBD", "Server connectivity test failed: \(error.localizedDescription)")
                   connection.cancel()
               default:
                   break
               }
           }
           
           connection.start(queue: .global())
           
           // Auto-cancel after 10 seconds
           DispatchQueue.global().asyncAfter(deadline: .now() + 10.0) {
               connection.cancel()
           }
       }
       
       private func formatOBDMessage(data: VehicleData, location: CLLocation?) -> String {
           let timestamp = DateFormatter()
           timestamp.dateFormat = "HHmmss"
           let timeStr = timestamp.string(from: Date())
           
           // Use real GPS coordinates
           let lat = location?.coordinate.latitude ?? 0.0
           let lon = location?.coordinate.longitude ?? 0.0
           
           let runtimeMinutes = data.engineRuntime / 60
           let milStatus = data.milOn ? "1" : "0"
           
           // Use actual detected protocol number instead of hardcoded 6
           let currentProtocolNumber = data.currentProtocolNumber
           let totalSupportedPidsRead = 17
           let totalSupportedPids = 17
           
           let deviceNameToUse = obdDeviceName.isEmpty ? deviceName : obdDeviceName
           
           let formattedMessage = "*OBD,\(deviceNameToUse),\(timeStr)," +
                  "\(Int(data.rpm)),\(String(format: "%.1f", data.speed))," +
                  "\(String(format: "%.1f", data.engineLoad)),\(Int(data.coolantTemp))," +
                  "\(Int(data.intakeAirTemp)),\(String(format: "%.1f", data.throttlePosition))," +
                  "\(String(format: "%.1f", data.fuelLevel)),\(String(format: "%.2f", data.voltage))," +
                  "\(Int(data.ambientAirTemp)),\(String(format: "%.6f", lat))," +
                  "\(String(format: "%.6f", lon)),\(runtimeMinutes)," +
                  "\(String(format: "%.2f", data.mafRate)),\(String(format: "%.1f", data.timingAdvance))," +
                  "\(String(format: "%.1f", data.relativeThrottlePos))," +
                  "\(String(format: "%.1f", data.shortFuelTrim1)),\(String(format: "%.1f", data.longFuelTrim1))," +
                  "\(String(format: "%.1f", data.shortFuelTrim2)),\(String(format: "%.1f", data.longFuelTrim2))," +
                  "\(data.obdStandards),\(currentProtocolNumber),\(data.dtcCount)," +
                  "[\(data.rawDTC)],\(milStatus),\(totalSupportedPidsRead),\(totalSupportedPids),#"
           
           logger.info("OBD", "Formatted OBD message with \(formattedMessage.count) characters")
           return formattedMessage
       }
      
      func startBackgroundMonitoring() {
          print("Starting background monitoring...")
          logger.info("OBD", "Starting background monitoring")
          // Placeholder for background setup
      }
      
      private func setupBackgroundTask() {
          print("Setting up background task...")
          logger.debug("OBD", "Setting up background task configuration")
          // Placeholder for background task setup
      }

       // Add these methods to OBDManager
       func testWiFiConnection() {
           print("🧪 Testing WiFi connection only...")
           logger.info("OBD", "Testing WiFi connection only")
           connectWiFi { success in
               print("🧪 WiFi test result: \(success)")
               self.logger.info("OBD", "WiFi connection test result: \(success)")
           }
       }

       func testBluetoothConnection() {
           print("🧪 Testing Bluetooth connection only...")
           logger.info("OBD", "Testing Bluetooth connection only")
           connectBluetooth()
       }
       
       // MARK: - Protocol Detection

       private func detectCurrentProtocol(completion: @escaping (Int) -> Void) {
           print("🔍 Detecting current OBD protocol...")
           logger.info("OBD", "Starting OBD protocol detection")
           
           sendOBDCommand("ATDPN") { response in
               let protocolNumber = self.parseProtocolNumber(response: response)
               print("📡 Current protocol: \(protocolNumber) (\(self.getProtocolName(protocolNumber)))")
               self.logger.info("OBD", "Detected protocol: \(protocolNumber) (\(self.getProtocolName(protocolNumber)))")
               completion(protocolNumber)
           }
       }

       private func parseProtocolNumber(response: String) -> Int {
           let cleanResponse = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
           print("🔍 Protocol response: '\(cleanResponse)'")
           logger.debug("OBD", "Parsing protocol from response: '\(cleanResponse)'")
           
           // Handle different response formats
           let protocolNumber: Int
           if cleanResponse == "A" {
               protocolNumber = 1 // SAE J1850 PWM (41.6 kbaud)
           } else if cleanResponse == "B" {
               protocolNumber = 2 // SAE J1850 VPW (10.4 kbaud)
           } else if cleanResponse == "C" {
               protocolNumber = 3 // ISO 9141-2 (5 baud init)
           } else if cleanResponse == "D" {
               protocolNumber = 4 // ISO 14230-4 KWP (5 baud init)
           } else if cleanResponse == "E" {
               protocolNumber = 5 // ISO 14230-4 KWP (fast init)
           } else if cleanResponse == "6" {
               protocolNumber = 6 // ISO 15765-4 CAN (11 bit ID, 500 kbaud)
           } else if cleanResponse == "7" {
               protocolNumber = 7 // ISO 15765-4 CAN (29 bit ID, 500 kbaud)
           } else if cleanResponse == "8" {
               protocolNumber = 8 // ISO 15765-4 CAN (11 bit ID, 250 kbaud)
           } else if cleanResponse == "9" {
               protocolNumber = 9 // ISO 15765-4 CAN (29 bit ID, 250 kbaud)
           } else if cleanResponse == "A0" || cleanResponse == "0A" {
               protocolNumber = 10 // SAE J1939 CAN (29 bit ID, 250 kbaud)
           } else if let number = Int(cleanResponse) {
               protocolNumber = number
           } else {
               print("⚠️ Unknown protocol response: \(cleanResponse), defaulting to 6 (CAN)")
               logger.warning("OBD", "Unknown protocol response: '\(cleanResponse)', defaulting to 6 (CAN)")
               protocolNumber = 6 // Default to most common protocol
           }
           
           logger.debug("OBD", "Protocol number parsed as: \(protocolNumber)")
           return protocolNumber
       }

       private func getProtocolName(_ protocolNumber: Int) -> String {
           switch protocolNumber {
           case 1: return "SAE J1850 PWM (41.6 kbaud)"
           case 2: return "SAE J1850 VPW (10.4 kbaud)"
           case 3: return "ISO 9141-2 (5 baud init)"
           case 4: return "ISO 14230-4 KWP (5 baud init)"
           case 5: return "ISO 14230-4 KWP (fast init)"
           case 6: return "ISO 15765-4 CAN (11 bit ID, 500 kbaud)"
           case 7: return "ISO 15765-4 CAN (29 bit ID, 500 kbaud)"
           case 8: return "ISO 15765-4 CAN (11 bit ID, 250 kbaud)"
           case 9: return "ISO 15765-4 CAN (29 bit ID, 250 kbaud)"
           case 10: return "SAE J1939 CAN (29 bit ID, 250 kbaud)"
           default: return "Unknown Protocol \(protocolNumber)"
           }
       }

       func detectProtocolManually() {
           guard isConnected else {
               print("❌ Not connected to OBD adapter")
               logger.warning("OBD", "Cannot detect protocol - not connected to OBD adapter")
               return
           }
           
           detectCurrentProtocol { protocolNumber in
               DispatchQueue.main.async {
                   if var currentData = self.currentVehicleData {
                       currentData.currentProtocolNumber = protocolNumber
                       currentData.protocolName = self.getProtocolName(protocolNumber)
                       self.currentVehicleData = currentData
                   }
               }
           }
       }

       func scanAllBluetoothDevices() {
           print("🔍 Scanning for ALL Bluetooth devices...")
           logger.info("OBD", "Starting comprehensive Bluetooth device scan")
           
           guard bluetoothManager?.state == .poweredOn else {
               print("❌ Bluetooth not available")
               logger.warning("OBD", "Cannot scan - Bluetooth not available")
               return
           }
           
           bluetoothManager?.scanForPeripherals(withServices: nil, options: [
               CBCentralManagerScanOptionAllowDuplicatesKey: true
           ])
           
           DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
               self.bluetoothManager?.stopScan()
               print("🛑 Bluetooth scan completed")
               self.logger.info("OBD", "Bluetooth device scan completed")
           }
       }
    }

    // MARK: - Enhanced Bluetooth Delegate Implementation

    extension OBDManager: CBCentralManagerDelegate, CBPeripheralDelegate {
      func centralManagerDidUpdateState(_ central: CBCentralManager) {
          print("🔵 Bluetooth state updated: \(central.state.rawValue)")
          logger.info("OBD", "Bluetooth central manager state updated: \(central.state.rawValue)")
          
          switch central.state {
          case .poweredOn:
              print("✅ Bluetooth powered on, scanning for devices...")
              logger.info("OBD", "Bluetooth powered on, starting device scan")
              central.scanForPeripherals(withServices: nil, options: [
                  CBCentralManagerScanOptionAllowDuplicatesKey: false
              ])
              connectionStatus = "Scanning for Bluetooth devices..."
              
          case .poweredOff:
              logger.warning("OBD", "Bluetooth is powered off")
              connectionStatus = "Bluetooth is off"
              
          case .unauthorized:
              logger.error("OBD", "Bluetooth access not authorized")
              connectionStatus = "Bluetooth not authorized"
              
          case .unsupported:
              logger.error("OBD", "Bluetooth not supported on this device")
              connectionStatus = "Bluetooth not supported"
              
          default:
              logger.warning("OBD", "Bluetooth not available, state: \(central.state.rawValue)")
              connectionStatus = "Bluetooth not available"
          }
      }
      
      func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
          let deviceName = peripheral.name ?? "Unknown"
          print("🔍 Discovered Bluetooth device: '\(deviceName)' (RSSI: \(RSSI))")
          logger.debug("OBD", "Discovered Bluetooth device: '\(deviceName)' with RSSI: \(RSSI)")
          
          // Print advertisement data for debugging
          if !advertisementData.isEmpty {
              print("📡 Advertisement data: \(advertisementData)")
              logger.debug("OBD", "Advertisement data: \(advertisementData)")
          }
          
          // Look for ELM327 or OBD devices with more specific matching
          let obdKeywords = ["ELM", "OBD", "V-LINK", "OBDII", "VEEPEAK", "KIWI", "BAFX", "BLUETOOTH", "SPP", "VIECAR"]
          let isOBDDevice = obdKeywords.contains { keyword in
              deviceName.uppercased().contains(keyword.uppercased())
          }
          
          // Also check if it's a generic Bluetooth serial device
          let hasSerialService = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] != nil
          
          if isOBDDevice || (deviceName != "Unknown" && RSSI.intValue > -80) {
              print("✅ Potential OBD device found: '\(deviceName)'")
              print("   Connecting to device...")
              logger.info("OBD", "Found potential OBD device: '\(deviceName)', attempting connection")
              
              connectedPeripheral = peripheral
              peripheral.delegate = self
              
              // Stop scanning and connect
              central.stopScan()
              central.connect(peripheral, options: [
                  CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                  CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
              ])
              connectionStatus = "Connecting to \(deviceName)..."
          }
      }
      
      func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
          print("✅ Connected to Bluetooth device: \(peripheral.name ?? "Unknown")")
          logger.info("OBD", "Successfully connected to Bluetooth device: '\(peripheral.name ?? "Unknown")'")
          isConnected = true
          connectionStatus = "Connected (Bluetooth)"
          
          // Extract device name from Bluetooth device name
          extractDeviceNameFromBluetooth(peripheral.name ?? "Unknown")
          
          // Start discovering services
          peripheral.discoverServices(nil)
          
          // Set connection timeout
          DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
              if self.obdCharacteristic == nil {
                  print("⏰ Bluetooth service discovery timeout")
                  self.logger.warning("OBD", "Bluetooth service discovery timeout after 15 seconds")
                  central.cancelPeripheralConnection(peripheral)
              }
          }
      }
        
    private func extractDeviceNameFromBluetooth(_ bluetoothName: String) {
        // First check if we have a configured device
        if deviceSettings.hasDevices() {
            obdDeviceName = deviceSettings.getDeviceName()
            logger.debug("OBD", "Using configured device name: \(obdDeviceName)")
            return
        }
        
        // Auto-detect from Bluetooth name
        if bluetoothName.contains("_") {
            let components = bluetoothName.components(separatedBy: "_")
            if components.count >= 2 {
                obdDeviceName = components[1] // Extract "TOOMTI123456"
            } else {
                obdDeviceName = bluetoothName
            }
        } else {
            obdDeviceName = bluetoothName
        }
        
        logger.debug("OBD", "Auto-detected device name from Bluetooth: \(obdDeviceName)")
    }
      
      func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
          print("❌ Failed to connect to Bluetooth device: \(error?.localizedDescription ?? "Unknown error")")
          logger.error("OBD", "Failed to connect to Bluetooth device '\(peripheral.name ?? "Unknown")': \(error?.localizedDescription ?? "Unknown error")")
          connectionStatus = "Bluetooth Connection Failed"
          isConnected = false
          
          // Continue scanning for other devices
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
              if central.state == .poweredOn && !self.isConnected {
                  self.logger.debug("OBD", "Resuming Bluetooth scan after connection failure")
                  central.scanForPeripherals(withServices: nil, options: nil)
                  self.connectionStatus = "Scanning for Bluetooth devices..."
              }
          }
      }
      
      func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
          print("🔍 Discovered Bluetooth services")
          logger.debug("OBD", "Discovered services for peripheral: '\(peripheral.name ?? "Unknown")'")
          
          if let error = error {
              logger.error("OBD", "Service discovery error: \(error.localizedDescription)")
              return
          }
          
          guard let services = peripheral.services else {
              logger.warning("OBD", "No services found for peripheral")
              return
          }
          
          print("📋 Found \(services.count) services:")
          for service in services {
              print("   Service: \(service.uuid)")
              logger.debug("OBD", "Discovered service: \(service.uuid)")
              peripheral.discoverCharacteristics(nil, for: service)
          }
      }
      
      func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
          print("🔍 Discovered characteristics for service: \(service.uuid)")
          logger.debug("OBD", "Discovered characteristics for service: \(service.uuid)")
          
          if let error = error {
              logger.error("OBD", "Characteristic discovery error: \(error.localizedDescription)")
              return
          }
          
          guard let characteristics = service.characteristics else { return }
          
          var writeCharacteristic: CBCharacteristic?
          var notifyCharacteristic: CBCharacteristic?
          
          for characteristic in characteristics {
              let properties = characteristic.properties
              print("📝 Characteristic: \(characteristic.uuid)")
              print("   Properties: \(describeCharacteristicProperties(properties))")
              logger.debug("OBD", "Characteristic: \(characteristic.uuid), properties: \(describeCharacteristicProperties(properties))")
              
              // Look for characteristics that support writing
              if properties.contains(.write) {
                  print("✅ Found WRITE characteristic: \(characteristic.uuid)")
                  logger.info("OBD", "Found WRITE characteristic: \(characteristic.uuid)")
                  writeCharacteristic = characteristic
              }
              
              if properties.contains(.writeWithoutResponse) {
                  print("✅ Found WRITE_WITHOUT_RESPONSE characteristic: \(characteristic.uuid)")
                  logger.info("OBD", "Found WRITE_WITHOUT_RESPONSE characteristic: \(characteristic.uuid)")
                  writeCharacteristic = characteristic // Prefer this for OBD
              }
              
              // Look for notification characteristic
              if properties.contains(.notify) {
                  print("✅ Found NOTIFY characteristic: \(characteristic.uuid)")
                  logger.info("OBD", "Found NOTIFY characteristic: \(characteristic.uuid)")
                  notifyCharacteristic = characteristic
              }
              
              if properties.contains(.indicate) {
                  print("✅ Found INDICATE characteristic: \(characteristic.uuid)")
                  logger.info("OBD", "Found INDICATE characteristic: \(characteristic.uuid)")
                  notifyCharacteristic = characteristic
              }
          }
          
          // Set up the characteristics
          if let writeChar = writeCharacteristic {
              obdCharacteristic = writeChar
              print("✅ Using write characteristic: \(writeChar.uuid)")
              logger.info("OBD", "Using write characteristic: \(writeChar.uuid)")
              
              // Enable notifications on the same or different characteristic
              let notifyChar = notifyCharacteristic ?? writeChar
              if notifyChar.properties.contains(.notify) || notifyChar.properties.contains(.indicate) {
                  print("🔔 Enabling notifications on: \(notifyChar.uuid)")
                  logger.debug("OBD", "Enabling notifications on characteristic: \(notifyChar.uuid)")
                  peripheral.setNotifyValue(true, for: notifyChar)
              }
              
              // Start ELM327 initialization
              print("🚀 Starting ELM327 initialization via Bluetooth...")
              logger.info("OBD", "Starting ELM327 initialization via Bluetooth")
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { // Small delay
                  self.initializeELM327()
              }
              
          } else {
              print("❌ No writable characteristic found!")
              logger.error("OBD", "No writable characteristic found")
              connectionStatus = "No writable characteristic"
              
              // List all characteristics for debugging
              print("🔍 Available characteristics:")
              logger.debug("OBD", "Available characteristics:")
              for char in characteristics {
                  print("   \(char.uuid): \(describeCharacteristicProperties(char.properties))")
                  logger.debug("OBD", "   \(char.uuid): \(describeCharacteristicProperties(char.properties))")
              }
          }
      }

      private func describeCharacteristicProperties(_ properties: CBCharacteristicProperties) -> String {
          var descriptions: [String] = []
          
          if properties.contains(.read) { descriptions.append("READ") }
          if properties.contains(.write) { descriptions.append("WRITE") }
          if properties.contains(.writeWithoutResponse) { descriptions.append("WRITE_NO_RESPONSE") }
          if properties.contains(.notify) { descriptions.append("NOTIFY") }
          if properties.contains(.indicate) { descriptions.append("INDICATE") }
          if properties.contains(.broadcast) { descriptions.append("BROADCAST") }
          if properties.contains(.authenticatedSignedWrites) { descriptions.append("SIGNED_WRITE") }
          if properties.contains(.extendedProperties) { descriptions.append("EXTENDED") }
          
          return descriptions.joined(separator: ", ")
      }
       
       func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
           guard let data = characteristic.value,
                 let response = String(data: data, encoding: .utf8) else {
               logger.warning("OBD", "Received invalid data from Bluetooth characteristic")
               return
           }
           
           print("Received Bluetooth data: \(response)")
           logger.info("OBD", "Received Bluetooth data: '\(response)'")
           
           // Accumulate response data
           responseBuffer += response
           
           // Handle SEARCHING state
           if responseBuffer.uppercased().contains("SEARCHING") {
               print("Bluetooth: ELM327 is SEARCHING, continuing to wait...")
               logger.debug("OBD", "Bluetooth: ELM327 is SEARCHING, continuing to wait...")
               // Don't complete the response yet, keep accumulating
               return
           }
           
           // Check if response is complete
           if responseBuffer.contains(">") ||
              responseBuffer.contains("OK") ||
              responseBuffer.contains("ERROR") ||
              responseBuffer.contains("NO DATA") ||
              responseBuffer.contains("UNABLE TO CONNECT") {
               
               let finalResponse = responseBuffer
                   .replacingOccurrences(of: ">", with: "")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
               
               print("Complete Bluetooth response: \(finalResponse)")
               logger.debug("OBD", "Complete Bluetooth response: '\(finalResponse)'")
               
               // Find and call the appropriate completion handler
               if let completion = pendingResponses.values.first {
                   pendingResponses.removeAll()
                   completion(finalResponse)
               }
               
               responseBuffer = "" // Clear for next response
           }
       }
       
       func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
           if let error = error {
               print("[ERROR] OBD: Bluetooth write error: \(error)")
               logger.error("OBD", "Bluetooth write error: \(error.localizedDescription)")
               if let completion = pendingResponses.values.first {
                   pendingResponses.removeAll()
                   completion("WRITE_ERROR: \(error.localizedDescription)")
               }
           } else {
               print("[INFO] OBD: Bluetooth write successful")
               logger.info("OBD", "Bluetooth write successful")
           }
           // Write successful, now wait for response via didUpdateValueFor
       }
       
       func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
           print("Bluetooth peripheral disconnected: \(error?.localizedDescription ?? "Unknown reason")")
           logger.warning("OBD", "Bluetooth peripheral disconnected: \(error?.localizedDescription ?? "Unknown reason")")
           isConnected = false
           connectionStatus = "Bluetooth Disconnected"
           connectedPeripheral = nil
           obdCharacteristic = nil
           stopDataCollection()
       }
    }
