# MeshCore Wardrive iOS App

A Flutter-based iOS application for mapping MeshCore mesh network coverage in real-time.

⚠️ **iOS Version**: This version only supports Bluetooth connectivity (no USB support due to iOS limitations).

🤖 **Looking for Android?** The full-featured Android version with USB support is available at [Meshcore-Wardrive-Android](https://github.com/mintylinux/Meshcore-Wardrive-Android)

## 🚀 Features

- Real-time GPS tracking with foreground service
- **Bluetooth connectivity** for MeshCore companion radios (iOS compatible)
- Auto-ping functionality with configurable intervals (50m, 200m, 0.5 miles, 1 mile)
- Manual ping testing
- Success rate based coverage visualization with color coding
- Clickable coverage squares showing detailed statistics
- Repeater discovery and tracking
- Data export to JSON
- Web map upload functionality
- Debug terminal with logging
- Light/Dark theme support

## 🛠️ Development Setup

### Prerequisites

- Flutter SDK (3.10.0 or higher)
- Xcode (for iOS development)
- macOS with iOS development environment configured
- iOS device or simulator
- A MeshCore companion radio device with Bluetooth (for testing)

### Installation

1. Clone this repository:
```bash
git clone https://github.com/mintylinux/Meshcore_Wardrive_IOS.git
cd meshcore_wardrive_ios
```

2. Install dependencies:
```bash
flutter pub get
```

3. Generate app icons:
```bash
flutter pub run flutter_launcher_icons
```

4. Run on connected device:
```bash
flutter run
```

### Building for iOS

```bash
# Debug build
flutter build ios --debug

# Release build
flutter build ios --release

# Open in Xcode
open ios/Runner.xcworkspace
```

## 📁 Project Structure

```
lib/
├── main.dart                    # App entry point
├── models/
│   └── models.dart              # Data models (Sample, Coverage, Repeater)
├── screens/
│   ├── map_screen.dart          # Main map interface
│   └── debug_log_screen.dart    # Debug terminal
├── services/
│   ├── location_service.dart         # GPS tracking & auto-ping
│   ├── lora_companion_service.dart   # LoRa device communication
│   ├── database_service.dart         # SQLite database
│   ├── aggregation_service.dart      # Coverage calculation
│   ├── upload_service.dart           # Web map upload
│   ├── meshcore_protocol.dart        # Protocol implementation
│   └── debug_log_service.dart        # Debug logging
└── utils/
    └── geohash_utils.dart        # Geohash utilities
```

## 🔧 Configuration

### Ping Intervals
Default ping interval can be changed in `lib/services/location_service.dart`:
```dart
double _pingIntervalMeters = 805.0; // 0.5 miles
```

### Coverage Grid Precision
Grid size is set in `lib/utils/geohash_utils.dart`:
```dart
static String coverageKey(double lat, double lon) {
  return geohash.GeoHash.encode(lat, lon, precision: 6); // ~1.2km x 610m
}
```

### Ping Timeout
Timeout for ping responses in `lib/services/location_service.dart`:
```dart
timeoutSeconds: 20,  // 20 second timeout
```

## 📚 Documentation

- [LoRa Companion Guide](LORA_COMPANION_GUIDE.md) - Device setup and connectivity
- [MeshCore Auth Setup](MESHCORE_AUTH_SETUP.md) - Authentication configuration
- [Quick Start](QUICKSTART.md) - Getting started guide

## 🧪 Testing

Run tests with:
```bash
flutter test
```

## 📦 Dependencies

Key packages:
- `flutter_map` - Map display
- `geolocator` - GPS tracking
- `flutter_foreground_task` - Background service
- `flutter_blue_plus` - Bluetooth connectivity (iOS compatible)
- `sqflite` - Local database
- `geohash_plus` - Geohash encoding
- `pointycastle` - Encryption

See [pubspec.yaml](pubspec.yaml) for complete list.

## 🐛 Known Issues & iOS Limitations

- **No USB support** - iOS does not allow USB serial connections to external devices
- **Bluetooth only** - Only Bluetooth connection to LoRa companion devices is supported
- iOS may limit background location tracking based on system power management
- Location permission: "Always Allow" required for background tracking
- Bluetooth connection may be interrupted by iOS system events

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes with co-author line:
   ```
   git commit -m "Add amazing feature
   
   Co-Authored-By: Your Name <your.email@example.com>"
   ```
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 🙏 Credits

Built for the MeshCore mesh networking community.

## 📧 Support

For issues and questions:
- Open an issue on GitHub
- Check existing documentation in the repository

---

**Current Version:** 1.0.27-iOS

**Platform:** iOS (Bluetooth only)

**See also:** [README_iOS.md](README_iOS.md) for detailed iOS-specific information
