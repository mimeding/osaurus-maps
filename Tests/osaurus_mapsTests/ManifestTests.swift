import Foundation
import Testing

@testable import osaurus_maps

@Suite("Plugin Manifest")
struct ManifestTests {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private func loadManifest() throws -> [String: Any] {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }

    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    let initPtr = apiPtr.load(
      fromByteOffset: fnPtrSize,
      as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
    let ctx = initPtr()

    let getManifestPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 3,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    guard let cStr = getManifestPtr(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)

    let freeStringPtr = apiPtr.load(
      fromByteOffset: 0,
      as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
    freeStringPtr(cStr)

    let destroyPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 2,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    destroyPtr(ctx)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func toolMap(from manifest: [String: Any]) -> [String: [String: Any]] {
    let capabilities = manifest["capabilities"] as? [String: Any]
    let tools = capabilities?["tools"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })
  }

  @Test("manifest has correct plugin identity")
  func pluginIdentity() throws {
    let manifest = try loadManifest()
    #expect(manifest["plugin_id"] as? String == "osaurus.maps")
  }

  @Test("manifest declares expected maps tools")
  func toolIDs() throws {
    let map = try toolMap(from: loadManifest())
    #expect(
      Set(map.keys) == [
        "maps_search_locations", "maps_save_location", "maps_get_directions", "maps_drop_pin",
        "maps_list_guides", "maps_add_to_guide", "maps_create_guide", "maps_get_current_location",
      ])
  }

  @Test("all maps tools require approval")
  func permissionPolicies() throws {
    let map = try toolMap(from: loadManifest())
    for (id, tool) in map {
      #expect(tool["permission_policy"] as? String == "ask", "Tool '\(id)' should ask")
    }
  }

  @Test("manifest distinguishes Maps automation and location requirements")
  func requirements() throws {
    let map = try toolMap(from: loadManifest())

    for id in [
      "maps_save_location", "maps_drop_pin", "maps_list_guides", "maps_add_to_guide",
      "maps_create_guide",
    ] {
      #expect(map[id]?["requirements"] as? [String] == ["maps"])
    }

    #expect(map["maps_get_current_location"]?["requirements"] as? [String] == ["location"])
    #expect(map["maps_get_directions"]?["requirements"] as? [String] == ["location"])

    let directionsDescription =
      (map["maps_get_directions"]?["description"] as? String ?? "").lowercased()
    #expect(directionsDescription.contains("current location"))
  }

  @Test("tools with location inputs declare required parameters")
  func requiredParameters() throws {
    let map = try toolMap(from: loadManifest())

    let searchParams = map["maps_search_locations"]?["parameters"] as? [String: Any]
    let searchRequired = searchParams?["required"] as? [String] ?? []
    #expect(searchRequired.contains("query"))

    let directionsParams = map["maps_get_directions"]?["parameters"] as? [String: Any]
    let directionsRequired = Set(directionsParams?["required"] as? [String] ?? [])
    #expect(directionsRequired == ["fromAddress", "toAddress"])

    let saveParams = map["maps_save_location"]?["parameters"] as? [String: Any]
    let saveRequired = Set(saveParams?["required"] as? [String] ?? [])
    #expect(saveRequired == ["name", "address"])
  }
}
