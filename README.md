# MeshCore Wardrive Android App - Source Code

A Flutter-based Android application for mapping MeshCore mesh network coverage in real-time.

## 📥 Download Pre-built APK

**Latest Release:** [Download from Releases Repository](https://github.com/mintylinux/Meshcore-Wardrive-Android)

## 🚀 Features

- Real-time GPS tracking with foreground service
- USB and Bluetooth connectivity for MeshCore companion radios
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
- Android Studio or VS Code with Flutter extensions
- Android SDK with API level 21+
- A MeshCore companion radio device (for testing)

### Installation

1. Clone this repository:
```bash
git clone https://github.com/mintylinux/Meshcore-Wardrive-Android-Source.git
cd meshcore_wardrive
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

### Building Release APK

```bash
flutter build apk --release
```

The APK will be located at: `build/app/outputs/flutter-apk/app-release.apk`

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
- `usb_serial` - USB connectivity
- `flutter_blue_plus` - Bluetooth connectivity
- `sqflite` - Local database
- `geohash_plus` - Geohash encoding
- `pointycastle` - Encryption

See [pubspec.yaml](pubspec.yaml) for complete list.

## 🐛 Known Issues

- Some Android devices may require "Location Always" permission for background tracking
- USB connectivity requires OTG cable and data-capable cable
- #meshwar channel must be joined in MeshCore app before first use

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

## 📄 License

[Specify your license here]

## 🙏 Credits

Built for the MeshCore mesh networking community.

## 📧 Support

For issues and questions:
- Open an issue on GitHub
- Check existing documentation in the repository

---

**Current Version:** 1.0.7

**Minimum Android Version:** Android 5.0 (API 21)
