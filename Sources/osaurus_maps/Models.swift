import Foundation

// MARK: - Models

struct MapLocation: Codable {
  let id: String
  let name: String
  let address: String
  let latitude: Double?
  let longitude: Double?
  let category: String?
  let isFavorite: Bool
}

struct Guide: Codable {
  let id: String
  let name: String
  let itemCount: Int
}

struct SearchResult: Codable {
  let success: Bool
  let locations: [MapLocation]?
  let message: String?
}

struct SaveResult: Codable {
  let success: Bool
  let message: String
  let location: MapLocation?
}

struct RouteInfo: Codable {
  let distance: String
  let duration: String
  let startAddress: String
  let endAddress: String
}

struct DirectionResult: Codable {
  let success: Bool
  let message: String
  let route: RouteInfo?
}

struct GuideResult: Codable {
  let success: Bool
  let message: String
  let guides: [Guide]?
}

struct AddToGuideResult: Codable {
  let success: Bool
  let message: String
  let guideName: String?
  let locationName: String?
}
