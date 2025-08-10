import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()
    
    @Published var isAuthorized = false
    @Published var authorizationStatus = "Not Determined"
    @Published var currentLocation: CLLocation?
    
    private let locationManager = CLLocationManager()
    
    private override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        
        // Update status immediately
        updateAuthorizationStatus()
    }
    
    func requestPermission() {
        print("Current authorization status: \(locationManager.authorizationStatus.rawValue)")
        
        switch locationManager.authorizationStatus {
        case .notDetermined:
            print("Requesting location permission...")
            // Request "When In Use" first, then we can upgrade to "Always"
            locationManager.requestWhenInUseAuthorization()
            
        case .authorizedWhenInUse:
            print("Has 'When In Use' permission, requesting 'Always'...")
            locationManager.requestAlwaysAuthorization()
            
        case .denied, .restricted:
            print("Location permission denied/restricted")
            authorizationStatus = "Permission Denied - Enable in Settings"
            
        case .authorizedAlways:
            print("Already has 'Always' permission")
            startLocationUpdates()
            
        @unknown default:
            print("Unknown authorization status")
            break
        }
    }
    
    private func startLocationUpdates() {
        guard isAuthorized else {
            print("Not authorized to start location updates")
            return
        }
        
        print("Starting location updates...")
        locationManager.startUpdatingLocation()
        
        // Only start significant location changes if we have "Always" permission
        if locationManager.authorizationStatus == .authorizedAlways {
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }
    
    private func updateAuthorizationStatus() {
        DispatchQueue.main.async {
            switch self.locationManager.authorizationStatus {
            case .notDetermined:
                self.authorizationStatus = "Not Determined"
                self.isAuthorized = false
                
            case .denied:
                self.authorizationStatus = "Denied"
                self.isAuthorized = false
                
            case .restricted:
                self.authorizationStatus = "Restricted"
                self.isAuthorized = false
                
            case .authorizedWhenInUse:
                self.authorizationStatus = "When In Use"
                self.isAuthorized = true
                self.startLocationUpdates()
                
            case .authorizedAlways:
                self.authorizationStatus = "Always"
                self.isAuthorized = true
                self.startLocationUpdates()
                
            @unknown default:
                self.authorizationStatus = "Unknown"
                self.isAuthorized = false
            }
            
            print("Updated authorization status: \(self.authorizationStatus)")
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print("Received location update: \(locations.last?.coordinate ?? CLLocationCoordinate2D())")
        currentLocation = locations.last
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("Location authorization changed to: \(status.rawValue)")
        updateAuthorizationStatus()
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed with error: \(error.localizedDescription)")
    }
}
