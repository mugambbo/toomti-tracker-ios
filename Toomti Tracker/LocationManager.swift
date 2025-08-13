import CoreLocation
import Combine

class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()
    private let logger = LogManager.shared
    
    @Published var isAuthorized = false
    @Published var authorizationStatus = "Not Determined"
    @Published var currentLocation: CLLocation?
    
    private let locationManager = CLLocationManager()
    private var hasRequestedPermission = false // Add this flag
    
    private override init() {
        super.init()
        setupLocationManager()
    }
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        updateAuthorizationStatus()
    }
    
    func requestPermission() {
        logger.info("Location", "Requesting location permission")
        
        // Prevent multiple requests
        guard !hasRequestedPermission else {
            print("Permission already requested, skipping...")
            return
        }
        
        print("Current authorization status: \(locationManager.authorizationStatus.rawValue)")
        
        switch locationManager.authorizationStatus {
        case .notDetermined:
            logger.debug("Location", "Status: Not determined, requesting permission")
            print("Requesting location permission...")
            hasRequestedPermission = true
            locationManager.requestWhenInUseAuthorization()
            
        case .authorizedWhenInUse:
            logger.warning("Location", "Authorized when in Use")
            print("Has 'When In Use' permission, requesting 'Always'...")
            locationManager.requestAlwaysAuthorization()
            
        case .denied, .restricted:
            logger.warning("Location", "Permission denied by user")
            print("Location permission denied/restricted")
            authorizationStatus = "Permission Denied - Enable in Settings"
            
        case .authorizedAlways:
            logger.warning("Location", "Authorized always")
            print("Already has 'Always' permission")
            startLocationUpdates()
            
        @unknown default:
            logger.warning("Location", "Permission not understood")
            print("Unknown authorization status")
            break
        }
    }
    
    // Add this method to manually trigger permission request
    func forceRequestPermission() {
        hasRequestedPermission = false
        requestPermission()
    }
    
    private func startLocationUpdates() {
        guard isAuthorized else {
            print("Not authorized to start location updates")
            return
        }
        
        print("Starting location updates...")
        locationManager.startUpdatingLocation()
        
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
        
        // Auto-request "Always" permission after getting "When In Use"
        if status == .authorizedWhenInUse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("Requesting upgrade to 'Always' permission...")
                self.locationManager.requestAlwaysAuthorization()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed with error: \(error.localizedDescription)")
    }
}
