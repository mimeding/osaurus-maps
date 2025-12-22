import Contacts
import CoreLocation
import Foundation
import MapKit

// MARK: - Async Helper
// Helper to wait for async MapKit calls in a synchronous context
private func waitFor<T>(_ operation: (@escaping (T) -> Void) -> Void) -> T {
  var result: T?
  let semaphore = DispatchSemaphore(value: 0)

  operation { res in
    result = res
    semaphore.signal()
  }

  _ = semaphore.wait(timeout: .now() + 15)  // 15s timeout
  return result!
}

class LocationFetcher: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var completion: ((CLLocation?) -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }

  func fetch(completion: @escaping (CLLocation?) -> Void) {
    self.completion = completion
    // Check authorization
    let status = manager.authorizationStatus
    if status == .notDetermined {
      manager.requestWhenInUseAuthorization()
    }

    manager.startUpdatingLocation()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    if let location = locations.first {
      manager.stopUpdatingLocation()
      completion?(location)
      completion = nil
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    manager.stopUpdatingLocation()
    completion?(nil)
    completion = nil
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    if status == .denied || status == .restricted {
      manager.stopUpdatingLocation()
      completion?(nil)
      completion = nil
    }
  }
}

class MapsService {

  // MARK: - JXA Helper

  private func runJXA<T: Decodable, A: Encodable>(args: A, scriptBody: String, returnType: T.Type)
    throws -> T
  {
    let argsData = try JSONEncoder().encode(args)
    guard let argsString = String(data: argsData, encoding: .utf8) else {
      throw NSError(
        domain: "MapsPlugin", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Failed to encode arguments"])
    }

    // Construct the full script
    let fullScript = """
      const args = \(argsString);

      function run(args) {
          const app = Application.currentApplication();
          app.includeStandardAdditions = true;
          const Maps = Application("Maps");
          
          \(scriptBody)
      }

      JSON.stringify(run(args));
      """

    // Execute via osascript
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", fullScript]

    let pipe = Pipe()
    process.standardOutput = pipe
    let errPipe = Pipe()
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      let errOutput = String(data: errData, encoding: .utf8) ?? "Unknown error"
      // If output is empty, it might be a permission issue or syntax error
      throw NSError(
        domain: "MapsPlugin", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "JXA Error: \(errOutput)"])
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    // Handle potentially empty output
    if data.isEmpty {
      throw NSError(
        domain: "MapsPlugin", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "No output from JXA script"])
    }

    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      let outputStr = String(data: data, encoding: .utf8) ?? ""
      throw NSError(
        domain: "MapsPlugin", code: 0,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Failed to decode JXA output: \(error). Output was: \(outputStr)"
        ])
    }
  }

  // MARK: - Native MapKit Implementations

  func searchLocations(query: String, limit: Int) throws -> SearchResult {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    // Optional: Bias towards current location if available?
    // For now, global search.

    let search = MKLocalSearch(request: request)

    let response: MKLocalSearch.Response? = waitFor { completion in
      search.start { response, error in
        completion(response)
      }
    }

    guard let items = response?.mapItems else {
      return SearchResult(success: false, locations: [], message: "No locations found or timeout")
    }

    let locations = items.prefix(limit).map { item -> MapLocation in
      let placemark = item.placemark

      // Format address
      let addressParts = [
        placemark.thoroughfare,
        placemark.locality,
        placemark.administrativeArea,
        placemark.postalCode,
      ].compactMap { $0 }
      let address = addressParts.joined(separator: ", ")

      return MapLocation(
        id: UUID().uuidString,
        name: item.name ?? query,
        address: address.isEmpty ? "Unknown Address" : address,
        latitude: placemark.coordinate.latitude,
        longitude: placemark.coordinate.longitude,
        category: item.pointOfInterestCategory?.rawValue,
        isFavorite: false
      )
    }

    return SearchResult(
      success: true,
      locations: Array(locations),
      message: "Found \(locations.count) locations via MapKit"
    )
  }

  func getDirections(from: String, to: String, transport: String) throws -> DirectionResult {
    // Helper to resolve string to MKMapItem
    func resolveItem(_ query: String) -> MKMapItem? {
      if query.lowercased() == "current location" || query.lowercased() == "here" {
        return MKMapItem.forCurrentLocation()
      }

      let request = MKLocalSearch.Request()
      request.naturalLanguageQuery = query
      let search = MKLocalSearch(request: request)

      let response: MKLocalSearch.Response? = waitFor { completion in
        search.start { response, error in completion(response) }
      }
      return response?.mapItems.first
    }

    guard let sourceItem = resolveItem(from) else {
      return DirectionResult(
        success: false, message: "Could not find location: \(from)", route: nil)
    }

    guard let destItem = resolveItem(to) else {
      return DirectionResult(success: false, message: "Could not find location: \(to)", route: nil)
    }

    let request = MKDirections.Request()
    request.source = sourceItem
    request.destination = destItem
    request.requestsAlternateRoutes = false

    switch transport.lowercased() {
    case "walking": request.transportType = .walking
    case "transit": request.transportType = .transit
    default: request.transportType = .automobile
    }

    let directions = MKDirections(request: request)

    let response: MKDirections.Response? = waitFor { completion in
      directions.calculate { response, error in
        completion(response)
      }
    }

    guard let route = response?.routes.first else {
      return DirectionResult(
        success: false, message: "Could not find a route between these locations.", route: nil)
    }

    // Format duration
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.allowedUnits = [.hour, .minute]
    let durationStr =
      formatter.string(from: route.expectedTravelTime)
      ?? "\(Int(route.expectedTravelTime / 60)) mins"

    // Format distance
    let distFormatter = MKDistanceFormatter()
    let distanceStr = distFormatter.string(fromDistance: route.distance)

    return DirectionResult(
      success: true,
      message: "Route found",
      route: RouteInfo(
        distance: distanceStr,
        duration: durationStr,
        startAddress: sourceItem.placemark.title ?? from,
        endAddress: destItem.placemark.title ?? to
      )
    )
  }

  // MARK: - JXA Methods (UI Interactions)

  struct SaveArgs: Encodable {
    let name: String
    let address: String
  }

  func saveLocation(name: String, address: String) throws -> SaveResult {
    let script = """
          try {
              Maps.activate();
              Maps.search(args.address);
              delay(2);
              
              try {
                  const location = Maps.selectedLocation();
                  if (location) {
                      try {
                          // Try to add to favorites (API dependent)
                          Maps.addToFavorites(location, {withProperties: {name: args.name}});
                          return {
                              success: true,
                              message: `Added "${args.name}" to favorites`,
                              location: {
                                  id: `loc-${Date.now()}`,
                                  name: args.name,
                                  address: location.formattedAddress() || args.address,
                                  latitude: location.latitude(),
                                  longitude: location.longitude(),
                                  category: null,
                                  isFavorite: true
                              }
                          };
                      } catch (e) {
                          return {
                              success: false,
                              message: `Location found but unable to automatically add to favorites. Please manually save "${args.name}".`
                          };
                      }
                  } else {
                      return {
                          success: false,
                          message: `Could not find location "${args.address}" to save`
                      };
                  }
              } catch (e) {
                   return {
                      success: false,
                      message: `Error interacting with location: ${e.message}`
                  };
              }
          } catch (e) {
              return { success: false, message: e.message || e.toString() };
          }
      """
    return try runJXA(
      args: SaveArgs(name: name, address: address), scriptBody: script, returnType: SaveResult.self)
  }

  struct DropPinArgs: Encodable {
    let name: String
    let address: String
  }

  func dropPin(name: String, address: String) throws -> SaveResult {
    let script = """
          try {
              Maps.activate();
              Maps.search(args.address);
              delay(2);
              return {
                  success: true,
                  message: `Showing "${args.address}". Manually drop a pin if needed.`
              };
          } catch (e) {
              return { success: false, message: e.message || e.toString() };
          }
      """
    return try runJXA(
      args: DropPinArgs(name: name, address: address), scriptBody: script,
      returnType: SaveResult.self)
  }

  struct EmptyArgs: Encodable {}

  func listGuides() throws -> GuideResult {
    let script = """
          try {
              Maps.activate();
              app.openLocation("maps://?show=guides");
              return {
                  success: true,
                  message: "Opened guides view in Maps",
                  guides: []
              };
          } catch (e) {
              return { success: false, message: e.message || e.toString() };
          }
      """
    return try runJXA(args: EmptyArgs(), scriptBody: script, returnType: GuideResult.self)
  }

  struct AddToGuideArgs: Encodable {
    let locationAddress: String
    let guideName: String
  }

  func addToGuide(location: String, guide: String) throws -> AddToGuideResult {
    let script = """
          try {
              Maps.activate();
              const encodedAddress = encodeURIComponent(args.locationAddress);
              app.openLocation(`maps://?q=${encodedAddress}`);
              
              return {
                  success: true,
                  message: `Showing location. Please add to guide "${args.guideName}" manually.`,
                  guideName: args.guideName,
                  locationName: args.locationAddress
              };
          } catch (e) {
              return { success: false, message: e.message || e.toString() };
          }
      """
    return try runJXA(
      args: AddToGuideArgs(locationAddress: location, guideName: guide), scriptBody: script,
      returnType: AddToGuideResult.self)
  }

  struct CreateGuideArgs: Encodable {
    let guideName: String
  }

  func createGuide(name: String) throws -> AddToGuideResult {
    let script = """
          try {
              Maps.activate();
              app.openLocation("maps://?show=guides");
              return {
                  success: true,
                  message: `Opened guides view. Please create guide "${args.guideName}" manually.`,
                  guideName: args.guideName
              };
          } catch (e) {
               return { success: false, message: e.message || e.toString() };
          }
      """
    return try runJXA(
      args: CreateGuideArgs(guideName: name), scriptBody: script, returnType: AddToGuideResult.self)
  }

  func getCurrentLocation() -> MapLocation? {
    var result: CLLocation?
    var finished = false

    let fetcher = LocationFetcher()
    fetcher.fetch { loc in
      result = loc
      finished = true
    }

    // Pump the runloop until we get a result or timeout
    // CoreLocation events need a run loop to fire.
    let start = Date()
    while !finished && Date().timeIntervalSince(start) < 10 {  // 10s timeout
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }

    guard let loc = result else { return nil }

    // Reverse geocode for better context
    var addressString = "Lat: \(loc.coordinate.latitude), Long: \(loc.coordinate.longitude)"
    let geocoder = CLGeocoder()
    let semaphore = DispatchSemaphore(value: 0)
    geocoder.reverseGeocodeLocation(loc) { placemarks, _ in
      if let p = placemarks?.first {
        let parts = [p.name, p.locality, p.administrativeArea].compactMap { $0 }
        addressString = parts.joined(separator: ", ")
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)

    return MapLocation(
      id: "current-location",
      name: "Current Location",
      address: addressString,
      latitude: loc.coordinate.latitude,
      longitude: loc.coordinate.longitude,
      category: "Current Location",
      isFavorite: false
    )
  }
}
