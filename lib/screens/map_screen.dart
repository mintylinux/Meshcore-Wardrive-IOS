import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../services/location_service.dart';
import '../services/aggregation_service.dart';
import '../services/lora_companion_service.dart';
import '../services/database_service.dart';
import '../services/upload_service.dart';
import '../services/settings_service.dart';
import '../utils/geohash_utils.dart';
import '../utils/color_blind_palette.dart';
import 'package:geohash_plus/geohash_plus.dart' as geohash;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:dio_cache_interceptor_file_store/dio_cache_interceptor_file_store.dart';
import 'package:flutter_map_heatmap/flutter_map_heatmap.dart';
import 'dart:typed_data';
import 'debug_log_screen.dart';
import 'debug_diagnostics_screen.dart';
import 'session_history_screen.dart';
import 'signal_trend_screen.dart';
import '../main.dart';
import '../constants/app_version.dart';
import '../services/ducting_service.dart';
import '../services/carpeater_service.dart';
import 'analytics_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // App version is imported from constants/app_version.dart
  
  final LocationService _locationService = LocationService();
  final MapController _mapController = MapController();
  final UploadService _uploadService = UploadService();
  final SettingsService _settingsService = SettingsService();
  final ScreenshotController _screenshotController = ScreenshotController();
  
  bool _isTracking = false;
  int _sampleCount = 0;
  List<Sample> _samples = [];
  AggregationResult? _aggregationResult;
  
  String _colorMode = 'quality';
  bool _showSamples = false;
  bool _showGpsSamples = true; // Show GPS-only samples (null pingSuccess)
  bool _showSuccessfulOnly = false; // Show only samples with successful pings
  bool _showCoverage = true; // Show coverage boxes
  bool _showEdges = true;
  bool _showRepeaters = true;
  bool _autoPingEnabled = false;
  String? _ignoredRepeaterPrefix;
  String? _includeOnlyRepeaters; // Comma-separated list of repeater prefixes to show
  bool _filterEdgesByWhitelist = false; // Whether to apply whitelist to edges
  double _pingIntervalMeters = 805.0; // Default 0.5 miles
  int _coveragePrecision = 6; // Default precision 6 (~1.2km squares)
  
  // Repeaters
  List<Repeater> _repeaters = [];
  
  LatLng? _currentPosition;
  Timer? _updateTimer;
  StreamSubscription<LatLng>? _positionSubscription;
  StreamSubscription<void>? _sampleSavedSubscription;
  StreamSubscription<String>? _pingEventSubscription;
  StreamSubscription<double>? _distanceSubscription;
  StreamSubscription<double>? _speedSubscription;
  
  // Ping visual indicator
  bool _showPingPulse = false;
  
  // Distance tracking
  double _totalDistance = 0.0;
  double _currentSpeed = 0.0;
  String _distanceUnit = 'miles';
  
  // Color blind mode
  String _colorBlindMode = 'normal';
  
  // Discovery timeout (10-30 seconds)
  int _discoveryTimeoutSeconds = 20;
  
  // Fuel unit ('imperial' for MPG/gal, 'metric' for L/100km/L)
  String _fuelUnit = 'imperial';
  
  // Screenshot mode - hide UI elements
  bool _hideUIForScreenshot = false;
  
  // LoRa connection status
  bool _loraConnected = false;
  ConnectionType _connectionType = ConnectionType.none;
  int? _batteryPercent;
  StreamSubscription<int?>? _batterySubscription;
  
  // Auto-follow GPS location
  bool _followLocation = false;
  
  // Map rotation lock
  bool _lockRotationNorth = false;
  
  // Route trail
  bool _showRouteTrail = false;
  
  // Session filter
  WSession? _activeSessionFilter;
  
  // Offline tile cache
  CacheStore? _tileCacheStore;
  
  // Heatmap
  bool _showHeatmap = false;
  final StreamController<void> _heatmapRebuildStream = StreamController.broadcast();
  
  // Coverage prediction rings
  bool _showPredictionRings = false;
  
  // Atmospheric ducting
  bool _showDucting = false;
  String _currentDuctingRisk = DuctingRisk.unknown;
  
  // Carpeater mode
  bool _carpeaterEnabled = false;
  String? _carpeaterRepeaterId;
  String? _carpeaterPassword;
  int _carpeaterInterval = 30;
  CarpeaterState _carpeaterState = CarpeaterState.disabled;
  StreamSubscription<CarpeaterState>? _carpeaterStateSubscription;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Initialize tile cache store
    final cacheDir = await getApplicationDocumentsDirectory();
    _tileCacheStore = FileCacheStore('${cacheDir.path}/tile_cache');
    
    // Initialize home screen widget
    
    // Load saved settings
    await _loadSettings();
    
    // Subscribe to battery updates
    final loraService = _locationService.loraCompanion;
    _batterySubscription = loraService.batteryStream.listen((percent) {
      setState(() {
        _batteryPercent = percent;
      });
    });
    
    // Subscribe to Carpeater state changes
    _carpeaterStateSubscription = _locationService.carpeaterService.stateStream.listen((state) {
      if (mounted) setState(() { _carpeaterState = state; });
    });
    
    // Subscribe to position updates
    _positionSubscription = _locationService.currentPositionStream.listen((position) {
      setState(() {
        _currentPosition = position;
      });
      
      // Auto-follow if enabled
      if (_followLocation && position != null) {
        _mapController.move(position, _mapController.camera.zoom);
      }
    });
    
    // Subscribe to sample saved events - reload map when new samples are saved
    _sampleSavedSubscription = _locationService.sampleSavedStream.listen((_) {
      _loadSamples();
    });
    
    // Subscribe to ping events for visual feedback
    _pingEventSubscription = _locationService.pingEventStream.listen((event) {
      if (event == 'pinging' && mounted) {
        setState(() {
          _showPingPulse = true;
        });
        // Hide pulse after 2 seconds
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _showPingPulse = false;
            });
          }
        });
      }
    });
    
    // Subscribe to distance updates
    _distanceSubscription = _locationService.totalDistanceStream.listen((distance) {
      if (mounted) {
        setState(() {
          _totalDistance = _distanceUnit == 'miles' 
              ? _locationService.totalDistanceMiles 
              : _locationService.totalDistanceKm;
        });
      }
    });
    
    // Subscribe to speed updates
    _speedSubscription = _locationService.speedStream.listen((speed) {
      if (mounted) {
        setState(() {
          _currentSpeed = _distanceUnit == 'miles'
              ? _locationService.currentSpeedMph
              : _locationService.currentSpeedKmh;
        });
      }
    });
    
    await _loadSamples();
    await _getCurrentLocation();
    
    // Update periodically
    _updateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadSamples();
    });
  }
  
  Future<void> _loadSettings() async {
    final showSamples = await _settingsService.getShowSamples();
    final showGpsSamples = await _settingsService.getShowGpsSamples();
    final showCoverage = await _settingsService.getShowCoverage();
    final showEdges = await _settingsService.getShowEdges();
    final showRepeaters = await _settingsService.getShowRepeaters();
    final colorMode = await _settingsService.getColorMode();
    final pingInterval = await _settingsService.getPingInterval();
    final coveragePrecision = await _settingsService.getCoveragePrecision();
    final ignoredPrefix = await _settingsService.getIgnoredRepeaterPrefix();
    final includeOnly = await _settingsService.getIncludeOnlyRepeaters();
    final filterEdges = await _settingsService.getFilterEdgesByWhitelist();
    final distanceUnit = await _settingsService.getDistanceUnit();
    final colorBlindMode = await _settingsService.getColorBlindMode();
    final discoveryTimeout = await _settingsService.getDiscoveryTimeout();
    final fuelUnit = await _settingsService.getFuelUnit();
    final showRouteTrail = await _settingsService.getShowRouteTrail();
    final showHeatmap = await _settingsService.getShowHeatmap();
    final showPredictionRings = await _settingsService.getShowPredictionRings();
    final showDucting = await _settingsService.getShowDucting();
    
    setState(() {
      _showSamples = showSamples;
      _showGpsSamples = showGpsSamples;
      _showCoverage = showCoverage;
      _showEdges = showEdges;
      _showRepeaters = showRepeaters;
      _colorMode = colorMode;
      _pingIntervalMeters = pingInterval;
      _coveragePrecision = coveragePrecision;
      _ignoredRepeaterPrefix = ignoredPrefix;
      _includeOnlyRepeaters = includeOnly;
      _filterEdgesByWhitelist = filterEdges;
      _distanceUnit = distanceUnit;
      _colorBlindMode = colorBlindMode;
      _discoveryTimeoutSeconds = discoveryTimeout;
      _fuelUnit = fuelUnit;
      _showRouteTrail = showRouteTrail;
      _showHeatmap = showHeatmap;
      _showPredictionRings = showPredictionRings;
      _showDucting = showDucting;
    });
    
    // Load Carpeater settings
    final carpeaterEnabled = await _settingsService.getCarpeaterEnabled();
    final carpeaterRepeaterId = await _settingsService.getCarpeaterRepeaterId();
    final carpeaterPassword = await _settingsService.getCarpeaterPassword();
    final carpeaterInterval = await _settingsService.getCarpeaterInterval();
    setState(() {
      _carpeaterEnabled = carpeaterEnabled;
      _carpeaterRepeaterId = carpeaterRepeaterId;
      _carpeaterPassword = carpeaterPassword;
      _carpeaterInterval = carpeaterInterval;
    });
    _locationService.setCarpeaterMode(carpeaterEnabled);
    
    // Apply to services
    _locationService.setPingInterval(pingInterval);
    _locationService.loraCompanion.setIgnoredRepeaterPrefix(ignoredPrefix);
  }

  Future<void> _getCurrentLocation() async {
    final pos = await _locationService.getCurrentPosition();
    if (pos != null) {
      setState(() {
        _currentPosition = pos;
      });
      // Move map to user's current location on startup
      _mapController.move(pos, 13.0);
    }
  }

  Future<void> _loadSamples() async {
    var samples = await _locationService.getAllSamples();
    final count = await _locationService.getSampleCount();
    
    // Apply session time filter if active
    if (_activeSessionFilter != null) {
      final start = _activeSessionFilter!.startTime;
      final end = _activeSessionFilter!.endTime ?? DateTime.now();
      samples = samples.where((s) =>
          s.timestamp.isAfter(start.subtract(const Duration(seconds: 1))) &&
          s.timestamp.isBefore(end.add(const Duration(seconds: 1)))
      ).toList();
    }
    
    // Update connection status
    final loraService = _locationService.loraCompanion;
    
    // Sync discovered repeaters from LoRa service
    final discoveredRepeaters = loraService.discoveredRepeaters;
    
    // Aggregate data with user's chosen coverage precision and repeaters
    final result = AggregationService.buildIndexes(
      samples, 
      discoveredRepeaters,
      coveragePrecision: _coveragePrecision,
    );
    
    // Combine repeaters from both LoRa service (live) and aggregation result (historical)
    // Use a map to deduplicate by ID, preferring live data when available
    final Map<String, Repeater> repeaterMap = {};
    
    // First add historical repeaters from samples
    for (final repeater in result.repeaters) {
      repeaterMap[repeater.id] = repeater;
    }
    
    // Then overlay with live discovered repeaters (these have fresher data)
    for (final repeater in discoveredRepeaters) {
      repeaterMap[repeater.id] = repeater;
    }
    
    final combinedRepeaters = repeaterMap.values.toList();
    
    final isConnected = loraService.isDeviceConnected;
    final connType = loraService.connectionType;
    
    setState(() {
      _samples = samples;
      _sampleCount = count;
      _aggregationResult = result;
      _loraConnected = isConnected;
      _connectionType = connType;
      _autoPingEnabled = _locationService.isAutoPingEnabled;
      _repeaters = combinedRepeaters;
    });
    
    // Update ducting badge if enabled
    if (_showDucting) {
      final risk = await _locationService.ductingService.getLatestRisk();
      if (mounted && risk != _currentDuctingRisk) {
        setState(() { _currentDuctingRisk = risk; });
      }
    }
    
    // Update home screen widget
    final connLabel = isConnected
        ? (connType == ConnectionType.usb ? 'USB' : 'BT')
        : '---';
    final pingSamples = samples.where((s) => s.pingSuccess != null).toList();
    final successCount = pingSamples.where((s) => s.pingSuccess == true).length;
    final rate = pingSamples.isNotEmpty
        ? '${(successCount / pingSamples.length * 100).toStringAsFixed(0)}%'
        : '--';
    final dist = _isTracking
        ? '${_totalDistance.toStringAsFixed(1)} ${_distanceUnit == "miles" ? "mi" : "km"}'
        : '--';
      sampleCount: count,
      isTracking: _isTracking,
      connectionLabel: connLabel,
      successRate: rate,
      distance: dist,
    );
  }

  Future<void> _toggleTracking() async {
    if (_isTracking) {
      // Persist session distance before stopping
      final sessionMeters = _locationService.totalDistanceMeters;
      if (sessionMeters > 0) {
        await _settingsService.addToTotalDistanceDriven(sessionMeters);
      }
      // Stop tracking and auto-ping
      await _locationService.stopTracking();
      _locationService.disableAutoPing();
      setState(() {
        _isTracking = false;
        _autoPingEnabled = false;
      });
    } else {
      // Start tracking
      final started = await _locationService.startTracking();
      if (started) {
        // Auto-enable ping or Carpeater if LoRa is connected
        if (_loraConnected && _carpeaterEnabled) {
          _locationService.setCarpeaterMode(true);
          final carpeaterStarted = await _locationService.startCarpeater();
          setState(() {
            _isTracking = true;
            _autoPingEnabled = false;
          });
          _showSnackBar(carpeaterStarted
              ? 'Carpeater mode started'
              : 'Carpeater failed — check settings');
        } else if (_loraConnected) {
          _locationService.enableAutoPing();
          setState(() {
            _isTracking = true;
            _autoPingEnabled = true;
          });
          _showSnackBar('Location tracking and auto-ping started');
        } else {
          setState(() {
            _isTracking = true;
          });
          _showSnackBar('Location tracking started');
        }
      } else {
        _showSnackBar('Failed to start tracking. Check permissions.');
      }
    }
  }

  Future<void> _clearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Map History?'),
        content: Text(
          'This will permanently delete all $_sampleCount samples and coverage data from the map.\n\nThis action cannot be undone.',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _locationService.clearAllSamples();
      await _loadSamples();
      _showSnackBar('Deleted $_sampleCount samples');
    }
  }

  Future<void> _exportData() async {
    // Ask user for export format
    final format = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export Format'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('JSON'),
              subtitle: const Text('Full data with all fields'),
              onTap: () => Navigator.pop(context, 'json'),
            ),
            ListTile(
              leading: const Icon(Icons.table_chart),
              title: const Text('CSV'),
              subtitle: const Text('Spreadsheet-compatible'),
              onTap: () => Navigator.pop(context, 'csv'),
            ),
            ListTile(
              leading: const Icon(Icons.route),
              title: const Text('GPX'),
              subtitle: const Text('GPS track for mapping apps'),
              onTap: () => Navigator.pop(context, 'gpx'),
            ),
            ListTile(
              leading: const Icon(Icons.map),
              title: const Text('KML'),
              subtitle: const Text('Google Earth format'),
              onTap: () => Navigator.pop(context, 'kml'),
            ),
          ],
        ),
      ),
    );
    
    if (format == null) return;
    
    // Ask save or share
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Export as ${format.toUpperCase()}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save to Folder'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'share'),
            child: const Text('Share'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    
    if (choice == null) return;
    
    try {
      final samples = await _locationService.getAllSamples();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      String content;
      String fileName;
      String extension;
      
      switch (format) {
        case 'csv':
          content = _buildCsvExport(samples);
          extension = 'csv';
          fileName = 'meshcore_export_$timestamp.csv';
          break;
        case 'gpx':
          content = _buildGpxExport(samples);
          extension = 'gpx';
          fileName = 'meshcore_export_$timestamp.gpx';
          break;
        case 'kml':
          content = _buildKmlExport(samples);
          extension = 'kml';
          fileName = 'meshcore_export_$timestamp.kml';
          break;
        default:
          final data = await _locationService.exportSamples();
          content = jsonEncode(data);
          extension = 'json';
          fileName = 'meshcore_export_$timestamp.json';
      }
      
      if (choice == 'save') {
        await FilePicker.platform.saveFile(
          dialogTitle: 'Save Export',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: [extension],
          bytes: utf8.encode(content),
        );
        _showSnackBar('Exported ${samples.length} samples as ${format.toUpperCase()}');
      } else if (choice == 'share') {
        final directory = await getExternalStorageDirectory();
        final file = File('${directory!.path}/$fileName');
        await file.writeAsString(content);
        
        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'MeshCore Wardrive Export',
          text: 'Exported ${samples.length} samples from MeshCore Wardrive',
        );
        _showSnackBar('Export shared');
      }
    } catch (e) {
      _showSnackBar('Export failed: $e');
    }
  }
  
  String _buildCsvExport(List<Sample> samples) {
    final buffer = StringBuffer();
    buffer.writeln('id,lat,lon,timestamp,geohash,rssi,snr,pingSuccess,path');
    for (final s in samples) {
      buffer.writeln(
        '${s.id},${s.position.latitude},${s.position.longitude},'
        '${s.timestamp.toIso8601String()},${s.geohash},'
        '${s.rssi ?? ''},${s.snr ?? ''},'
        '${s.pingSuccess ?? ''},${s.path ?? ''}'
      );
    }
    return buffer.toString();
  }
  
  String _buildGpxExport(List<Sample> samples) {
    final sorted = List<Sample>.from(samples)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<gpx version="1.1" creator="MeshCore Wardrive"');
    buffer.writeln('  xmlns="http://www.topografix.com/GPX/1/1">');
    buffer.writeln('  <trk>');
    buffer.writeln('    <name>MeshCore Wardrive ${DateFormat('yyyy-MM-dd').format(DateTime.now())}</name>');
    buffer.writeln('    <trkseg>');
    for (final s in sorted) {
      buffer.writeln('      <trkpt lat="${s.position.latitude}" lon="${s.position.longitude}">');
      buffer.writeln('        <time>${s.timestamp.toUtc().toIso8601String()}</time>');
      if (s.rssi != null) buffer.writeln('        <desc>RSSI: ${s.rssi} dBm, SNR: ${s.snr} dB</desc>');
      buffer.writeln('      </trkpt>');
    }
    buffer.writeln('    </trkseg>');
    buffer.writeln('  </trk>');
    buffer.writeln('</gpx>');
    return buffer.toString();
  }
  
  String _buildKmlExport(List<Sample> samples) {
    final sorted = List<Sample>.from(samples)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    final coords = sorted.map((s) => 
      '${s.position.longitude},${s.position.latitude},0'
    ).join('\n            ');
    
    // Build placemarks for ping results
    final placemarks = StringBuffer();
    for (final s in sorted.where((s) => s.pingSuccess != null)) {
      final icon = s.pingSuccess == true ? '#successStyle' : '#failStyle';
      placemarks.writeln('    <Placemark>');
      placemarks.writeln('      <styleUrl>$icon</styleUrl>');
      placemarks.writeln('      <description>${s.pingSuccess == true ? 'Success' : 'Failed'}${s.rssi != null ? ' RSSI:${s.rssi}' : ''}</description>');
      placemarks.writeln('      <Point><coordinates>${s.position.longitude},${s.position.latitude},0</coordinates></Point>');
      placemarks.writeln('    </Placemark>');
    }
    
    return '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>MeshCore Wardrive ${DateFormat('yyyy-MM-dd').format(DateTime.now())}</name>
    <Style id="successStyle"><IconStyle><color>ff00ff00</color></IconStyle></Style>
    <Style id="failStyle"><IconStyle><color>ff0000ff</color></IconStyle></Style>
    <Placemark>
      <name>Route Trail</name>
      <LineString>
        <coordinates>
            $coords
        </coordinates>
      </LineString>
    </Placemark>
$placemarks  </Document>
</kml>''';
  }

  Future<void> _importData() async {
    try {
      // Pick a JSON file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      
      if (result == null || result.files.single.path == null) {
        return; // User cancelled
      }
      
      final file = File(result.files.single.path!);
      final jsonString = await file.readAsString();
      final List<dynamic> jsonData = jsonDecode(jsonString);
      
      // Import samples
      final importedCount = await _locationService.importSamples(
        jsonData.cast<Map<String, dynamic>>(),
      );
      
      // Reload map
      await _loadSamples();
      
      _showSnackBar('Imported $importedCount new samples');
    } catch (e) {
      _showSnackBar('Import failed: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
  
  Future<void> _checkForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/mintylinux/Meshcore-Wardrive-Android/releases/latest'),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tagName = data['tag_name'].toString();
        // Extract version from tag like "Meshcore-Wardrive-Android-1.0.2"
        final latestVersion = tagName.split('-').last;
        
        if (latestVersion != appVersion) {
          if (!mounted) return;
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Update Available'),
              content: Text(
                'New version $latestVersion is available!\n\n'
                'Current version: $appVersion\n\n'
                'Would you like to download it?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Later'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _openGitHub();
                  },
                  child: const Text('Download'),
                ),
              ],
            ),
          );
        } else {
          _showSnackBar('You\'re on the latest version!');
        }
      } else {
        _showSnackBar('Could not check for updates');
      }
    } catch (e) {
      _showSnackBar('Error checking for updates: $e');
    }
  }
  
  Future<void> _openGitHub() async {
    final url = Uri.parse('https://github.com/mintylinux/Meshcore-Wardrive-Android/releases');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      _showSnackBar('Could not open GitHub');
    }
  }
  

  void _toggleFollowLocation() {
    setState(() {
      _followLocation = !_followLocation;
    });
    
    if (_followLocation) {
      // Center on current location when enabling follow
      if (_currentPosition != null) {
        _mapController.move(_currentPosition!, _mapController.camera.zoom);
      }
      _showSnackBar('Auto-follow enabled');
    } else {
      _showSnackBar('Auto-follow disabled');
    }
  }
  
  void _resetMapRotation() {
    _mapController.rotate(0); // 0 degrees = north up
    _showSnackBar('Map reset to north');
  }
  
  Future<void> _captureScreenshot() async {
    try {
      // Hide UI elements
      setState(() {
        _hideUIForScreenshot = true;
      });
      
      // Wait for UI to update
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Capture screenshot
      final Uint8List? imageBytes = await _screenshotController.capture(
        pixelRatio: 2.0, // Higher quality
      );
      
      // Restore UI
      setState(() {
        _hideUIForScreenshot = false;
      });
      
      if (imageBytes == null) {
        _showSnackBar('Failed to capture screenshot');
        return;
      }
      
      // Save to gallery
      final String fileName = 'meshcore_wardrive_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = await SaverGallery.saveImage(
        imageBytes,
        quality: 100,
        fileName: fileName,
        androidRelativePath: "Pictures/MeshCore",
        skipIfExists: false,
      );
      
      if (result.isSuccess) {
        _showSnackBar('Screenshot saved to gallery!');
        
        // Ask if user wants to share
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Screenshot Saved'),
            content: const Text('Would you like to share the screenshot?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  // Save temp file and share
                  final tempDir = await getTemporaryDirectory();
                  final file = File('${tempDir.path}/meshcore_screenshot.png');
                  await file.writeAsBytes(imageBytes);
                  await Share.shareXFiles(
                    [XFile(file.path)],
                    text: 'MeshCore Wardrive Coverage Map',
                  );
                },
                child: const Text('Yes'),
              ),
            ],
          ),
        );
      } else {
        _showSnackBar('Failed to save screenshot');
      }
    } catch (e) {
      // Restore UI on error
      setState(() {
        _hideUIForScreenshot = false;
      });
      _showSnackBar('Error capturing screenshot: $e');
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _batterySubscription?.cancel();
    _positionSubscription?.cancel();
    _sampleSavedSubscription?.cancel();
    _pingEventSubscription?.cancel();
    _distanceSubscription?.cancel();
    _speedSubscription?.cancel();
    _heatmapRebuildStream.close();
    _locationService.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshCore Wardrive'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const DebugLogScreen()),
              );
            },
            tooltip: 'Debug Terminal',
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt),
            onPressed: _captureScreenshot,
            tooltip: 'Screenshot',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
          ),
        ],
      ),
      body: Screenshot(
        controller: _screenshotController,
        child: Stack(
          children: [
            _buildMap(),
            if (!_hideUIForScreenshot) _buildControlPanel(),
          ],
        ),
      ),
      floatingActionButton: _hideUIForScreenshot ? null : Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'compass',
            mini: true,
            onPressed: _resetMapRotation,
            child: const Icon(Icons.navigation),
            tooltip: 'Reset to North',
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'location',
            mini: true,
            onPressed: _toggleFollowLocation,
            backgroundColor: _followLocation ? Colors.blue : null,
            child: Icon(
              _followLocation ? Icons.gps_fixed : Icons.gps_not_fixed,
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'tracking',
            onPressed: _toggleTracking,
            backgroundColor: _isTracking ? Colors.red : Colors.green,
            child: Icon(_isTracking ? Icons.stop : Icons.play_arrow),
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentPosition ?? GeohashUtils.centerPos,
        initialZoom: 13.0,
        minZoom: 3.0,
        maxZoom: 18.0,
        interactionOptions: InteractionOptions(
          flags: _lockRotationNorth 
              ? InteractiveFlag.all & ~InteractiveFlag.rotate  // Disable rotation
              : InteractiveFlag.all,  // Allow all interactions
        ),
        onMapEvent: (event) {
          // Disable follow mode if user manually pans/drags the map
          if (event is MapEventMoveStart && event.source == MapEventSource.mapController) {
            // Ignore programmatic moves (from auto-follow)
            return;
          }
          if (event is MapEventMoveStart && _followLocation) {
            setState(() {
              _followLocation = false;
            });
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: isDarkMode
              ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
              : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: isDarkMode ? const ['a', 'b', 'c', 'd'] : const [],
          userAgentPackageName: 'com.meshcore.wardrive',
          tileProvider: _tileCacheStore != null
              ? CachedTileProvider(
                  store: _tileCacheStore!,
                )
              : null,
        ),
        if (_showRouteTrail) _buildRouteTrailLayer(),
        if (_showHeatmap) _buildHeatmapLayer(),
        if (_showCoverage) ..._buildCoverageLayers(),
        if (_showSamples) _buildSampleLayer(),
        if (_showEdges) _buildEdgeLayer(),
        if (_showRepeaters) _buildRepeaterLayer(),
        if (_showPredictionRings) _buildPredictionRingsLayer(),
        if (_currentPosition != null && !_hideUIForScreenshot) _buildCurrentLocationLayer(),
      ],
    );
  }

  Widget _buildRouteTrailLayer() {
    if (_samples.isEmpty) return const SizedBox.shrink();
    
    // Sort samples by timestamp (oldest first)
    final sorted = List<Sample>.from(_samples)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    final polylines = <Polyline>[];
    const maxGapMinutes = 5; // Break trail if gap > 5 minutes
    
    var segmentPoints = <LatLng>[];
    Color segmentColor = Colors.blue;
    
    for (int i = 0; i < sorted.length; i++) {
      final sample = sorted[i];
      
      // Determine color for this point
      Color pointColor;
      if (sample.pingSuccess == true) {
        pointColor = ColorBlindPalette.getSuccessColor(_colorBlindMode);
      } else if (sample.pingSuccess == false) {
        pointColor = ColorBlindPalette.getFailureColor(_colorBlindMode);
      } else {
        pointColor = Colors.blue;
      }
      
      if (i > 0) {
        final gap = sample.timestamp.difference(sorted[i - 1].timestamp).inMinutes;
        
        if (gap > maxGapMinutes) {
          // Save current segment and start new one
          if (segmentPoints.length >= 2) {
            polylines.add(Polyline(
              points: List.from(segmentPoints),
              color: segmentColor.withValues(alpha: 0.7),
              strokeWidth: 3.0,
            ));
          }
          segmentPoints = [sample.position];
          segmentColor = pointColor;
          continue;
        }
        
        // If color changes, end current segment and start new one
        if (pointColor != segmentColor && segmentPoints.length >= 2) {
          polylines.add(Polyline(
            points: List.from(segmentPoints),
            color: segmentColor.withValues(alpha: 0.7),
            strokeWidth: 3.0,
          ));
          // Start new segment from last point of previous segment for continuity
          segmentPoints = [segmentPoints.last, sample.position];
          segmentColor = pointColor;
          continue;
        }
      } else {
        segmentColor = pointColor;
      }
      
      segmentPoints.add(sample.position);
    }
    
    // Add final segment
    if (segmentPoints.length >= 2) {
      polylines.add(Polyline(
        points: segmentPoints,
        color: segmentColor.withValues(alpha: 0.7),
        strokeWidth: 3.0,
      ));
    }
    
    return PolylineLayer(polylines: polylines);
  }

  Widget _buildHeatmapLayer() {
    if (_samples.isEmpty) return const SizedBox.shrink();
    
    // Convert samples to weighted points
    // Higher weight = hotter on the heatmap
    final data = _samples.map((sample) {
      double weight;
      if (sample.pingSuccess == true) {
        weight = 1.0; // Successful ping = hot
      } else if (sample.pingSuccess == false) {
        weight = 0.5; // Failed ping = warm
      } else {
        weight = 0.2; // GPS-only = cool
      }
      return WeightedLatLng(sample.position, weight);
    }).toList();
    
    return HeatMapLayer(
      heatMapDataSource: InMemoryHeatMapDataSource(data: data),
      heatMapOptions: HeatMapOptions(
        gradient: {
          0.25: Colors.green,
          0.50: Colors.yellow,
          0.75: Colors.orange,
          1.0: Colors.red,
        },
        minOpacity: 0.1,
      ),
      reset: _heatmapRebuildStream.stream,
    );
  }

  List<Widget> _buildCoverageLayers() {
    if (_aggregationResult == null) return [];
    
    final coveragePolygons = <Polygon>[];
    final coverageMarkers = <Marker>[];
    
    for (final coverage in _aggregationResult!.coverages) {
      final gh = geohash.GeoHash.decode(coverage.id);
      final color = Color(AggregationService.getCoverageColor(coverage, _colorMode, colorBlindMode: _colorBlindMode));
      final opacity = AggregationService.getCoverageOpacity(coverage);
      
      // Get corners from geohash bounds
      final sw = gh.bounds.southWest;
      final ne = gh.bounds.northEast;
      
      coveragePolygons.add(
        Polygon(
          points: [
            LatLng(sw.latitude, sw.longitude),
            LatLng(sw.latitude, ne.longitude),
            LatLng(ne.latitude, ne.longitude),
            LatLng(ne.latitude, sw.longitude),
          ],
          color: color.withValues(alpha: opacity),
          borderColor: color,
          borderStrokeWidth: 1,
          isFilled: true,
        ),
      );
      
      // Add invisible tap target at center of coverage square
      coverageMarkers.add(
        Marker(
          point: coverage.position,
          width: 100,
          height: 100,
          child: GestureDetector(
            onTap: () => _showCoverageInfo(coverage),
            child: Container(color: Colors.transparent),
          ),
        ),
      );
    }
    
    return [
      PolygonLayer(polygons: coveragePolygons),
      MarkerLayer(markers: coverageMarkers),
    ];
  }

  Widget _buildSampleLayer() {
    if (_samples.isEmpty) return const SizedBox.shrink();
    
    // Filter samples based on settings
    final filteredSamples = _samples.where((sample) {
      // If showing GPS samples is disabled, hide samples with null pingSuccess
      if (!_showGpsSamples && sample.pingSuccess == null) {
        return false;
      }
      
      // If showing successful only, hide failed pings and GPS-only samples
      if (_showSuccessfulOnly && sample.pingSuccess != true) {
        return false;
      }
      
      // If include-only repeaters is set, only show samples from those repeaters
      if (_includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty) {
        final allowedPrefixes = _includeOnlyRepeaters!.split(',').map((s) => s.trim().toUpperCase()).toList();
        final sampleNodeId = sample.path?.toUpperCase() ?? '';
        
        // Check if sample's repeater matches any allowed prefix
        final matches = allowedPrefixes.any((prefix) => sampleNodeId.startsWith(prefix));
        if (!matches) {
          return false;
        }
      }
      
      return true;
    }).toList();
    
    // Sort by timestamp (oldest first) so newer samples render on top
    filteredSamples.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    final markers = filteredSamples.map((sample) {
      // Determine color based on ping result and color blind mode
      Color markerColor;
      if (sample.pingSuccess == true) {
        markerColor = ColorBlindPalette.getSuccessColor(_colorBlindMode);
      } else if (sample.pingSuccess == false) {
        markerColor = ColorBlindPalette.getFailureColor(_colorBlindMode);
      } else {
        markerColor = ColorBlindPalette.getGpsOnlyColor(_colorBlindMode);
      }
      
      return Marker(
        point: sample.position,
        width: 12,
        height: 12,
        child: GestureDetector(
          onTap: () => _showSampleInfo(sample),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: markerColor.withValues(alpha: 0.7),
              shape: BoxShape.circle,
              border: Border.all(
                color: markerColor.withValues(alpha: 0.9),
                width: 1,
              ),
            ),
          ),
        ),
      );
    }).toList();
    
    return MarkerLayer(markers: markers);
  }

  Widget _buildEdgeLayer() {
    if (_aggregationResult == null) return const SizedBox.shrink();
    
    // Filter edges by whitelist if enabled
    var edges = _aggregationResult!.edges;
    
    if (_filterEdgesByWhitelist && _includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty) {
      final allowedPrefixes = _includeOnlyRepeaters!.split(',').map((s) => s.trim().toUpperCase()).toList();
      edges = edges.where((edge) {
        final repeaterId = edge.repeater.id.toUpperCase();
        return allowedPrefixes.any((prefix) => repeaterId.startsWith(prefix));
      }).toList();
    }
    
    final polylines = edges.map((edge) {
      return Polyline(
        points: [edge.coverage.position, edge.repeater.position],
        color: Colors.purple.withValues(alpha: 0.6),  // Increased from 0.3 to 0.6
        strokeWidth: 2,  // Increased from 1 to 2
      );
    }).toList();
    
    return PolylineLayer(polylines: polylines);
  }

  Widget _buildRepeaterLayer() {
    if (_repeaters.isEmpty) return const SizedBox.shrink();
    
    final markers = _repeaters.map((repeater) {
      return Marker(
        point: repeater.position,
        width: 30,
        height: 30,
        child: GestureDetector(
          onTap: () => _showRepeaterInfo(repeater),
          child: Icon(
            Icons.cell_tower,
            color: ColorBlindPalette.getRepeaterColor(_colorBlindMode),
            size: 30,
          ),
        ),
      );
    }).toList();
    
    return MarkerLayer(markers: markers);
  }

  /// Generate polygon points approximating a circle at a given radius
  List<LatLng> _circlePoints(LatLng center, double radiusMeters, {int segments = 72}) {
    const distance = Distance();
    return List.generate(segments, (i) {
      final bearing = (360.0 / segments) * i;
      return distance.offset(center, radiusMeters, bearing);
    });
  }

  Widget _buildPredictionRingsLayer() {
    if (_repeaters.isEmpty || _samples.isEmpty) return const SizedBox.shrink();

    // Build lookup: repeater ID -> list of distances (meters) from successful samples
    final Map<String, List<double>> repeaterDistances = {};
    final Map<String, Repeater> repeaterById = {};
    const distance = Distance();
    final allowedPrefixes = _includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty
        ? _includeOnlyRepeaters!.split(',').map((s) => s.trim().toUpperCase()).toList()
        : null;

    for (final repeater in _repeaters) {
      // Skip repeaters at 0,0 (unknown position)
      if (repeater.position.latitude == 0.0 && repeater.position.longitude == 0.0) continue;
      if (allowedPrefixes != null) {
        final repeaterId = repeater.id.toUpperCase();
        final matches = allowedPrefixes.any((prefix) => repeaterId.startsWith(prefix));
        if (!matches) continue;
      }
      repeaterById[repeater.id] = repeater;
    }

    // Match samples to repeaters by path (nodeId)
    for (final sample in _samples) {
      if (sample.pingSuccess != true || sample.path == null || sample.path!.isEmpty) continue;
      final repeater = repeaterById[sample.path!];
      if (repeater == null) continue;

      final dist = distance.as(LengthUnit.Meter, sample.position, repeater.position);
      // Skip impossibly large distances (GPS noise)
      if (dist > 100000) continue; // 100km sanity cap

      repeaterDistances.putIfAbsent(repeater.id, () => []);
      repeaterDistances[repeater.id]!.add(dist);
    }

    final polygons = <Polygon>[];

    for (final entry in repeaterDistances.entries) {
      final repeater = repeaterById[entry.key]!;
      final distances = entry.value..sort();

      // Need at least 3 data points for meaningful prediction
      if (distances.length < 3) continue;

      // Percentile-based rings
      final p25 = distances[(distances.length * 0.25).floor()];
      final p75 = distances[(distances.length * 0.75).floor()];
      final maxDist = distances.last;

      // Skip if rings would be too small to see (<50m)
      if (maxDist < 50) continue;

      // Edge ring (outer, red) — max observed distance
      polygons.add(Polygon(
        points: _circlePoints(repeater.position, maxDist),
        color: Colors.red.withValues(alpha: 0.05),
        borderColor: Colors.red.withValues(alpha: 0.35),
        borderStrokeWidth: 1.5,
        isFilled: true,
      ));

      // Moderate ring (middle, yellow)
      if (p75 > 50 && p75 < maxDist * 0.95) {
        polygons.add(Polygon(
          points: _circlePoints(repeater.position, p75),
          color: Colors.yellow.withValues(alpha: 0.08),
          borderColor: Colors.yellow.withValues(alpha: 0.5),
          borderStrokeWidth: 1.5,
          isFilled: true,
        ));
      }

      // Strong ring (inner, green)
      if (p25 > 50 && p25 < p75 * 0.95) {
        polygons.add(Polygon(
          points: _circlePoints(repeater.position, p25),
          color: Colors.green.withValues(alpha: 0.10),
          borderColor: Colors.green.withValues(alpha: 0.6),
          borderStrokeWidth: 1.5,
          isFilled: true,
        ));
      }
    }

    if (polygons.isEmpty) return const SizedBox.shrink();
    return PolygonLayer(polygons: polygons);
  }

  Widget _buildCurrentLocationLayer() {
    final markers = [
      // Main location dot
      Marker(
        point: _currentPosition!,
        width: 20,
        height: 20,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    ];
    
    // Add ping pulse animation when auto-pinging
    if (_showPingPulse) {
      markers.add(
        Marker(
          point: _currentPosition!,
          width: 60,
          height: 60,
          child: TweenAnimationBuilder(
            tween: Tween<double>(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 1500),
            builder: (context, double value, child) {
              return Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 1.0 - value),
                    width: 3,
                  ),
                ),
              );
            },
          ),
        ),
      );
    }
    
    return MarkerLayer(markers: markers);
  }

  Widget _buildControlPanel() {
    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              // Connection Status Icon
              Icon(
                _loraConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                size: 16,
                color: _loraConnected ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 4),
              Text(
                _loraConnected 
                    ? (_connectionType == ConnectionType.usb ? 'USB' : 'BT')
                    : 'No LoRa',
                style: TextStyle(
                  fontSize: 12,
                  color: _loraConnected ? Colors.green : Colors.grey,
                ),
              ),
              if (_loraConnected && _batteryPercent != null)
                const SizedBox(width: 4),
              if (_loraConnected && _batteryPercent != null)
                Icon(
                  _getBatteryIcon(_batteryPercent!),
                  size: 14,
                  color: _getBatteryColor(_batteryPercent!),
                ),
              if (_loraConnected && _batteryPercent != null)
                const SizedBox(width: 2),
              if (_loraConnected && _batteryPercent != null)
                Text(
                  '$_batteryPercent%',
                  style: TextStyle(
                    fontSize: 11,
                    color: _getBatteryColor(_batteryPercent!),
                  ),
                ),
              const SizedBox(width: 12),
              const Text('•', style: TextStyle(color: Colors.grey)),
              const SizedBox(width: 12),
              // Stats
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Samples: $_sampleCount',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    if (_isTracking)
                      Text(
                        '${_totalDistance.toStringAsFixed(2)} ${_distanceUnit == 'miles' ? 'mi' : 'km'} • ${_currentSpeed.toStringAsFixed(1)} ${_distanceUnit == 'miles' ? 'mph' : 'km/h'}',
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    if (_carpeaterEnabled && _carpeaterState != CarpeaterState.disabled)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: GestureDetector(
                          onTap: _carpeaterState == CarpeaterState.error
                              ? () async {
                                  _showSnackBar('Retrying Carpeater...');
                                  final ok = await _locationService.startCarpeater();
                                  _showSnackBar(ok ? 'Carpeater reconnected' : 'Carpeater retry failed');
                                }
                              : null,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: (_carpeaterState == CarpeaterState.error
                                  ? Colors.red
                                  : _carpeaterState == CarpeaterState.loggedIn ||
                                    _carpeaterState == CarpeaterState.discovering ||
                                    _carpeaterState == CarpeaterState.fetchingNeighbours
                                      ? Colors.green
                                      : Colors.orange).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _carpeaterState == CarpeaterState.error
                                    ? Colors.red
                                    : _carpeaterState == CarpeaterState.loggedIn ||
                                      _carpeaterState == CarpeaterState.discovering ||
                                      _carpeaterState == CarpeaterState.fetchingNeighbours
                                        ? Colors.green
                                        : Colors.orange,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'CP: ${_carpeaterStateLabel()}',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: _carpeaterState == CarpeaterState.error
                                        ? Colors.red
                                        : _carpeaterState == CarpeaterState.loggedIn ||
                                          _carpeaterState == CarpeaterState.discovering ||
                                          _carpeaterState == CarpeaterState.fetchingNeighbours
                                            ? Colors.green
                                            : Colors.orange,
                                  ),
                                ),
                                if (_carpeaterState == CarpeaterState.error) ...[
                                  const SizedBox(width: 4),
                                  Icon(Icons.refresh, size: 10, color: Colors.red),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_showDucting && _currentDuctingRisk != DuctingRisk.unknown)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: _getDuctingColor(_currentDuctingRisk).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: _getDuctingColor(_currentDuctingRisk), width: 1),
                          ),
                          child: Text(
                            'Ducting: ${DuctingService.riskLabel(_currentDuctingRisk)}',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: _getDuctingColor(_currentDuctingRisk),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Spacer(),
              // Connect button or Manual Ping
              if (!_loraConnected)
                TextButton(
                  onPressed: _showConnectionDialog,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('Connect', style: TextStyle(fontSize: 12)),
                ),
              if (_loraConnected) ...[  
                IconButton(
                  icon: const Icon(Icons.link_off, size: 16),
                  onPressed: _disconnectLoRa,
                  tooltip: 'Disconnect',
                  color: Colors.red,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _manualPing,
                  tooltip: 'Manual Ping',
                  color: Colors.blue,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _toggleAutoPing(bool? value) {
    if (value == true) {
      _locationService.enableAutoPing();
    } else {
      _locationService.disableAutoPing();
    }
    setState(() {
      _autoPingEnabled = value ?? false;
    });
  }

  Future<void> _manualPing() async {
    if (!_loraConnected) {
      _showSnackBar('Connect LoRa device first');
      return;
    }

    if (_currentPosition == null) {
      _showSnackBar('Waiting for GPS location...');
      return;
    }

    _showSnackBar('Sending ping...');

    // Send ping via LoRa companion
    final result = await _locationService.loraCompanion.ping(
      latitude: _currentPosition!.latitude,
      longitude: _currentPosition!.longitude,
    );

    // Create and save sample
    final geohash = GeohashUtils.sampleKey(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );
    
    final sample = Sample(
      id: '${DateTime.now().millisecondsSinceEpoch}_$geohash',
      position: _currentPosition!,
      timestamp: DateTime.now(),
      path: result.nodeId, // Save repeater/node ID
      geohash: geohash,
      rssi: result.rssi,
      snr: result.snr,
      pingSuccess: result.status == PingStatus.success,
    );
    
    await DatabaseService().insertSample(sample);

    // Reload samples to update map
    await _loadSamples();

    // Show result
    if (result.status == PingStatus.success) {
      _showSnackBar('✅ Ping heard by ${result.nodeId}');
    } else if (result.status == PingStatus.timeout) {
      _showSnackBar('❌ No response - dead zone');
    } else {
      _showSnackBar('❌ Ping failed: ${result.error}');
    }
  }

  void _showConnectionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect LoRa Device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose connection method:', 
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _connectUsb();
              },
              icon: const Icon(Icons.usb),
              label: const Text('Scan USB Devices'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 40),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _connectBluetooth();
              },
              icon: const Icon(Icons.bluetooth),
              label: const Text('Scan Bluetooth'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 40),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectUsb() async {
    try {
      final devices = await _locationService.loraCompanion.scanUsbDevices();
      
      if (!mounted) return;
      
      if (devices.isEmpty) {
        _showSnackBar('No USB devices found');
        return;
      }

      final selected = await showDialog<UsbDevice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select USB Device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: devices.map((device) {
              return ListTile(
                title: Text(device.productName ?? 'USB Device'),
                subtitle: Text('VID: ${device.vid}, PID: ${device.pid}'),
                onTap: () => Navigator.pop(context, device),
              );
            }).toList(),
          ),
        ),
      );

      if (selected != null) {
        final connected = await _locationService.loraCompanion.connectUsb(selected);
        if (connected) {
          _showSnackBar('Connected via USB');
          await _loadSamples();
        } else {
          _showSnackBar('Failed to connect USB device');
        }
      }
    } catch (e) {
      _showSnackBar('USB error: $e');
    }
  }

  Future<void> _connectBluetooth() async {
    try {
      _showSnackBar('Scanning for Bluetooth devices...');
      final devices = await _locationService.loraCompanion.scanBluetoothDevices();
      
      if (!mounted) return;
      
      if (devices.isEmpty) {
        _showSnackBar('No LoRa devices found via Bluetooth');
        return;
      }

      final selected = await showDialog<BluetoothDevice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select Bluetooth Device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: devices.map((device) {
              return ListTile(
                title: Text(device.platformName),
                subtitle: Text(device.remoteId.toString()),
                onTap: () => Navigator.pop(context, device),
              );
            }).toList(),
          ),
        ),
      );

      if (selected != null) {
        _showSnackBar('Connecting to ${selected.platformName}...');
        
        final connected = await _locationService.loraCompanion.connectBluetooth(selected);
        if (connected) {
          _showSnackBar('Connected via Bluetooth!');
          await _loadSamples();
        } else {
          _showSnackBar('Failed to connect Bluetooth device');
        }
      }
    } catch (e) {
      _showSnackBar('Bluetooth error: $e');
    }
  }


  String _getPingIntervalDescription() {
    if (_pingIntervalMeters < 100) {
      return '${_pingIntervalMeters.toInt()} meters (frequent)';
    } else if (_pingIntervalMeters < 1000) {
      return '${_pingIntervalMeters.toInt()} meters';
    } else {
      final miles = (_pingIntervalMeters / 1609.34).toStringAsFixed(1);
      return '$miles miles (${_pingIntervalMeters.toInt()}m)';
    }
  }

  Future<void> _setPingInterval() async {
    String? selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ping Interval'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('How often should pings be sent?'),
            const SizedBox(height: 16),
            ListTile(
              title: const Text('Frequent'),
              subtitle: const Text('Every 50 meters'),
              onTap: () => Navigator.pop(context, '50'),
            ),
            ListTile(
              title: const Text('Normal'),
              subtitle: const Text('Every 200 meters (~0.12 miles)'),
              onTap: () => Navigator.pop(context, '200'),
            ),
            ListTile(
              title: const Text('Sparse'),
              subtitle: const Text('Every 0.5 miles (805 meters)'),
              onTap: () => Navigator.pop(context, '805'),
            ),
            ListTile(
              title: const Text('Very Sparse'),
              subtitle: const Text('Every 1 mile (1609 meters)'),
              onTap: () => Navigator.pop(context, '1609'),
            ),
          ],
        ),
      ),
    );

    if (selected != null) {
      final interval = double.parse(selected);
      setState(() {
        _pingIntervalMeters = interval;
      });
      // Update location service ping interval
      _locationService.setPingInterval(_pingIntervalMeters);
      await _settingsService.setPingInterval(interval);
      _showSnackBar('Ping interval: ${_getPingIntervalDescription()}');
    }
  }

  String _getCoverageResolutionDescription() {
    switch (_coveragePrecision) {
      case 4:
        return 'Regional (~20km squares)';
      case 5:
        return 'City-level (~5km squares)';
      case 6:
        return 'Neighborhood (~1.2km squares)';
      case 7:
        return 'Street-level (~153m squares)';
      case 8:
        return 'Building-level (~38m squares)';
      default:
        return 'Unknown';
    }
  }

  Future<void> _setCoverageResolution() async {
    String? selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Coverage Resolution'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Choose the size of coverage squares:'),
            const SizedBox(height: 16),
            ListTile(
              title: const Text('Regional'),
              subtitle: const Text('~20km squares (precision 4)'),
              onTap: () => Navigator.pop(context, '4'),
            ),
            ListTile(
              title: const Text('City-level'),
              subtitle: const Text('~5km squares (precision 5)'),
              onTap: () => Navigator.pop(context, '5'),
            ),
            ListTile(
              title: const Text('Neighborhood'),
              subtitle: const Text('~1.2km squares (precision 6, default)'),
              onTap: () => Navigator.pop(context, '6'),
            ),
            ListTile(
              title: const Text('Street-level'),
              subtitle: const Text('~153m squares (precision 7)'),
              onTap: () => Navigator.pop(context, '7'),
            ),
            ListTile(
              title: const Text('Building-level'),
              subtitle: const Text('~38m squares (precision 8, detailed)'),
              onTap: () => Navigator.pop(context, '8'),
            ),
          ],
        ),
      ),
    );

    if (selected != null) {
      final precision = int.parse(selected);
      setState(() {
        _coveragePrecision = precision;
      });
      await _settingsService.setCoveragePrecision(precision);
      // Reload samples with new precision
      await _loadSamples();
      _showSnackBar('Coverage resolution: ${_getCoverageResolutionDescription()}');
    }
  }

  Future<void> _setIgnoredRepeater() async {
    final controller = TextEditingController(text: _ignoredRepeaterPrefix ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ignore Mobile Repeater'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Filter out responses from your mobile repeater to avoid false coverage.\n\n'
              'Enter the first 2-3 characters of your repeater\'s public key:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Public Key Prefix',
                hintText: 'e.g., 7E, A4F, etc.',
                isDense: true,
              ),
              textCapitalization: TextCapitalization.characters,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final prefix = controller.text.isEmpty ? null : controller.text;
      setState(() {
        _ignoredRepeaterPrefix = prefix;
      });
      _locationService.loraCompanion.setIgnoredRepeaterPrefix(_ignoredRepeaterPrefix);
      await _settingsService.setIgnoredRepeaterPrefix(prefix);
      _showSnackBar('Repeater prefix updated');
    }
  }

  Future<void> _setIncludeOnlyRepeaters() async {
    final controller = TextEditingController(text: _includeOnlyRepeaters ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Include Only Repeaters'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Show ONLY samples from specific repeaters (whitelist). Useful for testing your own infrastructure.\n\n'
              'Enter repeater prefixes separated by commas:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Repeater Prefixes',
                hintText: 'e.g., 7E3A, A4F2, 8B',
                isDense: true,
              ),
              textCapitalization: TextCapitalization.characters,
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final prefixes = controller.text.isEmpty ? null : controller.text;
      setState(() {
        _includeOnlyRepeaters = prefixes;
      });
      await _settingsService.setIncludeOnlyRepeaters(prefixes);
      _showSnackBar('Repeater whitelist updated');
    }
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.5,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) => Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                controller: scrollController,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            Row(
              children: [
                const Text(
                  'Settings',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  'v$appVersion',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Show Coverage Boxes'),
              value: _showCoverage,
              onChanged: (value) async {
                setState(() {
                  _showCoverage = value;
                });
                setModalState(() {});
                await _settingsService.setShowCoverage(value);
              },
            ),
            SwitchListTile(
              title: const Text('Show Samples'),
              value: _showSamples,
              onChanged: (value) async {
                setState(() {
                  _showSamples = value;
                });
                setModalState(() {});
                await _settingsService.setShowSamples(value);
              },
            ),
            SwitchListTile(
              title: const Text('Show Edges'),
              value: _showEdges,
              onChanged: (value) async {
                setState(() {
                  _showEdges = value;
                });
                setModalState(() {});
                await _settingsService.setShowEdges(value);
              },
            ),
            SwitchListTile(
              title: const Text('Show Repeaters'),
              value: _showRepeaters,
              onChanged: (value) async {
                setState(() {
                  _showRepeaters = value;
                });
                setModalState(() {});
                await _settingsService.setShowRepeaters(value);
              },
            ),
            SwitchListTile(
              title: const Text('Show GPS Samples'),
              subtitle: const Text('Show blue GPS-only markers'),
              value: _showGpsSamples,
              onChanged: (value) async {
                setState(() {
                  _showGpsSamples = value;
                });
                setModalState(() {});
                await _settingsService.setShowGpsSamples(value);
              },
            ),
            SwitchListTile(
              title: const Text('Show Successful Pings Only'),
              subtitle: const Text('Hide failed pings and GPS-only samples'),
              value: _showSuccessfulOnly,
              onChanged: (value) {
                setState(() {
                  _showSuccessfulOnly = value;
                });
                setModalState(() {});
              },
            ),
            SwitchListTile(
              title: const Text('Show Route Trail'),
              subtitle: const Text('Draw driven path on map'),
              value: _showRouteTrail,
              onChanged: (value) async {
                setState(() {
                  _showRouteTrail = value;
                });
                setModalState(() {});
                await _settingsService.setShowRouteTrail(value);
              },
            ),
            SwitchListTile(
              title: const Text('Show Heatmap'),
              subtitle: const Text('Heat gradient overlay of ping activity'),
              value: _showHeatmap,
              onChanged: (value) async {
                setState(() {
                  _showHeatmap = value;
                });
                setModalState(() {});
                await _settingsService.setShowHeatmap(value);
                // Trigger heatmap rebuild
                _heatmapRebuildStream.add(null);
              },
            ),
            SwitchListTile(
              title: const Text('Show Prediction Rings'),
              subtitle: const Text('Estimated repeater coverage radius'),
              value: _showPredictionRings,
              onChanged: (value) async {
                setState(() {
                  _showPredictionRings = value;
                });
                setModalState(() {});
                await _settingsService.setShowPredictionRings(value);
              },
            ),
            SwitchListTile(
              title: const Text('Atmospheric Ducting'),
              subtitle: const Text('Monitor ducting conditions (needs internet)'),
              value: _showDucting,
              onChanged: (value) async {
                setState(() {
                  _showDucting = value;
                });
                setModalState(() {});
                await _settingsService.setShowDucting(value);
                _locationService.setDuctingEnabled(value);
                if (value) {
                  // Fetch immediately and update badge
                  final risk = await _locationService.ductingService.getLatestRisk();
                  setState(() { _currentDuctingRisk = risk; });
                }
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Carpeater Mode',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            SwitchListTile(
              title: const Text('Enable Carpeater Mode'),
              subtitle: Text(_carpeaterEnabled
                  ? 'Using repeater for discovery'
                  : 'Use a repeater to discover neighbors'),
              value: _carpeaterEnabled,
              onChanged: (value) async {
                setState(() { _carpeaterEnabled = value; });
                setModalState(() {});
                await _settingsService.setCarpeaterEnabled(value);
                _locationService.setCarpeaterMode(value);
              },
            ),
            if (_carpeaterEnabled) ...[
              ListTile(
                title: const Text('Target Repeater'),
                subtitle: Text(_carpeaterRepeaterId ?? 'Not set'),
                leading: const Icon(Icons.cell_tower),
                trailing: const Icon(Icons.edit, size: 20),
                onTap: () async {
                  final controller = TextEditingController(text: _carpeaterRepeaterId ?? '');
                  final result = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Target Repeater'),
                      content: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          labelText: 'Repeater ID Prefix',
                          hintText: 'e.g., BAD5DC49',
                        ),
                        textCapitalization: TextCapitalization.characters,
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
                      ],
                    ),
                  );
                  if (result != null) {
                    setState(() { _carpeaterRepeaterId = result.isEmpty ? null : result; });
                    setModalState(() {});
                    await _settingsService.setCarpeaterRepeaterId(result.isEmpty ? null : result);
                  }
                },
              ),
              ListTile(
                title: const Text('Admin Password'),
                subtitle: Text(_carpeaterPassword != null ? '•' * _carpeaterPassword!.length : 'Not set'),
                leading: const Icon(Icons.lock),
                trailing: const Icon(Icons.edit, size: 20),
                onTap: () async {
                  final controller = TextEditingController(text: _carpeaterPassword ?? '');
                  final result = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Admin Password'),
                      content: TextField(
                        controller: controller,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          hintText: 'Repeater admin password',
                        ),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
                      ],
                    ),
                  );
                  if (result != null) {
                    setState(() { _carpeaterPassword = result.isEmpty ? null : result; });
                    setModalState(() {});
                    await _settingsService.setCarpeaterPassword(result.isEmpty ? null : result);
                  }
                },
              ),
              ListTile(
                title: const Text('Discovery Interval'),
                trailing: DropdownButton<int>(
                  value: _carpeaterInterval,
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5s')),
                    DropdownMenuItem(value: 10, child: Text('10s')),
                    DropdownMenuItem(value: 15, child: Text('15s')),
                    DropdownMenuItem(value: 30, child: Text('30s')),
                    DropdownMenuItem(value: 60, child: Text('60s')),
                    DropdownMenuItem(value: 120, child: Text('2m')),
                  ],
                  onChanged: (value) async {
                    setState(() { _carpeaterInterval = value!; });
                    setModalState(() {});
                    await _settingsService.setCarpeaterInterval(value!);
                  },
                ),
              ),
            ],
            const Divider(),
            SwitchListTile(
              title: const Text('Lock Map Rotation'),
              subtitle: const Text('Prevent map rotation'),
              value: _lockRotationNorth,
              onChanged: (value) {
                setState(() {
                  _lockRotationNorth = value;
                });
                setModalState(() {});
              },
            ),
            ListTile(
              title: const Text('Theme'),
              subtitle: Text(_getThemeModeText()),
              trailing: const Icon(Icons.brightness_6),
              onTap: () {
                Navigator.pop(context);
                _showThemeSelector();
              },
            ),
            if (_loraConnected)
              ListTile(
                title: const Text('Scan for Repeaters'),
                subtitle: Text(_repeaters.isEmpty 
                    ? 'Find nearby LoRa nodes' 
                    : '${_repeaters.length} repeater(s) found'),
                leading: const Icon(Icons.cell_tower),
                trailing: const Icon(Icons.search),
                onTap: () {
                  Navigator.pop(context);
                  _scanForRepeaters();
                },
              ),
            if (_loraConnected)
              ListTile(
                title: const Text('Refresh Contact List'),
                subtitle: const Text('Update repeater names from device'),
                leading: const Icon(Icons.refresh),
                onTap: () {
                  Navigator.pop(context);
                  _refreshContacts();
                },
              ),
            ListTile(
              title: const Text('Color Mode'),
              trailing: DropdownButton<String>(
                value: _colorMode,
                items: const [
                  DropdownMenuItem(value: 'quality', child: Text('Quality')),
                  DropdownMenuItem(value: 'age', child: Text('Age')),
                ],
                onChanged: (value) async {
                  setState(() {
                    _colorMode = value!;
                  });
                  await _settingsService.setColorMode(value!);
                },
              ),
            ),
            ListTile(
              title: const Text('Distance Unit'),
              trailing: DropdownButton<String>(
                value: _distanceUnit,
                items: const [
                  DropdownMenuItem(value: 'miles', child: Text('Miles')),
                  DropdownMenuItem(value: 'km', child: Text('Kilometers')),
                ],
                onChanged: (value) async {
                  setState(() {
                    _distanceUnit = value!;
                    // Update displayed distance immediately
                    _totalDistance = value == 'miles' 
                        ? _locationService.totalDistanceMiles 
                        : _locationService.totalDistanceKm;
                  });
                  setModalState(() {});
                  await _settingsService.setDistanceUnit(value!);
                },
              ),
            ),
            ListTile(
              title: const Text('Fuel Unit'),
              trailing: DropdownButton<String>(
                value: _fuelUnit,
                items: const [
                  DropdownMenuItem(value: 'imperial', child: Text('MPG / Gallons')),
                  DropdownMenuItem(value: 'metric', child: Text('L/100km / Litres')),
                ],
                onChanged: (value) async {
                  setState(() {
                    _fuelUnit = value!;
                  });
                  setModalState(() {});
                  await _settingsService.setFuelUnit(value!);
                },
              ),
            ),
            ListTile(
              title: const Text('Color Blind Mode'),
              trailing: DropdownButton<String>(
                value: _colorBlindMode,
                items: const [
                  DropdownMenuItem(value: 'normal', child: Text('Normal')),
                  DropdownMenuItem(value: 'deuteranopia', child: Text('Deuteranopia')),
                  DropdownMenuItem(value: 'protanopia', child: Text('Protanopia')),
                  DropdownMenuItem(value: 'tritanopia', child: Text('Tritanopia')),
                ],
                onChanged: (value) async {
                  setState(() {
                    _colorBlindMode = value!;
                  });
                  setModalState(() {});
                  await _settingsService.setColorBlindMode(value!);
                },
              ),
            ),
            ListTile(
              title: const Text('Discovery Timeout'),
              subtitle: const Text('How long to wait for repeater responses'),
              trailing: DropdownButton<int>(
                value: _discoveryTimeoutSeconds,
                items: const [
                  DropdownMenuItem(value: 5, child: Text('5s')),
                  DropdownMenuItem(value: 10, child: Text('10s')),
                  DropdownMenuItem(value: 15, child: Text('15s')),
                  DropdownMenuItem(value: 20, child: Text('20s')),
                  DropdownMenuItem(value: 25, child: Text('25s')),
                  DropdownMenuItem(value: 30, child: Text('30s')),
                ],
                onChanged: (value) async {
                  setState(() {
                    _discoveryTimeoutSeconds = value!;
                  });
                  setModalState(() {});
                  await _settingsService.setDiscoveryTimeout(value!);
                },
              ),
            ),
            ListTile(
              title: const Text('Ignore Mobile Repeater'),
              subtitle: Text(_ignoredRepeaterPrefix != null 
                  ? 'Filtering: ${_ignoredRepeaterPrefix}*' 
                  : 'Not filtering'),
              trailing: const Icon(Icons.edit),
              onTap: () {
                Navigator.pop(context);
                _setIgnoredRepeater();
              },
            ),
            ListTile(
              title: const Text('Include Only Repeaters'),
              subtitle: Text(_includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty
                  ? 'Whitelist: ${_includeOnlyRepeaters}' 
                  : 'Show all repeaters'),
              trailing: const Icon(Icons.edit),
              onTap: () {
                Navigator.pop(context);
                _setIncludeOnlyRepeaters();
              },
            ),
            SwitchListTile(
              title: const Text('Apply Whitelist to Edges'),
              subtitle: const Text('Only show edges for whitelisted repeaters'),
              value: _filterEdgesByWhitelist,
              onChanged: (value) async {
                setState(() {
                  _filterEdgesByWhitelist = value;
                });
                setModalState(() {});
                await _settingsService.setFilterEdgesByWhitelist(value);
              },
            ),
            ListTile(
              title: const Text('Ping Interval'),
              subtitle: Text(_getPingIntervalDescription()),
              trailing: const Icon(Icons.tune),
              onTap: () {
                Navigator.pop(context);
                _setPingInterval();
              },
            ),
            ListTile(
              title: const Text('Coverage Resolution'),
              subtitle: Text(_getCoverageResolutionDescription()),
              trailing: const Icon(Icons.grid_on),
              onTap: () {
                Navigator.pop(context);
                _setCoverageResolution();
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Statistics',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            FutureBuilder<List<double?>>(
              future: Future.wait([
                _settingsService.getTotalDistanceDriven(),
                _settingsService.getVehicleMpg(),
                _settingsService.getGasPrice(),
              ]),
              builder: (context, snapshot) {
                final totalMeters = snapshot.data?[0] ?? 0.0;
                final vehicleMpg = snapshot.data?[1];
                final gasPrice = snapshot.data?[2] ?? 3.50;
                final sessionMeters = _isTracking ? _locationService.totalDistanceMeters : 0.0;
                final grandTotalMeters = totalMeters + sessionMeters;
                final distanceDisplay = _distanceUnit == 'miles'
                    ? '${(grandTotalMeters / 1609.34).toStringAsFixed(2)} mi'
                    : '${(grandTotalMeters / 1000.0).toStringAsFixed(2)} km';
                
                // Estimate fuel usage
                String? fuelDisplay;
                if (vehicleMpg != null && vehicleMpg > 0) {
                  final totalMiles = grandTotalMeters / 1609.34;
                  final gallonsUsed = totalMiles / vehicleMpg;
                  if (_fuelUnit == 'metric') {
                    final litresUsed = gallonsUsed * 3.78541;
                    final pricePerLitre = gasPrice! / 3.78541;
                    fuelDisplay = '${litresUsed.toStringAsFixed(2)} L (~\$${(litresUsed * pricePerLitre).toStringAsFixed(2)} @ \$${pricePerLitre.toStringAsFixed(2)}/L)';
                  } else {
                    fuelDisplay = '${gallonsUsed.toStringAsFixed(2)} gal (~\$${(gallonsUsed * gasPrice!).toStringAsFixed(2)} @ \$${gasPrice.toStringAsFixed(2)}/gal)';
                  }
                }
                
                return Column(
                  children: [
                    ListTile(
                      title: const Text('Total Distance Driven'),
                      subtitle: Text(distanceDisplay),
                      leading: const Icon(Icons.straighten),
                      trailing: IconButton(
                        icon: const Icon(Icons.restart_alt, size: 20),
                        tooltip: 'Reset',
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Reset Distance'),
                              content: const Text('Reset total distance driven to zero?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Reset'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await _settingsService.resetTotalDistanceDriven();
                            setModalState(() {});
                          }
                        },
                      ),
                    ),
                    if (fuelDisplay != null)
                      ListTile(
                        title: const Text('Estimated Fuel Used'),
                        subtitle: Text(fuelDisplay),
                        leading: const Icon(Icons.local_gas_station),
                      ),
                    ListTile(
                      title: const Text('Vehicle Fuel Economy'),
                      subtitle: Text(vehicleMpg != null
                          ? (_fuelUnit == 'metric'
                              ? '${(235.215 / vehicleMpg).toStringAsFixed(1)} L/100km'
                              : '${vehicleMpg.toStringAsFixed(1)} MPG')
                          : 'Not set'),
                      leading: const Icon(Icons.directions_car),
                      trailing: const Icon(Icons.edit, size: 20),
                      onTap: () async {
                        final isMetric = _fuelUnit == 'metric';
                        final displayValue = vehicleMpg != null && isMetric
                            ? (235.215 / vehicleMpg).toStringAsFixed(1)
                            : vehicleMpg?.toStringAsFixed(1) ?? '';
                        final controller = TextEditingController(
                          text: displayValue,
                        );
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Vehicle Fuel Economy'),
                            content: TextField(
                              controller: controller,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                labelText: isMetric ? 'Litres per 100km (L/100km)' : 'Miles Per Gallon (MPG)',
                                hintText: isMetric ? 'e.g., 9.4' : 'e.g., 25.0',
                              ),
                              autofocus: true,
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              if (vehicleMpg != null)
                                TextButton(
                                  onPressed: () async {
                                    await _settingsService.setVehicleMpg(null);
                                    Navigator.pop(ctx, true);
                                  },
                                  child: const Text('Clear'),
                                ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Save'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && controller.text.isNotEmpty) {
                          final inputValue = double.tryParse(controller.text);
                          if (inputValue != null && inputValue > 0) {
                            // Convert L/100km to MPG for internal storage
                            final mpgToStore = isMetric ? 235.215 / inputValue : inputValue;
                            await _settingsService.setVehicleMpg(mpgToStore);
                          }
                        }
                        setModalState(() {});
                      },
                    ),
                    ListTile(
                      title: Text(_fuelUnit == 'metric' ? 'Fuel Price' : 'Gas Price'),
                      subtitle: Text(_fuelUnit == 'metric'
                          ? '\$${(gasPrice! / 3.78541).toStringAsFixed(2)}/L'
                          : '\$${gasPrice!.toStringAsFixed(2)}/gal'),
                      leading: const Icon(Icons.attach_money),
                      trailing: const Icon(Icons.edit, size: 20),
                      onTap: () async {
                        final isMetric = _fuelUnit == 'metric';
                        final displayPrice = isMetric
                            ? (gasPrice! / 3.78541).toStringAsFixed(2)
                            : gasPrice!.toStringAsFixed(2);
                        final controller = TextEditingController(
                          text: displayPrice,
                        );
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(isMetric ? 'Fuel Price' : 'Gas Price'),
                            content: TextField(
                              controller: controller,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                labelText: isMetric ? 'Price per Litre' : 'Price per Gallon',
                                hintText: isMetric ? 'e.g., 1.85' : 'e.g., 3.50',
                                prefixText: '\$ ',
                              ),
                              autofocus: true,
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Save'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true && controller.text.isNotEmpty) {
                          final inputPrice = double.tryParse(controller.text);
                          if (inputPrice != null && inputPrice > 0) {
                            // Convert $/L to $/gal for internal storage
                            final priceToStore = isMetric ? inputPrice * 3.78541 : inputPrice;
                            await _settingsService.setGasPrice(priceToStore);
                          }
                        }
                        setModalState(() {});
                      },
                    ),
                  ],
                );
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Data Management',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ListTile(
              title: const Text('Analytics'),
              subtitle: const Text('Time, goals, comparison & repeater stats'),
              leading: const Icon(Icons.analytics),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AnalyticsScreen(
                      samples: _samples,
                      coveragePrecision: _coveragePrecision,
                      currentPosition: _currentPosition,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              title: const Text('Session History'),
              subtitle: Text(_activeSessionFilter != null 
                  ? 'Filtering by session' 
                  : 'View past wardrive sessions'),
              leading: const Icon(Icons.history),
              trailing: _activeSessionFilter != null
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.red),
                      onPressed: () {
                        setState(() {
                          _activeSessionFilter = null;
                        });
                        setModalState(() {});
                        _loadSamples();
                        _showSnackBar('Session filter cleared');
                      },
                      tooltip: 'Clear filter',
                    )
                  : const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _openSessionHistory();
              },
            ),
            ListTile(
              title: const Text('Export Data'),
              subtitle: const Text('JSON, CSV, GPX, or KML'),
              leading: const Icon(Icons.upload),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _exportData();
              },
            ),
            ListTile(
              title: const Text('Import Data'),
              subtitle: const Text('Load samples from file'),
              leading: const Icon(Icons.download),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _importData();
              },
            ),
            ListTile(
              title: const Text('Share Coverage Map'),
              subtitle: const Text('Screenshot + share in one tap'),
              leading: const Icon(Icons.share),
              onTap: () {
                Navigator.pop(context);
                _shareCoverageMap();
              },
            ),
            ListTile(
              title: const Text('Filter by Repeater'),
              subtitle: Text(_includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty
                  ? 'Filtering: $_includeOnlyRepeaters'
                  : 'Show coverage from a specific repeater'),
              leading: const Icon(Icons.filter_alt),
              trailing: _includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.red),
                      onPressed: () async {
                        setState(() { _includeOnlyRepeaters = null; });
                        await _settingsService.setIncludeOnlyRepeaters(null);
                        setModalState(() {});
                        _loadSamples();
                        _showSnackBar('Repeater filter cleared');
                      },
                    )
                  : const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _showRepeaterFilterPicker();
              },
            ),
            ListTile(
              title: const Text('Find Coverage Gaps'),
              subtitle: const Text('Locate areas with poor signal'),
              leading: const Icon(Icons.location_searching),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _findCoverageGaps();
              },
            ),
            ListTile(
              title: const Text('Clear Map'),
              subtitle: const Text('Delete all samples and coverage'),
              leading: const Icon(Icons.delete, color: Colors.red),
              onTap: () {
                Navigator.pop(context);
                _clearData();
              },
            ),
            ListTile(
              title: const Text('Clear Tile Cache'),
              subtitle: const Text('Remove cached offline map tiles'),
              leading: const Icon(Icons.cached, color: Colors.orange),
              onTap: () async {
                if (_tileCacheStore != null) {
                  await _tileCacheStore!.clean();
                  _showSnackBar('Tile cache cleared');
                }
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Debug',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ListTile(
              title: const Text('Signal Trends'),
              subtitle: const Text('RSSI, SNR & response time charts'),
              leading: const Icon(Icons.show_chart),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SignalTrendScreen(samples: _samples),
                  ),
                );
              },
            ),
            ListTile(
              title: const Text('Debug Diagnostics'),
              subtitle: const Text('View debug logs for troubleshooting'),
              leading: const Icon(Icons.bug_report),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _openDebugDiagnostics();
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Online Map',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ListTile(
              title: const Text('Upload Data'),
              subtitle: const Text('Upload samples to web map'),
              leading: const Icon(Icons.cloud_upload),
              onTap: () {
                Navigator.pop(context);
                _uploadSamples();
              },
            ),
            ListTile(
              title: const Text('Manage Upload Sites'),
              subtitle: const Text('Add/edit upload endpoints'),
              leading: const Icon(Icons.dns),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _manageUploadSites();
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'About',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ListTile(
              title: const Text('Check for Updates'),
              subtitle: const Text('Current version: v$appVersion'),
              leading: const Icon(Icons.system_update),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _checkForUpdates();
              },
            ),
            ListTile(
              title: const Text('View on GitHub'),
              subtitle: const Text('Source code and releases'),
              leading: const Icon(Icons.code),
              trailing: const Icon(Icons.open_in_new),
              onTap: () {
                Navigator.pop(context);
                _openGitHub();
              },
            ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }
  
  
  Future<void> _disconnectLoRa() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect LoRa Device'),
        content: const Text('Disconnect from your LoRa companion device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      // Disable auto-ping first
      if (_autoPingEnabled) {
        _locationService.disableAutoPing();
      }
      
      await _locationService.loraCompanion.disconnectDevice();
      await _loadSamples();
      _showSnackBar('LoRa device disconnected');
    }
  }
  
  
  IconData _getBatteryIcon(int percent) {
    if (percent > 90) return Icons.battery_full;
    if (percent > 70) return Icons.battery_5_bar;
    if (percent > 50) return Icons.battery_4_bar;
    if (percent > 30) return Icons.battery_3_bar;
    if (percent > 15) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }
  
  Color _getBatteryColor(int percent) {
    if (percent > 30) return Colors.green;
    if (percent > 15) return Colors.orange;
    return Colors.red;
  }
  
  String _carpeaterStateLabel() {
    switch (_carpeaterState) {
      case CarpeaterState.disabled: return 'Off';
      case CarpeaterState.connecting: return 'Connecting';
      case CarpeaterState.loggingIn: return 'Login...';
      case CarpeaterState.loggedIn: return 'Ready';
      case CarpeaterState.discovering: return 'Scanning';
      case CarpeaterState.fetchingNeighbours: return 'Fetching';
      case CarpeaterState.error: return 'Error';
    }
  }
  
  Color _getDuctingColor(String risk) {
    switch (risk) {
      case 'none':
        return Colors.green;
      case 'possible':
        return Colors.orange;
      case 'likely':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
  
  Future<void> _refreshContacts() async {
    if (!_loraConnected) {
      _showSnackBar('Connect LoRa device first');
      return;
    }
    
    _showSnackBar('Refreshing contact list...');
    
    // Request full contact list from device
    await _locationService.loraCompanion.refreshContactList();
    
    // Give it a moment to process
    await Future.delayed(const Duration(seconds: 2));
    
    _showSnackBar('Contact list updated');
  }
  
  Future<void> _scanForRepeaters() async {
    if (!_loraConnected) {
      _showSnackBar('Connect LoRa device first');
      return;
    }
    
    _showSnackBar('Scanning for repeaters...');
    
    final repeaters = await _locationService.loraCompanion.scanForRepeaters();
    
    setState(() {
      _repeaters = repeaters;
    });
    
    if (repeaters.isEmpty) {
      _showSnackBar('No repeaters found');
    } else {
      _showSnackBar('Found ${repeaters.length} repeater(s)');
      _showRepeatersDialog();
    }
  }
  
  void _openSessionHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SessionHistoryScreen(
          onSessionSelected: (session) {
            setState(() {
              _activeSessionFilter = session;
            });
            _loadSamples();
            _showSnackBar('Showing session from ${DateFormat('MMM d, h:mm a').format(session.startTime)}');
          },
        ),
      ),
    );
  }
  
  void _openDebugDiagnostics() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DebugDiagnosticsScreen(
          locationService: _locationService,
        ),
      ),
    );
  }
  
  String _getThemeModeText() {
    final appState = MyApp.of(context);
    if (appState == null) return 'System Default';
    
    switch (appState.themeMode) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'System Default';
    }
  }
  
  Future<void> _showThemeSelector() async {
    final appState = MyApp.of(context);
    if (appState == null) return;
    
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Theme'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Light'),
              leading: const Icon(Icons.light_mode),
              onTap: () => Navigator.pop(context, ThemeMode.light),
            ),
            ListTile(
              title: const Text('Dark'),
              leading: const Icon(Icons.dark_mode),
              onTap: () => Navigator.pop(context, ThemeMode.dark),
            ),
            ListTile(
              title: const Text('System Default'),
              leading: const Icon(Icons.brightness_auto),
              onTap: () => Navigator.pop(context, ThemeMode.system),
            ),
          ],
        ),
      ),
    );
    
    if (selected != null) {
      await appState.setThemeMode(selected);
      setState(() {}); // Refresh to update map tiles
    }
  }
  
  String? _getRepeaterName(String? repeaterId) {
    if (repeaterId == null) return null;
    
    // If it's a 2-char prefix, try to expand it first
    String? fullId = repeaterId;
    if (repeaterId.length == 2) {
      fullId = _locationService.loraCompanion.matchRepeaterPrefix(repeaterId);
      if (fullId == null) {
        // No match found, return the 2-char prefix as-is
        return repeaterId;
      }
    }
    
    // First check discovered repeaters list
    final repeater = _repeaters.firstWhere(
      (r) => r.id == fullId,
      orElse: () => Repeater(id: fullId!, position: const LatLng(0, 0), timestamp: DateTime.now()),
    );
    if (repeater.name != null) return repeater.name;
    
    // Fall back to checking LoRa service's contact cache
    final loraRepeater = _locationService.loraCompanion.getRepeaterLocation(fullId!);
    return loraRepeater?.name ?? fullId; // Return full ID if no name
  }
  
  void _showSampleInfo(Sample sample) {
    final timestamp = DateFormat('MMM d, yyyy HH:mm:ss').format(sample.timestamp);
    final hasSignalData = sample.rssi != null || sample.snr != null;
    final pingStatus = sample.pingSuccess == true 
        ? '✅ Success' 
        : sample.pingSuccess == false 
            ? '❌ Failed' 
            : '📍 GPS Only';
    
    // Get repeater name if available (sample.path holds repeater/node ID)
    final repeaterName = sample.path != null ? _getRepeaterName(sample.path) : null;
    final idOrName = repeaterName ?? sample.path ?? 'Unknown';
    final repeaterDisplay = (repeaterName != null)
        ? repeaterName
        : (idOrName.length > 8 ? idOrName.substring(0, 8).toUpperCase() : idOrName.toUpperCase());
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sample Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Status: ', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(pingStatus),
              ],
            ),
            const SizedBox(height: 8),
            Text('Time: $timestamp', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Text('Lat: ${sample.position.latitude.toStringAsFixed(6)}'),
            Text('Lon: ${sample.position.longitude.toStringAsFixed(6)}'),
            if (sample.path != null) ...[
              const Divider(height: 16),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Repeater: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(child: Text(repeaterDisplay, style: const TextStyle(fontFamily: 'monospace'))),
                ],
              ),
            ],
            if (hasSignalData)
              const Divider(height: 16),
            if (hasSignalData)
              const SizedBox(height: 8),
            if (sample.rssi != null)
              Row(
                children: [
                  const Text('RSSI: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${sample.rssi} dBm'),
                ],
              ),
            if (sample.snr != null)
              Row(
                children: [
                  const Text('SNR: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${sample.snr} dB'),
                ],
              ),
            if (sample.responseTimeMs != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('Response: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${sample.responseTimeMs} ms'),
                ],
              ),
            ],
            if (sample.ductingRisk != null) ...[
              const Divider(height: 16),
              Row(
                children: [
                  const Text('Ducting: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _getDuctingColor(sample.ductingRisk!).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      DuctingService.riskLabel(sample.ductingRisk!),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _getDuctingColor(sample.ductingRisk!),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
  
  void _showRepeaterInfo(Repeater repeater) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(repeater.name ?? 'Repeater ${(repeater.id.length > 8 ? repeater.id.substring(0,8) : repeater.id).toUpperCase()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ID: ${(repeater.id.length > 8 ? repeater.id.substring(0,8) : repeater.id).toUpperCase()}', style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Text('Lat: ${repeater.position.latitude.toStringAsFixed(6)}'),
            Text('Lon: ${repeater.position.longitude.toStringAsFixed(6)}'),
            if (repeater.rssi != null)
              const SizedBox(height: 8),
            if (repeater.rssi != null)
              Text('RSSI: ${repeater.rssi} dBm'),
            if (repeater.snr != null)
              Text('SNR: ${repeater.snr} dB'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() { _includeOnlyRepeaters = repeater.id; });
              await _settingsService.setIncludeOnlyRepeaters(repeater.id);
              _loadSamples();
              _showSnackBar('Filtering by ${(repeater.id.length > 8 ? repeater.id.substring(0,8) : repeater.id).toUpperCase()}');
            },
            child: const Text('Filter by This'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _mapController.move(repeater.position, 15.0);
            },
            child: const Text('Show on Map'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
  
  void _showCoverageInfo(Coverage coverage) {
    // Calculate total samples and success rate
    final total = coverage.received + coverage.lost;
    final successRate = total > 0 ? ((coverage.received / total) * 100).toStringAsFixed(0) : 'N/A';
    final reliabilityText = total > 0 ? '$successRate%' : 'No ping data';
    
    // Round weighted values to 1 decimal place for display
    final receivedDisplay = coverage.received.toStringAsFixed(1);
    final lostDisplay = coverage.lost.toStringAsFixed(1);
    final totalDisplay = total.toStringAsFixed(1);
    
    // Get unique repeater prefixes (first 2 chars)
    final uniquePrefixes = coverage.repeaters.map((id) => id.substring(0, id.length >= 2 ? 2 : id.length)).toSet().toList()..sort();
    final repeaterText = uniquePrefixes.isNotEmpty ? uniquePrefixes.join(', ') : 'None';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Coverage Square Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Samples: ', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(totalDisplay),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Success Rate: ', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(reliabilityText),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Received: ', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                Flexible(child: Text(receivedDisplay)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Lost: ', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                Flexible(child: Text(lostDisplay)),
              ],
            ),
            if (coverage.received > 0)
              const SizedBox(height: 8),
            if (coverage.received > 0)
              Row(
                children: [
                  const Text('Repeaters Heard: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${uniquePrefixes.length}'),
                ],
              ),
            if (coverage.received > 0)
              const SizedBox(height: 4),
            if (coverage.received > 0)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Repeater IDs: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(
                    child: Text(
                      repeaterText,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showRepeatersDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Nearby Repeaters (${_repeaters.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _repeaters.length,
            itemBuilder: (context, index) {
              final repeater = _repeaters[index];
              return ListTile(
                leading: const Icon(Icons.cell_tower, color: Colors.purple),
                title: Text(repeater.name ?? 'Repeater ${repeater.id}'),
                subtitle: Text(
                  '${repeater.position.latitude.toStringAsFixed(4)}, '
                  '${repeater.position.longitude.toStringAsFixed(4)}'
                  '${repeater.snr != null ? " • SNR: ${repeater.snr} dB" : ""}'
                  '${repeater.rssi != null ? " • RSSI: ${repeater.rssi} dBm" : ""}',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showRepeaterInfo(repeater);
                },
                trailing: IconButton(
                  icon: const Icon(Icons.location_searching),
                  onPressed: () {
                    Navigator.pop(context);
                    _mapController.move(repeater.position, 15.0);
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadSamples() async {
    // Check if multiple sites are selected
    final selectedSites = await _uploadService.getSelectedEndpoints();
    final endpoints = await _uploadService.getUploadEndpoints();
    
    // Track progress state
    int currentBatch = 0;
    int totalBatches = 0;
    String currentSite = '';
    
    // Show loading dialog with progress
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  currentSite.isNotEmpty
                      ? 'Uploading to $currentSite...'
                      : 'Uploading samples...',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (totalBatches > 1)
                  Text(
                    'Batch $currentBatch of $totalBatches',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
          );
        },
      ),
    );

    try {
      // Build repeater names map from discovered repeaters and LoRa service
      final repeaterNames = <String, String>{};
      
      // Add names from discovered repeaters
      for (final repeater in _repeaters) {
        if (repeater.name != null) {
          repeaterNames[repeater.id] = repeater.name!;
        }
      }
      
      // Add names from LoRa service contact cache
      final loraService = _locationService.loraCompanion;
      for (final contact in loraService.discoveredRepeaters) {
        if (contact.name != null && !repeaterNames.containsKey(contact.id)) {
          repeaterNames[contact.id] = contact.name!;
        }
      }
      
      Map<String, UploadResult> results;
      
      // Always use multi-site upload path if any endpoints are configured
      // This ensures custom endpoints work correctly
      if (selectedSites.isNotEmpty && endpoints.isNotEmpty) {
        results = await _uploadService.uploadToSelectedEndpoints(
          repeaterNames: repeaterNames,
          onProgress: (siteName, current, total) {
            if (mounted) {
              currentSite = siteName;
              currentBatch = current;
              totalBatches = total;
            }
          },
        );
      } else {
        // Fallback for backward compatibility (shouldn't happen)
        final result = await _uploadService.uploadAllSamples(
          repeaterNames: repeaterNames,
          onProgress: (current, total) {
            if (mounted) {
              currentBatch = current;
              totalBatches = total;
            }
          },
        );
        results = {'Upload': result};
      }
      
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        
        // Show results
        final allSuccess = results.values.every((r) => r.success);
        final successCount = results.values.where((r) => r.success).length;
        
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(allSuccess ? 'Upload Complete' : 'Upload Results'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (results.length > 1)
                  Text('Uploaded to $successCount of ${results.length} sites'),
                const SizedBox(height: 8),
                ...results.entries.map((entry) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          entry.value.success ? Icons.check_circle : Icons.error,
                          color: entry.value.success ? Colors.green : Colors.red,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.key,
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              if (!entry.value.success)
                                Text(
                                  entry.value.message,
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        _showSnackBar('Upload error: $e');
      }
    }
  }

  Future<void> _manageUploadSites() async {
    final endpoints = await _uploadService.getUploadEndpoints();
    final selectedNames = await _uploadService.getSelectedEndpoints();
    
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) => Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: ListView(
                controller: scrollController,
                children: [
                  Row(
                    children: const [
                      Text(
                        'Manage Upload Sites',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Select which sites to upload to:',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  if (endpoints.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('No upload sites configured'),
                    )
                  else
                    ...endpoints.map((endpoint) {
                      final isSelected = selectedNames.contains(endpoint.name);
                      return CheckboxListTile(
                        title: Text(endpoint.name),
                        subtitle: Text(
                          endpoint.url,
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: isSelected,
                        onChanged: (value) {
                          setModalState(() {
                            if (value == true) {
                              if (!selectedNames.contains(endpoint.name)) {
                                selectedNames.add(endpoint.name);
                              }
                            } else {
                              selectedNames.remove(endpoint.name);
                            }
                          });
                        },
                        secondary: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20, color: Colors.blue),
                              onPressed: () async {
                                final edited = await _showEditEndpointDialog(endpoint);
                                if (edited != null) {
                                  final index = endpoints.indexOf(endpoint);
                                  if (index != -1) {
                                    // Update selected names if name changed
                                    if (selectedNames.contains(endpoint.name)) {
                                      selectedNames.remove(endpoint.name);
                                      selectedNames.add(edited.name);
                                    }
                                    endpoints[index] = edited;
                                    await _uploadService.setUploadEndpoints(endpoints);
                                    await _uploadService.setSelectedEndpoints(selectedNames);
                                    setModalState(() {});
                                  }
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20, color: Colors.red),
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Delete Site'),
                                    content: Text('Delete "${endpoint.name}"?'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, true),
                                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                                        child: const Text('Delete'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  endpoints.remove(endpoint);
                                  selectedNames.remove(endpoint.name);
                                  await _uploadService.setUploadEndpoints(endpoints);
                                  await _uploadService.setSelectedEndpoints(selectedNames);
                                  setModalState(() {});
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final result = await _showAddEndpointDialog();
                          if (result != null) {
                            endpoints.add(result);
                            selectedNames.add(result.name);
                            await _uploadService.setUploadEndpoints(endpoints);
                            await _uploadService.setSelectedEndpoints(selectedNames);
                            setModalState(() {});
                          }
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Add Site'),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await _uploadService.setSelectedEndpoints(selectedNames);
                          Navigator.pop(context);
                          _showSnackBar('Upload sites updated');
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  
  Future<void> _shareCoverageMap() async {
    try {
      // Hide UI elements for clean screenshot
      setState(() { _hideUIForScreenshot = true; });
      await Future.delayed(const Duration(milliseconds: 300));
      
      final Uint8List? imageBytes = await _screenshotController.capture(pixelRatio: 2.0);
      
      setState(() { _hideUIForScreenshot = false; });
      
      if (imageBytes == null) {
        _showSnackBar('Failed to capture screenshot');
        return;
      }
      
      // Build stats text
      final pingSamples = _samples.where((s) => s.pingSuccess != null).toList();
      final successCount = pingSamples.where((s) => s.pingSuccess == true).length;
      final failCount = pingSamples.where((s) => s.pingSuccess == false).length;
      final totalPings = successCount + failCount;
      final successRate = totalPings > 0 ? ((successCount / totalPings) * 100).toStringAsFixed(0) : 'N/A';
      final coverageCount = _aggregationResult?.coverages.length ?? 0;
      
      final statsText = 'MeshCore Wardrive Coverage Map\n'
          '📍 ${_samples.length} samples • $coverageCount coverage areas\n'
          '✅ $successCount success • ❌ $failCount failed • $successRate% rate\n'
          '🔁 ${_repeaters.length} repeaters discovered';
      
      // Save temp file and share
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/meshcore_coverage_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(imageBytes);
      
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'MeshCore Wardrive Coverage',
        text: statsText,
      );
    } catch (e) {
      setState(() { _hideUIForScreenshot = false; });
      _showSnackBar('Share failed: $e');
    }
  }
  
  void _showRepeaterFilterPicker() {
    // Collect all known repeater IDs from coverage data and discovered repeaters
    final Set<String> knownIds = {};
    if (_aggregationResult != null) {
      for (final cov in _aggregationResult!.coverages) {
        knownIds.addAll(cov.repeaters);
      }
    }
    for (final r in _repeaters) {
      knownIds.add(r.id);
    }
    
    if (knownIds.isEmpty) {
      _showSnackBar('No repeaters found yet - do some wardriving first!');
      return;
    }
    
    final sortedIds = knownIds.toList()..sort();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Filter by Repeater'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: sortedIds.length,
            itemBuilder: (context, index) {
              final id = sortedIds[index];
              final displayId = (id.length > 8 ? id.substring(0, 8) : id).toUpperCase();
              // Find matching repeater for name
              final repeater = _repeaters.cast<Repeater?>().firstWhere(
                (r) => r!.id == id, orElse: () => null,
              );
              final name = repeater?.name;
              final isSelected = _includeOnlyRepeaters == id;
              
              return ListTile(
                leading: Icon(
                  Icons.cell_tower,
                  color: isSelected ? Colors.blue : Colors.purple,
                ),
                title: Text(name ?? 'Repeater $displayId'),
                subtitle: Text(displayId, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                trailing: isSelected ? const Icon(Icons.check_circle, color: Colors.blue) : null,
                onTap: () async {
                  Navigator.pop(context);
                  setState(() { _includeOnlyRepeaters = id; });
                  await _settingsService.setIncludeOnlyRepeaters(id);
                  _loadSamples();
                  _showSnackBar('Showing coverage from $displayId');
                },
              );
            },
          ),
        ),
        actions: [
          if (_includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty)
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                setState(() { _includeOnlyRepeaters = null; });
                await _settingsService.setIncludeOnlyRepeaters(null);
                _loadSamples();
                _showSnackBar('Repeater filter cleared');
              },
              child: const Text('Clear Filter', style: TextStyle(color: Colors.red)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
  
  void _findCoverageGaps() {
    if (_aggregationResult == null || _aggregationResult!.coverages.isEmpty) {
      _showSnackBar('No coverage data yet - do some wardriving first!');
      return;
    }
    
    // Find coverage areas with low/zero success rate
    final gaps = <Coverage>[];
    for (final cov in _aggregationResult!.coverages) {
      final total = cov.received + cov.lost;
      if (total == 0) continue; // Skip GPS-only areas
      final successRate = cov.received / total;
      if (successRate < 0.3) { // Less than 30% success = gap
        gaps.add(cov);
      }
    }
    
    // Sort by success rate (worst first)
    gaps.sort((a, b) {
      final aRate = a.received / (a.received + a.lost);
      final bRate = b.received / (b.received + b.lost);
      return aRate.compareTo(bRate);
    });
    
    if (gaps.isEmpty) {
      _showSnackBar('No coverage gaps found! All areas have >30% success rate.');
      return;
    }
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Coverage Gaps (${gaps.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: gaps.length,
            itemBuilder: (context, index) {
              final gap = gaps[index];
              final total = gap.received + gap.lost;
              final rate = total > 0 ? ((gap.received / total) * 100).toStringAsFixed(0) : '0';
              return ListTile(
                leading: Icon(
                  Icons.warning,
                  color: double.parse(rate) == 0 ? Colors.red : Colors.orange,
                ),
                title: Text('$rate% success rate'),
                subtitle: Text(
                  '${gap.position.latitude.toStringAsFixed(4)}, '
                  '${gap.position.longitude.toStringAsFixed(4)}\n'
                  '${gap.received.toStringAsFixed(1)} received / ${gap.lost.toStringAsFixed(1)} lost',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _mapController.move(gap.position, 15.0);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<UploadEndpoint?> _showEditEndpointDialog(UploadEndpoint existing) async {
    final nameController = TextEditingController(text: existing.name);
    final urlController = TextEditingController(text: existing.url);
    
    return await showDialog<UploadEndpoint>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Upload Site'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Site Name',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'API URL',
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.isNotEmpty && urlController.text.isNotEmpty) {
                Navigator.pop(
                  context,
                  UploadEndpoint(
                    name: nameController.text,
                    url: urlController.text,
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<UploadEndpoint?> _showAddEndpointDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    
    return await showDialog<UploadEndpoint>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Upload Site'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Site Name',
                hintText: 'e.g., My Personal Map',
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'API URL',
                hintText: 'https://your-site.pages.dev/api/samples',
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.isNotEmpty && urlController.text.isNotEmpty) {
                Navigator.pop(
                  context,
                  UploadEndpoint(
                    name: nameController.text,
                    url: urlController.text,
                  ),
                );
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
  
}
