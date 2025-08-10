//
//  LocationManager.swift
//  Toomti Tracker
//
//  Created by Abdulmajid Isiaka on 10/08/2025.
//


import CoreLocation
import CoreMotion
import Combine

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()
    
    @Published var isAuthorized = false
    @Published var authorizationStatus = "Unknown"
    @Published var currentLocation: CLLocation?
    
    private let locationManager = CLLocationManager()
    private var motionActivityManager: CMMotionActivityManager?
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10 // 10 meters
        
        updateAuthorizationStatus()
    }
    
    func requestPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            authorizationStatus = "Permission Denied"
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startLocationUpdates()
        @unknown default:
            break
        }
    }
    
    private func startLocationUpdates() {
        guard isAuthorized else { return }
        
        locationManager.startUpdatingLocation()
        locationManager.startMonitoringSignificantLocationChanges()
        
        // Start motion detection
        startMotionDetection()
    }
    
    private func startMotionDetection() {
        motionActivityManager = CMMotionActivityManager()
        
        if CMMotionActivityManager.isActivityAvailable() {
            motionActivityManager?.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity = activity else { return }
                
                // Trigger OBD data collection on motion
                if activity.automotive || activity.cycling || activity.running {
                    self?.triggerDataCollection()
                }
            }
        }
    }
    
    private func triggerDataCollection() {
        // Notify OBD manager to collect data
        NotificationCenter.default.post(name: NSNotification.Name("MotionDetected"), object: nil)
    }
    
    private func updateAuthorizationStatus() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            authorizationStatus = "Not Determined"
            isAuthorized = false
        case .denied:
            authorizationStatus = "Denied"
            isAuthorized = false
        case .restricted:
            authorizationStatus = "Restricted"
            isAuthorized = false
        case .authorizedWhenInUse:
            authorizationStatus = "When In Use"
            isAuthorized = true
        case .authorizedAlways:
            authorizationStatus = "Always"
            isAuthorized = true
        @unknown default:
            authorizationStatus = "Unknown"
            isAuthorized = false
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        updateAuthorizationStatus()
        
        if isAuthorized {
            startLocationUpdates()
        }
    }
}
