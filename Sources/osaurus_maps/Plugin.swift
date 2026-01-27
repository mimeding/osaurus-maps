import Foundation

// MARK: - C ABI surface

// Opaque context
private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Function pointers
private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,  // type
    UnsafePointer<CChar>?,  // id
    UnsafePointer<CChar>?  // payload
  ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
}

// Context state
private class PluginContext {
  let maps = MapsService()
}

// Helper to return C strings
private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let cStr = strdup(s) else { return nil }
  return UnsafePointer(cStr)
}

// Helper to encode result to JSON string
private func encodeResult<T: Encodable>(_ result: T) -> String {
  do {
    let data = try JSONEncoder().encode(result)
    return String(data: data, encoding: .utf8) ?? "{}"
  } catch {
    return "{\"error\": \"\(error.localizedDescription)\"}"
  }
}

// API Implementation
private var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { ctxPtr in
    let manifest = """
      {
        "plugin_id": "osaurus.maps",
        "name": "Maps",
        "description": "Apple Maps integration plugin",
        "license": "MIT",
        "authors": ["Dinoki Labs"],
        "min_macos": "13.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "maps_search_locations",
              "description": "Search for locations on Apple Maps",
              "parameters": {
                "type": "object",
                "properties": {
                  "query": { "type": "string", "description": "Search query" },
                  "limit": { "type": "integer", "description": "Max results (default 5)" }
                },
                "required": ["query"]
              },
              "permission_policy": "ask"
            },
            {
              "id": "maps_save_location",
              "description": "Save a location to favorites in Apple Maps",
              "parameters": {
                "type": "object",
                "properties": {
                  "name": { "type": "string", "description": "Name for the location" },
                  "address": { "type": "string", "description": "Address of the location" }
                },
                "required": ["name", "address"]
              },
              "permission_policy": "ask",
              "requirements": ["maps"]
            },
            {
              "id": "maps_get_directions",
              "description": "Get directions between two locations",
              "parameters": {
                "type": "object",
                "properties": {
                  "fromAddress": { "type": "string", "description": "Starting address" },
                  "toAddress": { "type": "string", "description": "Destination address" },
                  "transportType": { "type": "string", "description": "Transport type (Driving, Walking, Transit)", "enum": ["Driving", "Walking", "Transit"] }
                },
                "required": ["fromAddress", "toAddress"]
              },
              "permission_policy": "ask"
            },
            {
              "id": "maps_drop_pin",
              "description": "Drop a pin at a specific location",
              "parameters": {
                "type": "object",
                "properties": {
                  "name": { "type": "string", "description": "Name for the pin" },
                  "address": { "type": "string", "description": "Address for the pin" }
                },
                "required": ["name", "address"]
              },
              "permission_policy": "ask",
              "requirements": ["maps"]
            },
            {
              "id": "maps_list_guides",
              "description": "List guides (opens Guides view)",
              "parameters": {
                "type": "object",
                "properties": {},
                "required": []
              },
              "permission_policy": "ask",
              "requirements": ["maps"]
            },
            {
              "id": "maps_add_to_guide",
              "description": "Add a location to a guide",
              "parameters": {
                "type": "object",
                "properties": {
                  "locationAddress": { "type": "string", "description": "Address to add" },
                  "guideName": { "type": "string", "description": "Name of the guide" }
                },
                "required": ["locationAddress", "guideName"]
              },
              "permission_policy": "ask",
              "requirements": ["maps"]
            },
            {
              "id": "maps_create_guide",
              "description": "Create a new guide",
              "parameters": {
                "type": "object",
                "properties": {
                  "guideName": { "type": "string", "description": "Name of the new guide" }
                },
                "required": ["guideName"]
              },
              "permission_policy": "ask",
              "requirements": ["maps"]
            },
            {
              "id": "maps_get_current_location",
              "description": "Get the user's current location (Location access required)",
              "parameters": {
                "type": "object",
                "properties": {},
                "required": []
              },
              "permission_policy": "ask",
              "requirements": ["location"]
            }
          ]
        }
      }
      """
    return makeCString(manifest)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    guard type == "tool" else {
      return makeCString("{\"error\": \"Unsupported capability type\"}")
    }

    guard let data = payload.data(using: .utf8) else {
      return makeCString("{\"error\": \"Invalid payload encoding\"}")
    }

    let decoder = JSONDecoder()

    do {
      switch id {
      case "maps_search_locations":
        struct Args: Decodable {
          let query: String
          let limit: Int?
        }
        let args = try decoder.decode(Args.self, from: data)
        let result = try ctx.maps.searchLocations(query: args.query, limit: args.limit ?? 5)
        return makeCString(encodeResult(result))

      case "maps_save_location":
        struct Args: Decodable {
          let name: String
          let address: String
        }
        let args = try decoder.decode(Args.self, from: data)
        let result = try ctx.maps.saveLocation(name: args.name, address: args.address)
        return makeCString(encodeResult(result))

      case "maps_get_directions":
        struct Args: Decodable {
          let fromAddress: String
          let toAddress: String
          let transportType: String?
        }
        let args = try decoder.decode(Args.self, from: data)
        let result = try ctx.maps.getDirections(
          from: args.fromAddress, to: args.toAddress, transport: args.transportType ?? "Driving")
        return makeCString(encodeResult(result))

      case "maps_drop_pin":
        struct Args: Decodable {
          let name: String
          let address: String
        }
        let args = try decoder.decode(Args.self, from: data)
        let result = try ctx.maps.dropPin(name: args.name, address: args.address)
        return makeCString(encodeResult(result))

      case "maps_list_guides":
        let result = try ctx.maps.listGuides()
        return makeCString(encodeResult(result))

      case "maps_add_to_guide":
        struct Args: Decodable {
          let locationAddress: String
          let guideName: String
        }
        let args = try decoder.decode(Args.self, from: data)
        let result = try ctx.maps.addToGuide(location: args.locationAddress, guide: args.guideName)
        return makeCString(encodeResult(result))

      case "maps_create_guide":
        struct Args: Decodable { let guideName: String }
        let args = try decoder.decode(Args.self, from: data)
        let result = try ctx.maps.createGuide(name: args.guideName)
        return makeCString(encodeResult(result))

      case "maps_get_current_location":
        if let location = ctx.maps.getCurrentLocation() {
          return makeCString(encodeResult(location))
        } else {
          return makeCString("{\"error\": \"Failed to get current location\"}")
        }

      default:
        return makeCString("{\"error\": \"Unknown tool id\"}")
      }
    } catch {
      return makeCString("{\"error\": \"\(error.localizedDescription)\"}")
    }
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
