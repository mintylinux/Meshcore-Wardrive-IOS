# MeshCore Wardrive - iOS Version

This is the iOS-compatible version of MeshCore Wardrive with USB support removed.

## Differences from Android Version

### Removed Features
- **USB Serial Connection** - iOS does not support USB serial connections to external devices
  - `usb_serial` package removed from dependencies
  - USB connection dialog option removed
  - USB connection methods removed from `LoRaCompanionService`

### iOS-Specific Changes
- Connection dialog simplified to directly scan for Bluetooth devices
- Only Bluetooth connection supported
- Version tagged as `1.0.26-iOS` to distinguish from Android version

## Building for iOS

### Prerequisites
- macOS with Xcode installed
- iOS development provisioning profile and certificates
- Flutter SDK configured for iOS development

### Build Commands
```bash
# Debug build
flutter build ios --debug

# Release build
flutter build ios --release

# Open in Xcode for advanced configuration
open ios/Runner.xcworkspace
```

## iOS-Specific Requirements

### Info.plist Permissions
Make sure the following permissions are configured in `ios/Runner/Info.plist`:

```xml
<!-- Bluetooth -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app needs Bluetooth to connect to your LoRa companion device</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app needs Bluetooth to connect to your LoRa companion device</string>

<!-- Location -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs your location to track wardrive coverage</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>This app needs your location in the background to track coverage while wardriving</string>
```

## Connecting Your LoRa Device

1. Make sure your LoRa Companion device has Bluetooth enabled
2. Tap "Connect" in the app
3. The app will automatically scan for nearby Bluetooth devices
4. Select your LoRa device from the list
5. Start tracking and wardriving!

## Known Limitations

- No USB connection option (iOS restriction)
- Background location tracking may be limited by iOS power management
- Bluetooth connection may be interrupted by iOS system events

## Version History

### v1.0.26-iOS (2026-02-12)
- Initial iOS release
- All features from Android v1.0.26 except USB connection
- Miles traveled tracking
- Screenshot capture
- Color blind accessibility modes
- 30-second ping timeout for repeater rate limiting

---

For the full-featured Android version with USB support, see the main `meshcore_wardrive_dev` folder.
