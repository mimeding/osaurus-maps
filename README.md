# osaurus-maps

An Osaurus plugin for Apple Maps integration.

## Capabilities

This plugin exposes the following tools to control the Apple Maps application on macOS.

### Native Data Tools (Background)

These tools use Apple's MapKit framework to provide high-quality data instantly without interrupting the user or opening the Maps application window.

- `maps_search_locations`: Search for locations using natural language. Returns precise coordinates and formatted addresses.
- `maps_get_directions`: Get directions between two addresses. Returns distance and expected travel time based on real-time traffic.
- `maps_get_current_location`: Get the user's current location (requires location permission).

### UI Automation Tools

These tools automate the Maps application to perform actions that third-party apps cannot do directly. These will bring the Maps app to the foreground.

- `maps_save_location`: Save a location to favorites.
- `maps_drop_pin`: Drop a pin at a specific location.
- `maps_list_guides`: Open the Guides view.
- `maps_add_to_guide`: Add a location to a specific guide.
- `maps_create_guide`: Create a new guide.

## Requirements

- macOS with Apple Maps installed.
- Permission to control the Maps application (via Automation permissions). The first time you use a tool, macOS will prompt for permission.
- Location access (for `maps_get_current_location` and `maps_search_locations`).

## Development

1. Build:
   ```bash
   swift build -c release
   cp .build/release/libosaurus-maps.dylib ./libosaurus-maps.dylib
   ```
2. Package (for distribution):
   ```bash
   osaurus tools package osaurus.maps 0.1.0
   ```
   This creates `osaurus.maps-0.1.0.zip`.
3. Install locally:
   ```bash
   osaurus tools install ./osaurus.maps-0.1.0.zip
   ```

## Publishing

To publish this plugin to the central registry:

1. Package it with the correct naming convention:
   ```bash
   osaurus tools package <plugin_id> <version>
   ```
   The zip file MUST be named `<plugin_id>-<version>.zip`.
2. Host the zip file (e.g. GitHub Releases).

3. Create a registry entry JSON file for the central repository.

## Important Notes

- Plugin metadata (id, version, capabilities) is defined in `get_manifest()` in `Plugin.swift`.
- The zip filename determines the plugin_id and version during installation.
- Ensure the version in `get_manifest()` matches your zip filename.
