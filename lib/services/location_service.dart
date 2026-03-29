import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/models.dart';
import 'database_service.dart';
import 'lora_companion_service.dart';
import '../utils/geohash_utils.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'persistent_debug_logger.dart';
import 'settings_service.dart';
import 'ducting_service.dart';
import 'carpeater_service.dart';

class LocationService {
  final DatabaseService _dbService = DatabaseService();
  final LoRaCompanionService _loraCompanion = LoRaCompanionService();
  final PersistentDebugLogger _logger = PersistentDebugLogger();
  final SettingsService _settings = SettingsService();
  final DuctingService _ductingService = DuctingService();
  
  LocationService() {
    _carpeaterService = CarpeaterService(_loraCompanion, _settings);
  }
  StreamSubscription<Position>? _positionStreamSubscription;
  bool _isTracking = false;
  bool _autoPingEnabled = false;
  double _pingIntervalMeters = 805.0; // Default 0.5 miles
  LatLng? _lastPingPosition;
  
  // Distance tracking
  double _totalDistanceMeters = 0.0;
  LatLng? _lastPosition;
  
  // Session tracking
  int? _currentSessionId;
  DateTime? _sessionStartTime;
  
  // Stream for broadcasting current position
  final _currentPositionController = StreamController<LatLng>.broadcast();
  Stream<LatLng> get currentPositionStream => _currentPositionController.stream;
  
  // Stream for broadcasting when samples are saved
  final _sampleSavedController = StreamController<void>.broadcast();
  Stream<void> get sampleSavedStream => _sampleSavedController.stream;
  
  // Stream for broadcasting ping events
  final _pingEventController = StreamController<String>.broadcast();
  Stream<String> get pingEventStream => _pingEventController.stream;
  
  // Stream for broadcasting total distance updates
  final _totalDistanceController = StreamController<double>.broadcast();
  Stream<double> get totalDistanceStream => _totalDistanceController.stream;
  
  // Stream for broadcasting current speed (m/s)
  final _speedController = StreamController<double>.broadcast();
  Stream<double> get speedStream => _speedController.stream;
  double _currentSpeedMps = 0.0;
  double get currentSpeedMph => _currentSpeedMps * 2.23694;
  double get currentSpeedKmh => _currentSpeedMps * 3.6;
  
  // Ducting monitoring
  bool _ductingEnabled = false;
  Timer? _ductingFetchTimer;
  
  // Carpeater mode
  late final CarpeaterService _carpeaterService;
  bool _carpeaterModeEnabled = false;
  StreamSubscription<List<Map<String, dynamic>>>? _carpeaterNeighboursSubscription;
  StreamSubscription<void>? _carpeaterDiscoveryStartedSubscription;
  LatLng? _carpeaterDiscoveryPosition; // GPS snapshot at moment of discovery
  
  /// Get ducting service for UI access
  DuctingService get ductingService => _ductingService;
  
  /// Get carpeater service for UI access
  CarpeaterService get carpeaterService => _carpeaterService;
  
  /// Enable or disable ducting monitoring at runtime
  void setDuctingEnabled(bool enabled) {
    _ductingEnabled = enabled;
    if (enabled && _isTracking && _lastPosition != null) {
      // Kick off an initial fetch and start periodic timer
      _ductingService.fetchAndCache(_lastPosition!.latitude, _lastPosition!.longitude);
      _ductingFetchTimer?.cancel();
      _ductingFetchTimer = Timer.periodic(const Duration(minutes: 60), (_) async {
        if (_lastPosition != null) {
          await _ductingService.fetchAndCache(
            _lastPosition!.latitude, _lastPosition!.longitude,
          );
        }
      });
    } else if (!enabled) {
      _ductingFetchTimer?.cancel();
      _ductingFetchTimer = null;
    }
  }
  
  /// Enable or disable Carpeater mode at runtime
  void setCarpeaterMode(bool enabled) {
    _carpeaterModeEnabled = enabled;
    _logger.logServiceEvent('Carpeater mode ${enabled ? "enabled" : "disabled"}');
  }

  /// Check if location permissions are granted
  Future<bool> checkPermissions() async {
    LocationPermission permission = await Geolocator.checkPermission();
    await _logger.logPermission('Location', permission.toString());
    
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      await _logger.logPermission('Location (after request)', permission.toString());
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      await _logger.logPermission('Location', 'DENIED_FOREVER');
      return false;
    }

    return true;
  }

  /// Check if location services are enabled
  Future<bool> isLocationServiceEnabled() async {
    return await Geolocator.isLocationServiceEnabled();
  }

  /// Get current position once
  Future<LatLng?> getCurrentPosition() async {
    try {
      final hasPermission = await checkPermissions();
      if (!hasPermission) return null;

      final isEnabled = await isLocationServiceEnabled();
      if (!isEnabled) return null;

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: false
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 0,
                forceLocationManager: true,
              )
            : const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 0,
              ),
      );

      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      print('Error getting current position: $e');
      return null;
    }
  }

  /// Initialize foreground service
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'meshcore_wardrive_location',
        channelName: 'MeshCore Wardrive Location Tracking',
        channelDescription: 'This notification appears when location tracking is active',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000), // Update every 5 seconds
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Start tracking location
  Future<bool> startTracking() async {
    await _logger.init();
    await _logger.logServiceEvent('startTracking() called');
    
    if (_isTracking) {
      await _logger.logServiceEvent('Already tracking - returning early');
      return true;
    }

    final hasPermission = await checkPermissions();
    if (!hasPermission) {
      await _logger.logError('Permissions', 'Location permission not granted');
      return false;
    }

    final isEnabled = await isLocationServiceEnabled();
    if (!isEnabled) {
      await _logger.logError('Location Service', 'GPS is disabled');
      return false;
    }

    // Request notification permission for Android 13+
    final notificationStatus = await Permission.notification.request();
    await _logger.logPermission('Notification', notificationStatus.toString());
    if (!notificationStatus.isGranted) {
      print('Notification permission denied - foreground service may not work properly');
    }

    try {
      // Initialize and start foreground service
      _initForegroundTask();
      await _logger.logServiceEvent('Foreground task initialized');
      
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'MeshCore Wardrive',
        notificationText: 'Location tracking active',
        notificationButtons: [
          const NotificationButton(id: 'stop', text: 'Stop Tracking'),
        ],
        callback: null, // We handle location in Flutter, not in service callback
      );
      
      await _logger.logServiceEvent('Foreground service started successfully');
      print('Foreground service started');
      
      final locationSettings = false
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5, // Update every 5 meters
              forceLocationManager: true,
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            );

      _positionStreamSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen(
        (Position position) {
          _handleNewPosition(position);
        },
        onError: (error) {
          _logger.logError('Location Stream', error.toString());
          print('Location stream error: $error');
        },
      );

      await _logger.logLocationEvent('Position stream started with 5m distance filter');

      // Enable wakelock to prevent screen from sleeping and stopping tracking
      await WakelockPlus.enable();
      await _logger.logPowerEvent('Wakelock enabled');
      print('Wakelock enabled - app will stay active during tracking');

      _isTracking = true;
      
      // Reset distance tracking for new session
      _totalDistanceMeters = 0.0;
      _lastPosition = null;
      _totalDistanceController.add(_totalDistanceMeters);
      
      // Start ducting monitoring if enabled (non-blocking)
      _ductingEnabled = await _settings.getShowDucting();
      if (_ductingEnabled) {
        // Fire-and-forget initial fetch using the position stream (don't block with getCurrentPosition)
        _ductingFetchTimer?.cancel();
        _ductingFetchTimer = Timer.periodic(const Duration(minutes: 60), (_) async {
          if (_lastPosition != null) {
            await _ductingService.fetchAndCache(
              _lastPosition!.latitude, _lastPosition!.longitude,
            );
          }
        });
        // Kick off first fetch after a short delay so GPS has time to get a fix
        Future.delayed(const Duration(seconds: 5), () {
          if (_lastPosition != null) {
            _ductingService.fetchAndCache(_lastPosition!.latitude, _lastPosition!.longitude);
          }
        });
      }
      
      // Create a new session record
      _sessionStartTime = DateTime.now();
      try {
        final session = WSession(
          startTime: _sessionStartTime!,
        );
        _currentSessionId = await _dbService.createSession(session);
        await _logger.logServiceEvent('Session created with ID: $_currentSessionId');
      } catch (e) {
        await _logger.logError('Session Create', e.toString());
      }
      
      await _logger.logServiceEvent('Tracking started successfully');
      return true;
    } catch (e) {
      await _logger.logError('Start Tracking', e.toString());
      print('Error starting location tracking: $e');
      return false;
    }
  }

  /// Get LoRa companion service
  LoRaCompanionService get loraCompanion => _loraCompanion;

  /// Enable auto-ping (requires LoRa device to be connected)
  void enableAutoPing() {
    final isConnected = _loraCompanion.isDeviceConnected;
    final connectionType = _loraCompanion.connectionType;
    _logger.logPingEvent('enableAutoPing() called - Device connected: $isConnected, Type: ${connectionType.name}');
    
    if (isConnected) {
      _autoPingEnabled = true;
      _logger.logPingEvent('Auto-ping enabled (interval: ${_pingIntervalMeters}m)');
    } else {
      _logger.logPingEvent('Auto-ping enable FAILED - no device connected');
    }
  }

  /// Disable auto-ping
  void disableAutoPing() {
    _autoPingEnabled = false;
    _logger.logPingEvent('Auto-ping disabled');
  }

  /// Check if auto-ping is enabled
  bool get isAutoPingEnabled => _autoPingEnabled;

  /// Check if ready for auto-ping
  bool get isReadyForAutoPing => 
      _loraCompanion.isDeviceConnected;
  
  /// Set ping interval in meters
  void setPingInterval(double meters) {
    _pingIntervalMeters = meters;
  }
  
  /// Get current ping interval in meters
  double get pingIntervalMeters => _pingIntervalMeters;
  
  /// Get total distance traveled in meters
  double get totalDistanceMeters => _totalDistanceMeters;
  
  /// Get total distance traveled in miles
  double get totalDistanceMiles => _totalDistanceMeters / 1609.34;
  
  /// Get total distance traveled in kilometers
  double get totalDistanceKm => _totalDistanceMeters / 1000.0;

  /// Handle new position from location stream
  void _handleNewPosition(Position position) async {
    final latLng = LatLng(position.latitude, position.longitude);
    await _logger.logLocationEvent('GPS update: ${latLng.latitude}, ${latLng.longitude}, accuracy: ${position.accuracy}m');
    
    // Update speed (filter out invalid negative values)
    _currentSpeedMps = (position.speed >= 0) ? position.speed : 0.0;
    _speedController.add(_currentSpeedMps);
    
    // Calculate distance traveled
    if (_lastPosition != null) {
      final distanceMeters = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        latLng.latitude,
        latLng.longitude,
      );
      _totalDistanceMeters += distanceMeters;
      _totalDistanceController.add(_totalDistanceMeters);
    }
    _lastPosition = latLng;
    
    // Broadcast current position to listeners
    _currentPositionController.add(latLng);

    // Validate location
    if (!GeohashUtils.isValidLocation(latLng)) {
      print('Location outside valid range: $latLng');
      return;
    }

    // Create sample
    final geohash = GeohashUtils.sampleKey(
      position.latitude,
      position.longitude,
    );

    // Check if we should trigger a ping (but don't wait for it)
    final isConnected = _loraCompanion.isDeviceConnected;
    
    // Log detailed debug info on every GPS update when auto-ping is enabled
    if (_autoPingEnabled) {
      await _logger.logPingEvent('Checking ping condition: autoPing=$_autoPingEnabled, deviceConnected=$isConnected, lastPingPos=${_lastPingPosition != null ? "set" : "null"}');
    }
    
    if (_autoPingEnabled && isConnected && !_carpeaterModeEnabled) {
      bool shouldPing = false;
      
      if (_lastPingPosition == null) {
        // First ping
        shouldPing = true;
      } else {
        // Calculate distance from last ping
        final distance = Geolocator.distanceBetween(
          _lastPingPosition!.latitude,
          _lastPingPosition!.longitude,
          latLng.latitude,
          latLng.longitude,
        );
        
        await _logger.logPingEvent('Distance from last ping: ${distance.toStringAsFixed(1)}m (threshold: ${_pingIntervalMeters}m)');
        
        if (distance >= _pingIntervalMeters) {
          shouldPing = true;
        }
      }
      
      if (shouldPing) {
        // Update last ping position immediately to prevent multiple pings
        _lastPingPosition = latLng;
        await _logger.logPingEvent('Auto-ping triggered at ${latLng.latitude}, ${latLng.longitude}');
        
        // Notify UI that ping is starting
        _pingEventController.add('pinging');
        
        // Update foreground notification
        FlutterForegroundTask.updateService(
          notificationTitle: 'MeshCore Wardrive',
          notificationText: 'Pinging...',
        );
        
        // Start ping in background - don't wait for it
        print('Triggering auto-ping via LoRa at ${latLng.latitude}, ${latLng.longitude}');
        _performPingInBackground(latLng, geohash);
        return; // Don't save GPS sample when auto-pinging - wait for ping result
      }
    }

    // Only save GPS sample if auto-ping is disabled or no ping triggered
    // Tag with ducting risk if monitoring is enabled
    String? ductingRisk;
    if (_ductingEnabled) {
      ductingRisk = await _ductingService.getCurrentRisk(DateTime.now());
      if (ductingRisk == DuctingRisk.unknown) ductingRisk = null;
    }
    
    final sample = Sample(
      id: _generateUniqueId(),
      position: latLng,
      timestamp: DateTime.now(),
      path: null,
      geohash: geohash,
      rssi: null,
      snr: null,
      pingSuccess: null, // GPS-only sample (no ping attempted)
      ductingRisk: ductingRisk,
    );

    // Save to database
    try {
      await _dbService.insertSample(sample);
      print('Saved GPS sample: ${sample.id} at ${latLng.latitude}, ${latLng.longitude}');
      // Notify listeners that a sample was saved
      _sampleSavedController.add(null);
    } catch (e) {
      print('Error saving sample: $e');
    }
  }
  
  /// Perform ping in background and update sample when complete
  void _performPingInBackground(LatLng latLng, String geohash) async {
    try {
      // Get user-configured discovery timeout
      final timeoutSeconds = await _settings.getDiscoveryTimeout();
      await _logger.logPingEvent('Sending ping to LoRa device (timeout: ${timeoutSeconds}s)...');
      final pingResult = await _loraCompanion.ping(
        latitude: latLng.latitude,
        longitude: latLng.longitude,
        timeoutSeconds: timeoutSeconds,
      );
      
      final pingSuccess = pingResult.status == PingStatus.success;
      final nodeId = pingResult.nodeId;
      
      await _logger.logPingEvent('Ping result: ${pingResult.status.name}, Node: $nodeId, RSSI: ${pingResult.rssi}, SNR: ${pingResult.snr}');
      print('Ping complete: ${pingResult.status.name}, Node: $nodeId, RSSI: ${pingResult.rssi}, SNR: ${pingResult.snr}');
      
      // Update notification with result
      final shortId = (nodeId != null && nodeId.isNotEmpty)
          ? (nodeId.length > 8 ? nodeId.substring(0, 8).toUpperCase() : nodeId.toUpperCase())
          : 'repeater';
      final resultText = pingSuccess ? '✅ Heard by $shortId' : '❌ No response';
      FlutterForegroundTask.updateService(
        notificationTitle: 'MeshCore Wardrive',
        notificationText: resultText,
      );
      
      // Notify UI
      _pingEventController.add(pingSuccess ? 'success' : 'failed');
      
      // Reset notification after 3 seconds
      Future.delayed(const Duration(seconds: 3), () {
        FlutterForegroundTask.updateService(
          notificationTitle: 'MeshCore Wardrive',
          notificationText: 'Location tracking active',
        );
      });
      
      // Tag with ducting risk if monitoring is enabled
      String? ductingRisk;
      if (_ductingEnabled) {
        ductingRisk = await _ductingService.getCurrentRisk(DateTime.now());
        if (ductingRisk == DuctingRisk.unknown) ductingRisk = null;
      }
      
      // Create a new sample with ping results
      final sample = Sample(
        id: _generateUniqueId(),
        position: latLng,
        timestamp: DateTime.now(),
        path: nodeId,
        geohash: geohash,
        rssi: pingResult.rssi,
        snr: pingResult.snr,
        pingSuccess: pingSuccess,
        responseTimeMs: pingResult.responseTimeMs,
        ductingRisk: ductingRisk,
      );
      
      // Save ping result as new sample
      await _dbService.insertSample(sample);
      print('Saved ping result: ${sample.id}');
      // Notify listeners
      _sampleSavedController.add(null);
    } catch (e) {
      await _logger.logError('Background Ping', e.toString());
      print('Error during background ping: $e');
      // Save failed ping result
      final sample = Sample(
        id: _generateUniqueId(),
        position: latLng,
        timestamp: DateTime.now(),
        path: null,
        geohash: geohash,
        rssi: null,
        snr: null,
        pingSuccess: false,
      );
      await _dbService.insertSample(sample);
      // Notify listeners
      _sampleSavedController.add(null);
    }
  }

  /// Stop tracking location
  Future<void> stopTracking() async {
    await _logger.logServiceEvent('stopTracking() called');
    
    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    
    // Stop ducting monitoring
    _ductingFetchTimer?.cancel();
    _ductingFetchTimer = null;
    
    // Stop Carpeater mode
    _carpeaterNeighboursSubscription?.cancel();
    _carpeaterDiscoveryStartedSubscription?.cancel();
    _carpeaterService.stop();
    
    // Stop foreground service
    await FlutterForegroundTask.stopService();
    await _logger.logServiceEvent('Foreground service stopped');
    
    // Disable wakelock when tracking stops
    await WakelockPlus.disable();
    await _logger.logPowerEvent('Wakelock disabled');
    print('Wakelock disabled');
    
    // Finalize session
    if (_currentSessionId != null && _sessionStartTime != null) {
      try {
        final endTime = DateTime.now();
        final counts = await _dbService.getSessionSampleCounts(_sessionStartTime!, endTime);
        final session = WSession(
          id: _currentSessionId,
          startTime: _sessionStartTime!,
          endTime: endTime,
          distanceMeters: _totalDistanceMeters,
          sampleCount: counts['total'] ?? 0,
          pingCount: counts['pings'] ?? 0,
          successCount: counts['successes'] ?? 0,
        );
        await _dbService.updateSession(session);
        await _logger.logServiceEvent('Session $_currentSessionId finalized: ${counts['total']} samples, ${counts['pings']} pings, ${counts['successes']} successes, ${_totalDistanceMeters.toStringAsFixed(0)}m');
      } catch (e) {
        await _logger.logError('Session Finalize', e.toString());
      }
      _currentSessionId = null;
      _sessionStartTime = null;
    }
    
    _isTracking = false;
    await _logger.logServiceEvent('Tracking stopped successfully');
  }

  /// Check if currently tracking
  bool get isTracking => _isTracking;

  /// Get all recorded samples
  Future<List<Sample>> getAllSamples() async {
    return await _dbService.getAllSamples();
  }

  /// Get sample count
  Future<int> getSampleCount() async {
    return await _dbService.getSampleCount();
  }

  /// Clear all samples
  Future<void> clearAllSamples() async {
    await _dbService.deleteAllSamples();
  }

  /// Export samples as JSON
  Future<List<Map<String, dynamic>>> exportSamples() async {
    return await _dbService.exportSamples();
  }

  /// Import samples from JSON file (returns count of imported samples)
  Future<int> importSamples(List<Map<String, dynamic>> jsonData) async {
    return await _dbService.importSamples(jsonData);
  }

  /// Get the debug log file path
  String? get debugLogPath => _logger.logFilePath;
  
  /// Generate a unique ID for samples
  String _generateUniqueId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(999999).toString().padLeft(6, '0');
    return '${timestamp}_$random';
  }

  /// Start Carpeater discovery and subscribe to results
  Future<bool> startCarpeater() async {
    // Subscribe to discovery started (snapshot GPS position)
    _carpeaterDiscoveryStartedSubscription = _carpeaterService.discoveryStartedStream.listen((_) {
      _carpeaterDiscoveryPosition = _lastPosition;
      _pingEventController.add('pinging');
    });
    
    // Subscribe to neighbour results
    _carpeaterNeighboursSubscription = _carpeaterService.neighboursStream.listen(_onCarpeaterNeighbours);
    
    final started = await _carpeaterService.start();
    if (!started) {
      _carpeaterDiscoveryStartedSubscription?.cancel();
      _carpeaterNeighboursSubscription?.cancel();
    }
    return started;
  }
  
  /// Handle Carpeater neighbour results — save as samples
  void _onCarpeaterNeighbours(List<Map<String, dynamic>> neighbours) async {
    final position = _carpeaterDiscoveryPosition ?? _lastPosition;
    if (position == null) return;
    
    final geohash = GeohashUtils.sampleKey(position.latitude, position.longitude);
    
    // Get ducting risk if enabled
    String? ductingRisk;
    if (_ductingEnabled) {
      ductingRisk = await _ductingService.getCurrentRisk(DateTime.now());
      if (ductingRisk == DuctingRisk.unknown) ductingRisk = null;
    }
    
    if (neighbours.isEmpty) {
      // Dead zone — repeater heard nobody
      final sample = Sample(
        id: _generateUniqueId(),
        position: position,
        timestamp: DateTime.now(),
        path: _carpeaterService.targetRepeaterId,
        geohash: geohash,
        pingSuccess: false,
        ductingRisk: ductingRisk,
      );
      await _dbService.insertSample(sample);
      _pingEventController.add('failed');
    } else {
      // Save one sample per neighbour
      for (final n in neighbours) {
        final pubkey = n['pubkey'] as String?;
        final snr = (n['snr'] as num?)?.toInt();
        final repeaterId = pubkey != null && pubkey.length >= 8
            ? pubkey.substring(0, 8)
            : pubkey;
        
        final sample = Sample(
          id: _generateUniqueId(),
          position: position,
          timestamp: DateTime.now(),
          path: repeaterId,
          geohash: geohash,
          snr: snr,
          pingSuccess: true,
          ductingRisk: ductingRisk,
        );
        await _dbService.insertSample(sample);
      }
      _pingEventController.add('success');
    }
    
    _sampleSavedController.add(null);
    
    FlutterForegroundTask.updateService(
      notificationTitle: 'MeshCore Wardrive',
      notificationText: neighbours.isEmpty
          ? 'Carpeater: No neighbours'
          : 'Carpeater: ${neighbours.length} neighbours found',
    );
    Future.delayed(const Duration(seconds: 3), () {
      FlutterForegroundTask.updateService(
        notificationTitle: 'MeshCore Wardrive',
        notificationText: 'Carpeater mode active',
      );
    });
  }

  /// Dispose resources
  void dispose() {
    stopTracking();
    _logger.close();
    _currentPositionController.close();
    _sampleSavedController.close();
    _pingEventController.close();
    _totalDistanceController.close();
    _speedController.close();
    _carpeaterNeighboursSubscription?.cancel();
    _carpeaterDiscoveryStartedSubscription?.cancel();
    _carpeaterService.dispose();
    _loraCompanion.dispose();
  }
}
