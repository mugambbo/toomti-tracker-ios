//
//  OBDManager.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//

import Foundation
import Network
import CoreBluetooth
import CoreLocation
import UIKit

class OBDManager: NSObject, ObservableObject {
    static let shared = OBDManager()
    
    @Published var isConnected = false
    @Published var connectionStatus = "Disconnected"
    @Published var currentVehicleData: VehicleData?
    @Published var lastUploadTime = "Never"
    
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
    
    // PIDs to query
    private let pidCommands: [(command: String, description: String)] = [
        ("010C", "Engine RPM"),
        ("010D", "Vehicle Speed"),
        ("0104", "Engine Load"),
        ("0105", "Coolant Temperature"),
        ("0111", "Throttle Position"),
        ("ATRV", "Battery Voltage")
    ]
    
    override init() {
        super.init()
        setupBackgroundTask()
    }
    
    // MARK: - Connection Management
    
    func connect() {
        connectionStatus = "Connecting..."
        
        // Try WiFi first, then Bluetooth
        connectWiFi { [weak self] success in
            if !success {
                DispatchQueue.main.async {
                    self?.connectBluetooth()
                }
            }
        }
    }
    
    func disconnect() {
        tcpConnection?.cancel()
        bluetoothManager?.stopScan()
        connectedPeripheral?.setNotifyValue(false, for: obdCharacteristic!)
        
        isConnected = false
        connectionStatus = "Disconnected"
        stopDataCollection()
    }
    
    // MARK: - WiFi Connection
    
    private func connectWiFi(completion: @escaping (Bool) -> Void) {
        let host = NWEndpoint.Host(obdWiFiHost)
        let port = NWEndpoint.Port(rawValue: obdWiFiPort)!
        
        tcpConnection = NWConnection(host: host, port: port, using: .tcp)
        
        tcpConnection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.connectionStatus = "Connected (WiFi)"
                    self?.initializeELM327()
                    completion(true)
                case .failed(let error):
                    print("WiFi connection failed: \(error)")
                    completion(false)
                case .cancelled:
                    self?.isConnected = false
                    self?.connectionStatus = "Disconnected"
                    completion(false)
                default:
                    break
                }
            }
        }
        
        tcpConnection?.start(queue: .global())
    }
    
    // MARK: - Bluetooth Connection
    
    private func connectBluetooth() {
        bluetoothManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - ELM327 Initialization
    
    private func initializeELM327() {
        let initCommands = [
            "ATZ",      // Reset
            "ATE0",     // Echo off
            "ATL0",     // Linefeeds off
            "ATS0",     // Spaces off
            "ATH0",     // Headers off
            "ATSPA0"    // Set protocol auto
        ]
        
        sendCommands(initCommands) { [weak self] in
            self?.startDataCollection()
        }
    }
    
    // MARK: - Data Collection
    
    private func startDataCollection() {
        dataTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.collectOBDData()
        }
        
        // Collect initial data
        collectOBDData()
    }
    
    private func stopDataCollection() {
        dataTimer?.invalidate()
        dataTimer = nil
    }
    
    private func collectOBDData() {
        guard isConnected else { return }
        
        var vehicleData = VehicleData()
        let group = DispatchGroup()
        
        for pidCommand in pidCommands {
            group.enter()
            
            sendOBDCommand(pidCommand.command) { [weak self] response in
                self?.parseOBDResponse(command: pidCommand.command, response: response, data: &vehicleData)
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            self?.currentVehicleData = vehicleData
            self?.uploadDataToServer(vehicleData)
        }
    }
    
    // MARK: - OBD Communication
    
    private func sendOBDCommand(_ command: String, completion: @escaping (String) -> Void) {
        let commandWithCR = command + "\r"
        
        if let tcpConnection = tcpConnection {
            // WiFi connection
            let data = commandWithCR.data(using: .utf8)!
            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("Send error: \(error)")
                    completion("")
                    return
                }
                
                // Read response
                tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, error in
                    if let data = data, let response = String(data: data, encoding: .utf8) {
                        completion(response)
                    } else {
                        completion("")
                    }
                }
            })
        } else if let peripheral = connectedPeripheral, let characteristic = obdCharacteristic {
            // Bluetooth connection
            let data = commandWithCR.data(using: .utf8)!
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            
            // Note: Response will come through characteristic notification
            // For simplicity, we'll use a timeout-based approach
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                completion("") // Simplified for demo
            }
        }
    }
    
    private func sendCommands(_ commands: [String], completion: @escaping () -> Void) {
        guard !commands.isEmpty else {
            completion()
            return
        }
        
        var remainingCommands = commands
        let currentCommand = remainingCommands.removeFirst()
        
        sendOBDCommand(currentCommand) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.sendCommands(remainingCommands, completion: completion)
            }
        }
    }
    
    // MARK: - Response Parsing
    
    private func parseOBDResponse(command: String, response: String, data: inout VehicleData) {
        let cleanResponse = response.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        
        switch command {
        case "010C": // RPM
            if let value = parseHexResponse(cleanResponse, expectedPrefix: "410C", bytes: 2) {
                data.rpm = Double(value) / 4.0
            }
        case "010D": // Speed
            if let value = parseHexResponse(cleanResponse, expectedPrefix: "410D", bytes: 1) {
                data.speed = Double(value)
            }
        case "0104": // Engine Load
            if let value = parseHexResponse(cleanResponse, expectedPrefix: "4104", bytes: 1) {
                data.engineLoad = Double(value) * 100.0 / 255.0
            }
        case "0105": // Coolant Temperature
            if let value = parseHexResponse(cleanResponse, expectedPrefix: "4105", bytes: 1) {
                data.coolantTemp = Double(value) - 40.0
            }
        case "0111": // Throttle Position
            if let value = parseHexResponse(cleanResponse, expectedPrefix: "4111", bytes: 1) {
                data.throttlePosition = Double(value) * 100.0 / 255.0
            }
        case "ATRV": // Battery Voltage
            if let voltage = Double(cleanResponse.replacingOccurrences(of: "V", with: "")) {
                data.voltage = voltage
            }
        default:
            break
        }
    }
    
    private func parseHexResponse(_ response: String, expectedPrefix: String, bytes: Int) -> UInt32? {
        guard response.hasPrefix(expectedPrefix) else { return nil }
        
        let dataStart = response.index(response.startIndex, offsetBy: expectedPrefix.count)
        let dataEnd = response.index(dataStart, offsetBy: bytes * 2)
        let hexData = String(response[dataStart..<dataEnd])
        
        return UInt32(hexData, radix: 16)
    }
    
    // MARK: - Server Communication
    
    private func uploadDataToServer(_ data: VehicleData) {
        guard let location = LocationManager.shared.currentLocation else { return }
        
        let message = formatOBDMessage(data: data, location: location)
        
        let host = NWEndpoint.Host(serverHost)
        let port = NWEndpoint.Port(rawValue: serverPort)!
        let connection = NWConnection(host: host, port: port, using: .tcp)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let messageData = message.data(using: .utf8)!
                connection.send(content: messageData, completion: .contentProcessed { error in
                    DispatchQueue.main.async {
                        if error == nil {
                            self.lastUploadTime = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                        }
                    }
                    connection.cancel()
                })
            case .failed(let error):
                print("Server connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        
        connection.start(queue: .global())
    }
    
    private func formatOBDMessage(data: VehicleData, location: CLLocation) -> String {
        let timestamp = DateFormatter()
        timestamp.dateFormat = "HHmmss"
        let timeStr = timestamp.string(from: Date())
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyMMdd"
        _ = dateFormatter.string(from: Date())
        
        return "*OBD,\(deviceName),\(timeStr),\(Int(data.rpm)),\(Int(data.speed)),\(Int(data.engineLoad)),\(Int(data.coolantTemp)),0,\(Int(data.throttlePosition)),0,\(String(format: "%.2f", data.voltage)),0,\(String(format: "%.6f", location.coordinate.latitude)),\(String(format: "%.6f", location.coordinate.longitude)),0,0,0,0,0,0,0,0,,0,,0,0,0,#"
    }
    
    func sendTestData() {
        let testData = VehicleData(
            rpm: 1500,
            speed: 60,
            engineLoad: 45,
            throttlePosition: 30,
            coolantTemp: 85,
            voltage: 12.4
        )
        
        if LocationManager.shared.currentLocation != nil {
            uploadDataToServer(testData)
        }
    }
    
    // MARK: - Background Processing
    
    func startBackgroundMonitoring() {
        // Configure background processing
        _ = "com.toomti.Toomti-Tracker"
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func appDidEnterBackground() {
        startBackgroundTask()
    }
    
    @objc private func appWillEnterForeground() {
        endBackgroundTask()
    }
    
    private func setupBackgroundTask() {
        // This would need to be configured in Info.plist for background modes
    }
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

// MARK: - Bluetooth Delegate

extension OBDManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
            connectionStatus = "Scanning for Bluetooth..."
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Look for ELM327 or OBD devices
        if let name = peripheral.name, (name.contains("ELM") || name.contains("OBD") || name.contains("V-LINK")) {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            central.stopScan()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectionStatus = "Connected (Bluetooth)"
        peripheral.discoverServices(nil)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                obdCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                initializeELM327()
                break
            }
        }
    }
}
