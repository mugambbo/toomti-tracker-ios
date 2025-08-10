import Foundation
import UIKit
import Network
import CoreBluetooth
import CoreLocation
import BackgroundTasks

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
    
    private override init() {
        super.init()
        setupBackgroundTask()
    }
    
    // MARK: - Connection Management
    
    func connect() {
        print("Connect button pressed")
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
        print("Disconnect button pressed")
        tcpConnection?.cancel()
        bluetoothManager?.stopScan()
        
        if let peripheral = connectedPeripheral, let characteristic = obdCharacteristic {
            peripheral.setNotifyValue(false, for: characteristic)
        }
        
        isConnected = false
        connectionStatus = "Disconnected"
        stopDataCollection()
    }
    
    func sendTestData() {
        print("Send Test Data button pressed")
        
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
        
        // Update the current vehicle data for UI display
        DispatchQueue.main.async {
            self.currentVehicleData = testData
        }
        
        // Send to server
        uploadDataToServer(testData)
        
        print("Test data created and upload initiated")
    }
    
    // MARK: - WiFi Connection
    
    private func connectWiFi(completion: @escaping (Bool) -> Void) {
        print("Attempting WiFi connection to \(obdWiFiHost):\(obdWiFiPort)")
        
        let host = NWEndpoint.Host(obdWiFiHost)
        let port = NWEndpoint.Port(rawValue: obdWiFiPort)!
        
        tcpConnection = NWConnection(host: host, port: port, using: .tcp)
        
        tcpConnection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("WiFi connection established")
                    self?.isConnected = true
                    self?.connectionStatus = "Connected (WiFi)"
                    self?.initializeELM327()
                    completion(true)
                case .failed(let error):
                    print("WiFi connection failed: \(error)")
                    self?.connectionStatus = "WiFi Failed"
                    completion(false)
                case .cancelled:
                    print("WiFi connection cancelled")
                    self?.isConnected = false
                    self?.connectionStatus = "Disconnected"
                    completion(false)
                default:
                    print("WiFi connection state: \(state)")
                    break
                }
            }
        }
        
        tcpConnection?.start(queue: .global())
    }
    
    // MARK: - Bluetooth Connection
    
    private func connectBluetooth() {
        print("Attempting Bluetooth connection")
        connectionStatus = "Scanning Bluetooth..."
        bluetoothManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Server Communication
    
    private func uploadDataToServer(_ data: VehicleData) {
        print("Starting upload to server...")
        
        let location = LocationManager.shared.currentLocation
        let message = formatOBDMessage(data: data, location: location)
        
        print("Formatted message: \(message)")
        
        let host = NWEndpoint.Host(serverHost)
        let port = NWEndpoint.Port(rawValue: serverPort)!
        let connection = NWConnection(host: host, port: port, using: .tcp)
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("Server connection established, sending data...")
                let messageData = message.data(using: .utf8)!
                connection.send(content: messageData, completion: .contentProcessed { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            print("Send error: \(error)")
                            self?.lastUploadTime = "Failed: \(error.localizedDescription)"
                        } else {
                            print("Data sent successfully")
                            let formatter = DateFormatter()
                            formatter.timeStyle = .medium
                            self?.lastUploadTime = formatter.string(from: Date())
                        }
                    }
                    connection.cancel()
                })
            case .failed(let error):
                print("Server connection failed: \(error)")
                DispatchQueue.main.async {
                    self?.lastUploadTime = "Connection Failed"
                }
                connection.cancel()
            case .cancelled:
                print("Server connection cancelled")
            default:
                print("Server connection state: \(state)")
                break
            }
        }
        
        connection.start(queue: .global())
    }
    
    private func formatOBDMessage(data: VehicleData, location: CLLocation?) -> String {
        let timestamp = DateFormatter()
        timestamp.dateFormat = "HHmmss"
        let timeStr = timestamp.string(from: Date())
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyMMdd"
        let dateStr = dateFormatter.string(from: Date())
        
        let lat = location?.coordinate.latitude ?? 9.0579 // Default to Abuja
        let lon = location?.coordinate.longitude ?? 7.4951
        
        let runtimeMinutes = data.engineRuntime / 60
        let milStatus = data.milOn ? "1" : "0"
        let currentProtocolNumber = 6
        let totalSupportedPidsRead = 15
        let totalSupportedPids = 20
        
        return "*OBD,\(deviceName),\(timeStr)," +
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
    }
    
    // MARK: - Placeholder methods for compilation
    
    private func initializeELM327() {
        print("Initializing ELM327...")
        startDataCollection()
    }
    
    private func startDataCollection() {
        print("Starting data collection...")
        dataTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.collectOBDData()
        }
    }
    
    private func stopDataCollection() {
        print("Stopping data collection...")
        dataTimer?.invalidate()
        dataTimer = nil
    }
    
    private func collectOBDData() {
        print("Collecting OBD data...")
        // For now, just create mock data
        let mockData = VehicleData(
            rpm: Double.random(in: 800...3000),
            speed: Double.random(in: 0...120),
            engineLoad: Double.random(in: 0...100),
            throttlePosition: Double.random(in: 0...100),
            coolantTemp: Double.random(in: 70...90),
            voltage: Double.random(in: 11.5...14.5),
            dataValid: true
        )
        
        DispatchQueue.main.async {
            self.currentVehicleData = mockData
        }
        
        uploadDataToServer(mockData)
    }
    
    func startBackgroundMonitoring() {
        print("Starting background monitoring...")
        // Placeholder for background setup
    }
    
    private func setupBackgroundTask() {
        print("Setting up background task...")
        // Placeholder for background task setup
    }
}

// MARK: - Bluetooth Delegate (Basic Implementation)

extension OBDManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Bluetooth state updated: \(central.state.rawValue)")
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
            connectionStatus = "Scanning for Bluetooth devices..."
        } else {
            connectionStatus = "Bluetooth not available"
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("Discovered peripheral: \(peripheral.name ?? "Unknown")")
        
        if let name = peripheral.name, (name.contains("ELM") || name.contains("OBD") || name.contains("V-LINK")) {
            connectedPeripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            central.stopScan()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to peripheral: \(peripheral.name ?? "Unknown")")
        isConnected = true
        connectionStatus = "Connected (Bluetooth)"
        peripheral.discoverServices(nil)
        initializeELM327()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        print("Discovered services")
        guard let services = peripheral.services else { return }
        
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("Discovered characteristics")
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                obdCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                break
            }
        }
    }
}
