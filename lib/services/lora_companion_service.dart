import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:latlong2/latlong.dart';
import 'debug_log_service.dart';
import 'meshcore_protocol.dart';
import '../models/models.dart';

enum ConnectionType { bluetooth, none }
enum PingStatus { success, failed, timeout, pending }

class PingResult {
  final DateTime timestamp;
  final PingStatus status;
  final int? rssi;
  final int? snr;
  final String? nodeId;
  final double? latitude;
  final double? longitude;
  final String? error;

  PingResult({
    required this.timestamp,
    required this.status,
    this.rssi,
    this.snr,
    this.nodeId,
    this.latitude,
    this.longitude,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'status': status.name,
        'rssi': rssi,
        'snr': snr,
        'nodeId': nodeId,
        'latitude': latitude,
        'longitude': longitude,
        'error': error,
      };
}

class LoRaCompanionService {
  // LoRa device connection
  ConnectionType _connectionType = ConnectionType.none;
  BluetoothDevice? _bluetoothDevice;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription? _deviceSubscription;
  String? _deviceName; // Connected device's advertised name
  
  // State
  final _pingResultController = StreamController<PingResult>.broadcast();
  final _pendingPings = <int, Completer<PingResult>>{}; // tag -> completer
  final Map<int, List<Map<String, dynamic>>> _pingResponses = {}; // tag -> list of responses
  final _random = Random();
  int? _batteryPercent;
  final _batteryController = StreamController<int?>.broadcast();
  StreamSubscription? _connectionStateSubscription;
  
  
  // Track pending contact requests
  final Set<String> _pendingContactRequests = {};
  
  // Repeater scanning
  List<Repeater> _discoveredRepeaters = []; // Repeaters that have echoed during wardriving
  Map<String, Repeater> _repeaterContactCache = {}; // All known repeater contacts (from scan)
  Map<String, int> _nodeTypes = {}; // Map of node ID -> advType (1=companion, 2=repeater, 3=room)
  Completer<List<Repeater>>? _scanCompleter;
  Map<String, Repeater> _knownRepeaters = {}; // Map of repeater ID -> location from internet map
  
  // Track recent advertisements for echo correlation
  final Map<String, DateTime> _recentAdvertisements = {}; // repeaterId -> last seen time
  final Duration _advertCorrelationWindow = const Duration(minutes: 5); // Window for correlating adverts with echoes
  
  // Throttle contact lookups to avoid dumping full list repeatedly
  final Map<String, DateTime> _lastContactRequestAt = {}; // keyPrefix -> time
  Duration _contactRequestCooldown = const Duration(minutes: 5);
  
  
  // Settings
  String? _ignoredRepeaterPrefix;
  
  // Secure storage
  final _secureStorage = const FlutterSecureStorage();
  final _debugLog = DebugLogService();
  final _protocol = MeshCoreProtocol();

  bool get isDeviceConnected => _connectionType != ConnectionType.none;
  ConnectionType get connectionType => _connectionType;
  String? get deviceName => _deviceName;
  Stream<PingResult> get pingResults => _pingResultController.stream;
  int? get batteryPercent => _batteryPercent;
  Stream<int?> get batteryStream => _batteryController.stream;

  /// Set repeater prefix to ignore (e.g., your mobile repeater)
  void setIgnoredRepeaterPrefix(String? prefix) {
    _ignoredRepeaterPrefix = prefix;
  }
  
  /// Check if a node ID is a companion device (not a repeater)
  /// Uses cached node type from contact info (advType: 1=companion, 2=repeater, 3=room)
  bool _isCompanionNode(String nodeId) {
    final nodeType = _nodeTypes[nodeId];
    if (nodeType == null) return false; // Unknown type, allow it
    return nodeType == ADV_TYPE_CHAT; // Type 1 = companion/chat device
  }
  
  
  /// Get device name for display (from BT device)
  String getDeviceName() {
    if (_bluetoothDevice != null) {
      return _bluetoothDevice!.platformName.isNotEmpty 
          ? _bluetoothDevice!.platformName 
          : _bluetoothDevice!.remoteId.toString();
    }
    return 'Unknown';
  }

  // ============================================================================
  // DEVICE CONNECTION - BLUETOOTH
  // ============================================================================

  /// Scan for Bluetooth LoRa devices
  Future<List<BluetoothDevice>> scanBluetoothDevices({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final devices = <BluetoothDevice>[];
    
    try {
      if (await FlutterBluePlus.isSupported == false) {
        throw Exception('Bluetooth not supported');
      }

      await FlutterBluePlus.startScan(timeout: timeout);

      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          // Look for LoRa/Meshtastic/WhisperOS devices
          final name = r.device.platformName.toLowerCase();
          if (name.contains('lora') ||
              name.contains('meshtastic') ||
              name.contains('meshcore') ||
              name.contains('whisper') ||
              name.contains('t-beam') ||
              name.contains('heltec')) {
            if (!devices.contains(r.device)) {
              devices.add(r.device);
            }
          }
        }
      });

      await Future.delayed(timeout);
      await subscription.cancel();
      await FlutterBluePlus.stopScan();

      return devices;
    } catch (e) {
      print('Error scanning Bluetooth: $e');
      return [];
    }
  }

  /// Connect to LoRa device via Bluetooth
  Future<bool> connectBluetooth(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 15));
      _bluetoothDevice = device;

      List<BluetoothService> services = await device.discoverServices();

      // Find UART service (Nordic UART or similar)
      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase().contains('6e40') ||
            service.uuid.toString().toLowerCase().contains('ffe0')) {
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.properties.write) _txCharacteristic = char;
            if (char.properties.notify) {
              _rxCharacteristic = char;
              await char.setNotifyValue(true);
              _deviceSubscription = char.lastValueStream.listen((value) {
                _handleDeviceData(Uint8List.fromList(value));
              });
            }
          }
        }
        
        // Try to read battery service (standard BLE Battery Service)
        // UUID: 0x180F (Battery Service), 0x2A19 (Battery Level Characteristic)
        if (service.uuid.toString().toLowerCase() == '0000180f-0000-1000-8000-00805f9b34fb') {
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.uuid.toString().toLowerCase() == '00002a19-0000-1000-8000-00805f9b34fb') {
              try {
                // Store battery characteristic for periodic reading
                _batteryCharacteristic = char;
                
                // Try to read battery level
                final value = await char.read();
                if (value.isNotEmpty) {
                  _batteryPercent = value[0];
                  _batteryController.add(_batteryPercent);
                  print('Battery level: $_batteryPercent%');
                }
                
                // Subscribe to battery updates if supported
                if (char.properties.notify) {
                  await char.setNotifyValue(true);
                  char.lastValueStream.listen((value) {
                    if (value.isNotEmpty) {
                      _batteryPercent = value[0];
                      _batteryController.add(_batteryPercent);
                      print('Battery level updated: $_batteryPercent%');
                    }
                  });
                }
              } catch (e) {
                print('Could not read battery level: $e');
              }
            }
          }
        }
      }

      if (_txCharacteristic != null && _rxCharacteristic != null) {
        _connectionType = ConnectionType.bluetooth;
        _deviceName = device.platformName.isNotEmpty 
            ? device.platformName 
            : device.remoteId.toString();
        print('Connected to LoRa device via Bluetooth');
        
        // Monitor connection state for disconnection
        _connectionStateSubscription = device.connectionState.listen((state) {
          print('Bluetooth connection state: $state');
          if (state == BluetoothConnectionState.disconnected) {
            _handleBluetoothDisconnection();
          }
        });
        
        // Enable BLE mode in protocol parser (unwrapped frames)
        _protocol.setBLEMode(true);
        _debugLog.logInfo('Protocol set to BLE mode (unwrapped frames)');
        
        // Start periodic battery check if not already getting updates
        _startBatteryMonitoring();
        
        // Send handshake
        await Future.delayed(const Duration(milliseconds: 500));
        final handshake = _createCommandForDevice(CMD_APP_START);
        await _sendBinaryToDevice(handshake);
        _debugLog.logInfo('Sent handshake');

      // Load full contact list so repeaters appear on the map
      await Future.delayed(const Duration(milliseconds: 150));
      await _requestAllContacts();
      
      return true;
      }

      return false;
    } catch (e) {
      print('Bluetooth connection error: $e');
      return false;
    }
  }

  // ============================================================================
  // MQTT CONNECTION - REMOVED
  // ============================================================================

  // ============================================================================
  // REPEATER SCANNING
  // ============================================================================

  /// Scan for nearby repeaters by requesting all contacts
  /// Loads repeater contacts from the device's contact list
  Future<List<Repeater>> scanForRepeaters({int timeoutSeconds = 5}) async {
    if (!isDeviceConnected) {
      _debugLog.logError('Cannot scan - LoRa device not connected');
      return [];
    }

    try {
      _debugLog.logInfo('🔍 Loading repeater contacts from device...');
      _repeaterContactCache.clear();
      _scanCompleter = Completer<List<Repeater>>();

      // Request all contacts from device
      await _requestAllContacts();
      
      _debugLog.logInfo('Requested contact list');
      print('📡 Loading repeater contacts...');

      // Wait for contacts to be loaded
      Timer(Duration(seconds: timeoutSeconds), () {
        if (_scanCompleter != null && !_scanCompleter!.isCompleted) {
          _debugLog.logInfo('✅ Scan complete: Cached ${_repeaterContactCache.length} contact(s)');
          print('✅ Cached ${_repeaterContactCache.length} repeater contact(s)');
          _scanCompleter!.complete(List.from(_repeaterContactCache.values));
          _scanCompleter = null;
        }
      });

      return await _scanCompleter!.future;
    } catch (e) {
      _debugLog.logError('Repeater scan error: $e');
      return [];
    }
  }

  List<Repeater> get discoveredRepeaters => List.unmodifiable(_discoveredRepeaters);
  
  /// Match a 2-character hex prefix to full repeater ID(s)
  /// Returns the first matching repeater from known repeaters
  String? matchRepeaterPrefix(String prefix) {
    if (prefix.length != 2) return null;
    
    final upperPrefix = prefix.toUpperCase();
    
    // Check known repeaters first
    for (final repeaterId in _knownRepeaters.keys) {
      if (repeaterId.toUpperCase().startsWith(upperPrefix)) {
        return repeaterId;
      }
    }
    
    // Check contact cache
    for (final repeaterId in _repeaterContactCache.keys) {
      if (repeaterId.toUpperCase().startsWith(upperPrefix)) {
        return repeaterId;
      }
    }
    
    // Check discovered repeaters
    for (final repeater in _discoveredRepeaters) {
      if (repeater.id.toUpperCase().startsWith(upperPrefix)) {
        return repeater.id;
      }
    }
    
    return null; // No match found
  }
  
  /// Get repeater location by ID (from cache or fetch)
  /// If repeaterId is 2 characters, attempt to match it to a full ID first
  Repeater? getRepeaterLocation(String repeaterId) {
    // If it's a 2-char prefix, try to expand it first
    String? fullId = repeaterId;
    if (repeaterId.length == 2) {
      fullId = matchRepeaterPrefix(repeaterId);
      if (fullId == null) return null; // No match found
    }
    
    return _knownRepeaters[fullId] ?? _repeaterContactCache[fullId];
  }
  
  // Internet map API methods removed - MQTT dependencies

  /// Parse repeater information from LoRa device output
  void _parseRepeaterLine(String line) {
    try {
      // Skip empty lines and common noise
      if (line.trim().isEmpty || line.length < 5) return;
      
      // Try to parse node information
      // Common formats:
      // Meshtastic: "Node: !1a2b3c4d Name: Repeater1 Lat: 47.123 Lon: -122.456 SNR: 8.5 dB"
      // MeshCore: Different formats - we'll try to detect patterns
      
      // Look for hex IDs (common in mesh networks)
      final hexIdMatch = RegExp(r'([0-9a-fA-F]{4,16})').firstMatch(line);
      
      // Look for coordinates in any format
      double? lat;
      double? lon;
      
      // Try various coordinate formats
      final patterns = [
        RegExp(r'lat[:\s=]*(-?\d+\.\d+)[,\s]+lon[:\s=]*(-?\d+\.\d+)', caseSensitive: false),
        RegExp(r'\(\s*(-?\d+\.\d+)\s*,\s*(-?\d+\.\d+)\s*\)'),
        RegExp(r'(-?\d+\.\d{4,})\s*,\s*(-?\d+\.\d{4,})'),
      ];
      
      for (final pattern in patterns) {
        final match = pattern.firstMatch(line);
        if (match != null) {
          lat = double.tryParse(match.group(1)!);
          lon = double.tryParse(match.group(2)!);
          if (lat != null && lon != null) break;
        }
      }
      
      // If we found coordinates, try to extract other info
      if (lat != null && lon != null) {
        // Use hex ID if found, or generate from line
        String nodeId = hexIdMatch?.group(1) ?? line.hashCode.toRadixString(16);
        
        // Try to extract name
        String? name;
        final namePatterns = [
          RegExp(r'[Nn]ame[:\s]+([A-Za-z0-9_-]+)'),
          RegExp(r'!\w+\s+([A-Za-z0-9_-]+)'),
        ];
        
        for (final pattern in namePatterns) {
          final match = pattern.firstMatch(line);
          if (match != null) {
            name = match.group(1);
            break;
          }
        }
        
        // Extract SNR
        int? snr;
        final snrMatch = RegExp(r'[Ss][Nn][Rr][:\s=]*(-?\d+(?:\.\d+)?)').firstMatch(line);
        if (snrMatch != null) {
          snr = double.tryParse(snrMatch.group(1)!)?.toInt();
        }
        
        // Extract RSSI
        int? rssi;
        final rssiMatch = RegExp(r'[Rr][Ss][Ss][Ii][:\s=]*(-?\d+)').firstMatch(line);
        if (rssiMatch != null) {
          rssi = int.tryParse(rssiMatch.group(1)!);
        }
        
        final repeater = Repeater(
          id: nodeId,
          position: LatLng(lat, lon),
          name: name,
          snr: snr,
          rssi: rssi,
          timestamp: DateTime.now(),
        );
        
        // Avoid duplicates based on position (within 10 meters)
        final isDuplicate = _discoveredRepeaters.any((r) => 
          (r.position.latitude - lat!).abs() < 0.0001 && 
          (r.position.longitude - lon!).abs() < 0.0001
        );
        
        if (!isDuplicate) {
          _discoveredRepeaters.add(repeater);
          _debugLog.logInfo('✅ Found: ${name ?? nodeId} at ($lat, $lon)');
          print('✅ Found repeater: ${name ?? nodeId} at ($lat, $lon), SNR: $snr');
        }
      }
    } catch (e) {
      // Don't spam logs with parse errors, just debug output
      print('Parse error on line: $line - $e');
    }
  }

  // ============================================================================
  // DEVICE INFO
  // ============================================================================

  /// Handle RESP_CODE_SELF_INFO - device information
  void _handleSelfInfo(Uint8List data) {
    // TODO: Parse device name from self info
    // For now, just log that we received it
    _debugLog.logInfo('Received device self info');
  }
  


  // ============================================================================
  // PING OPERATIONS
  // ============================================================================

  /// Update device position (for proper mesh routing)
  Future<void> _updateDevicePosition(double latitude, double longitude) async {
    try {
      final posPayload = _protocol.createPositionPayload(latitude, longitude);
      final posCmd = _createCommandForDevice(CMD_SET_POSITION, posPayload);
      await _sendBinaryToDevice(posCmd);
      _debugLog.logInfo('📍 Updated device position: $latitude, $longitude');
    } catch (e) {
      _debugLog.logError('Failed to update position: $e');
    }
  }

  DateTime? _lastPingTime;
  static const Duration _minPingInterval = Duration(seconds: 30);
  
  /// Send Discovery ping to find nearby repeaters
  /// Uses MeshCore Discovery protocol (DISCOVER_REQ/DISCOVER_RESP)
  /// Note: Repeaters rate-limit responses to 4 per 2 minutes
  Future<PingResult> ping({
    double? latitude,
    double? longitude,
    int timeoutSeconds = 30,
  }) async {
    if (!isDeviceConnected) {
      return PingResult(
        timestamp: DateTime.now(),
        status: PingStatus.failed,
        error: 'LoRa device not connected',
      );
    }

    if (latitude == null || longitude == null) {
      return PingResult(
        timestamp: DateTime.now(),
        status: PingStatus.failed,
        error: 'No GPS location',
      );
    }
    
    // Check rate limiting - don't ping too frequently
    if (_lastPingTime != null) {
      final timeSinceLastPing = DateTime.now().difference(_lastPingTime!);
      if (timeSinceLastPing < _minPingInterval) {
        final waitSeconds = (_minPingInterval - timeSinceLastPing).inSeconds;
        _debugLog.logInfo('⏳ Rate limit: wait ${waitSeconds}s before next ping');
        print('⏳ Waiting ${waitSeconds}s to avoid rate limits...');
        // Still allow the ping but warn the user
      }
    }

    try {
      // Update device position for proper mesh routing
      await _updateDevicePosition(latitude, longitude);
      
      // Send zero-hop advertisement to get immediate contact updates
      final zeroHopPayload = Uint8List.fromList([0]);  // 0 = zero-hop
      final zeroHopCmd = _createCommandForDevice(CMD_SEND_ADVERT, zeroHopPayload);
      _debugLog.logInfo('📡 Sending zero-hop advertisement');
      await _sendBinaryToDevice(zeroHopCmd);
      
      // Small delay to let adverts propagate
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Generate random tag for this discovery request
      final tag = _random.nextInt(0xFFFFFFFF);
      
      // Create Discovery request payload (prefixOnly=false to get full 32-byte keys for contact lookup)
      final discoveryPayload = _protocol.createDiscoveryRequestPayload(tag, prefixOnly: false);
      _debugLog.logInfo('Discovery payload: ${discoveryPayload.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
      
      final controlCmd = _createCommandForDevice(CMD_SEND_CONTROL_DATA, discoveryPayload);
      _debugLog.logInfo('Full command frame: ${controlCmd.take(30).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}...');
      
      _debugLog.logInfo('📡 Sending DISCOVER_REQ with tag=0x${tag.toRadixString(16).padLeft(8, "0")}');
      await _sendBinaryToDevice(controlCmd);
      
      _lastPingTime = DateTime.now();
      _debugLog.logPing('📍 Discovery ping sent at ($latitude, $longitude)');
      _debugLog.logInfo('Note: Repeaters rate-limit to 4 responses per 2 minutes');
      print('📍 Discovery ping sent, tag=0x${tag.toRadixString(16)}, waiting for responses...');

      // Setup response tracking
      final completer = Completer<PingResult>();
      _pendingPings[tag] = completer;
      _pingResponses[tag] = [];

      // Early completion timer: complete after 3 seconds if we have responses
      Timer(const Duration(seconds: 3), () {
        if (!completer.isCompleted) {
          final responses = _pingResponses[tag] ?? [];
          if (responses.isNotEmpty) {
            // We have at least one response, complete early
            _pendingPings.remove(tag);
            _pingResponses.remove(tag);
            
            responses.sort((a, b) => (b['snr'] as int).compareTo(a['snr'] as int));
            final best = responses.first;
            
            print('✅ Ping complete (early): ${responses.length} repeater(s) responded');
            _debugLog.logPing('✅ Best response: ${best["nodeId"]} (SNR=${best["snr"]}, RSSI=${best["rssi"]})');
            
            final result = PingResult(
              timestamp: DateTime.now(),
              status: PingStatus.success,
              rssi: best['rssi'] as int,
              snr: best['snr'] as int,
              nodeId: best['nodeId'] as String,
              latitude: latitude,
              longitude: longitude,
            );
            completer.complete(result);
            _pingResultController.add(result);
          }
        }
      });

      // Final timeout handler: wait full timeout if no responses yet
      Timer(Duration(seconds: timeoutSeconds), () {
        if (!completer.isCompleted) {
          _pendingPings.remove(tag);
          final responses = _pingResponses.remove(tag) ?? [];
          
          if (responses.isEmpty) {
            // No repeaters responded - dead zone
            print('⏰ Ping timeout. No repeaters responded.');
            final result = PingResult(
              timestamp: DateTime.now(),
              status: PingStatus.timeout,
              latitude: latitude,
              longitude: longitude,
              error: 'No repeaters in range - dead zone',
            );
            completer.complete(result);
            _pingResultController.add(result);
          } else {
            // Got responses after early timer - use the best one (highest SNR)
            responses.sort((a, b) => (b['snr'] as int).compareTo(a['snr'] as int));
            final best = responses.first;
            
            print('✅ Ping complete: ${responses.length} repeater(s) responded');
            _debugLog.logPing('✅ Best response: ${best["nodeId"]} (SNR=${best["snr"]}, RSSI=${best["rssi"]})');
            
            final result = PingResult(
              timestamp: DateTime.now(),
              status: PingStatus.success,
              rssi: best['rssi'] as int,
              snr: best['snr'] as int,
              nodeId: best['nodeId'] as String,
              latitude: latitude,
              longitude: longitude,
            );
            completer.complete(result);
            _pingResultController.add(result);
          }
        }
      });

      return await completer.future;
    } catch (e) {
      final result = PingResult(
        timestamp: DateTime.now(),
        status: PingStatus.failed,
        latitude: latitude,
        longitude: longitude,
        error: e.toString(),
      );
      _pingResultController.add(result);
      return result;
    }
  }

  /// Send command/data to LoRa device
  Future<void> _sendToDevice(String data) async {
    if (_connectionType == ConnectionType.bluetooth && _txCharacteristic != null) {
      await _txCharacteristic!.write(utf8.encode(data));
    } else if (_connectionType == ConnectionType.usb && _usbPort != null) {
      await _usbPort!.write(Uint8List.fromList(utf8.encode(data)));
    }
  }

  /// Handle binary data from LoRa device
  void _handleDeviceData(Uint8List data) {
    try {
      _debugLog.logLoRa('📶 Raw RX: ${data.length} bytes - ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).take(20).join(' ')}${data.length > 20 ? '...' : ''}');
      print('📶 Raw RX: ${data.length} bytes');
      
      final frames = _protocol.parseIncomingData(data);
      for (final frame in frames) {
        _handleFrame(frame);
      }
    } catch (e) {
      _debugLog.logError('Frame parse error: $e');
    }
  }

  /// Route incoming frames to appropriate handlers
  void _handleFrame(MeshCoreFrame frame) {
    _debugLog.logLoRa('📥 RX Frame: code=0x${frame.code.toRadixString(16).padLeft(2, '0')} (${frame.code}) len=${frame.length}');
    print('📥 RX Frame: code=0x${frame.code.toRadixString(16).padLeft(2, '0')} (${frame.code}) len=${frame.length}');
    
    switch (frame.code) {
      case PUSH_CODE_ADVERT:
        _handleAdvertPush(frame.data);
        break;
      case RESP_CODE_CONTACT:
        _handleContactResponse(frame.data);
        break;
      case RESP_CODE_END_OF_CONTACTS:
        _debugLog.logInfo('Contact list complete');
        break;
      case RESP_CODE_APP_START:
        _debugLog.logInfo('✅ App handshake complete');
        break;
      case RESP_CODE_SELF_INFO:
        _handleSelfInfo(frame.data);
        break;
      case RESP_CODE_OK:
        _debugLog.logInfo('✅ Command OK');
        break;
      case RESP_CODE_ERR:
        _debugLog.logError('❌ Command ERROR');
        break;
      case RESP_CODE_SENT:
        _debugLog.logInfo('✅ Message sent');
        break;
      case RESP_CODE_BATT_AND_STORAGE:
        _handleBatteryResponse(frame.data);
        break;
      case PUSH_CODE_ACK_RECV:
        _debugLog.logLoRa('✅ ACK received (0x84), payload len=${frame.data.length}');
        print('✅ ACK frame: ${frame.data.take(40).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
        _handleAckReceived(frame.data);
        break;
      case PUSH_CODE_CONTROL_DATA:
        _debugLog.logLoRa('🔍 Control data received (0x8E), payload len=${frame.data.length}');
        _debugLog.logLoRa('Control data hex: ${frame.data.take(50).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}${frame.data.length > 50 ? "..." : ""}');
        print('🔍 Control data: ${frame.data.take(50).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
        _handleControlDataPush(frame.data);
        break;
      default:
        // Log other frame types for debugging
        _debugLog.logLoRa('Unhandled frame type: 0x${frame.code.toRadixString(16)}');
    }
  }

  /// Handle PUSH_CODE_ADVERT - advertisement from nearby node
  Future<void> _handleAdvertPush(Uint8List data) async {
    final publicKey = _protocol.parseAdvertFrame(data);
    if (publicKey == null) return;
    
    final keyHexFull = publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    final keyPrefix = keyHexFull.substring(0, 8).toUpperCase();
    _debugLog.logInfo('📡 Advertisement from $keyPrefix');
    
    // Track this advertisement for echo correlation
    _recentAdvertisements[keyPrefix] = DateTime.now();
    
    // Do not request contacts on adverts to avoid full list dumps.
    // We already load contacts on connect or when user scans.
    _debugLog.logInfo('ℹ️ Skipping contact request on ADVERT for $keyPrefix');
  }

  /// Request full contact list
  Future<void> _requestAllContacts() async {
    try {
      _debugLog.logInfo('📒 Requesting full contact list...');
      final cmd = _createCommandForDevice(CMD_GET_CONTACTS);
      await _sendBinaryToDevice(cmd);
    } catch (e) {
      _debugLog.logError('Failed to request full contact list: $e');
    }
  }
  
  /// Refresh contact list (public method for UI)
  Future<void> refreshContactList() async {
    await _requestAllContacts();
  }

  /// Request contact details for a specific public key
  Future<void> _requestContactDetails(Uint8List publicKey) async {
    final keyHex = publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    final keyPrefix = keyHex.substring(0, 8).toUpperCase();
    
    // Avoid duplicate in-flight requests
    if (_pendingContactRequests.contains(keyHex)) {
      print('⏭️ Skipping duplicate contact request for $keyPrefix');
      return;
    }
    
    // Throttle by time window
    final last = _lastContactRequestAt[keyPrefix];
    final now = DateTime.now();
    if (last != null && now.difference(last) <= _contactRequestCooldown) {
      print('⏭️ Skipping contact request for $keyPrefix (within cooldown)');
      return;
    }
    _lastContactRequestAt[keyPrefix] = now;
    _pendingContactRequests.add(keyHex);
    
    print('📞 Requesting contact details for $keyPrefix');
    _debugLog.logInfo('Requesting contact for $keyPrefix');
    
    final cmd = _createCommandForDevice(CMD_GET_CONTACTS, publicKey);
    await _sendBinaryToDevice(cmd);
  }

  /// Handle PUSH_CODE_CONTROL_DATA - control data packet (e.g., Discovery responses)
  Future<void> _handleControlDataPush(Uint8List data) async {
    try {
      // Parse the control data frame (extracts SNR, RSSI, path, payload)
      final controlData = _protocol.parseControlDataPush(data);
      if (controlData == null) {
        _debugLog.logError('⚠️ Failed to parse control data push');
        return;
      }
      
      final snr = controlData['snr'] as int;
      final rssi = controlData['rssi'] as int;
      final payload = controlData['payload'] as Uint8List;
      
      // Parse the payload as a Discovery response
      final discovery = _protocol.parseDiscoveryResponse(payload);
      if (discovery == null) {
        _debugLog.logLoRa('Control data is not a Discovery response');
        return;
      }
      
      final tag = discovery['tag'] as int;
      final nodeType = discovery['node_type'] as int;
      final pubkey = discovery['pubkey'] as String;
      final pubkeyShort = pubkey.substring(0, 8).toUpperCase();
      final discoverySNR = discovery['snr'] as int; // SNR from discovery payload
      
      _debugLog.logInfo('🔍 DISCOVER_RESP: tag=0x${tag.toRadixString(16)}, node=$pubkeyShort, type=$nodeType, SNR=$snr, RSSI=$rssi');
      print('🔍 Discovery response from $pubkeyShort (SNR=$snr, RSSI=$rssi)');
      
      // Check if this repeater should be ignored (mobile companion)
      final shouldIgnore = _ignoredRepeaterPrefix != null && 
          pubkeyShort.toUpperCase().startsWith(_ignoredRepeaterPrefix!.toUpperCase());
      
      if (shouldIgnore) {
        _debugLog.logInfo('⛔ Ignoring discovery response from mobile repeater: $pubkeyShort');
        return;
      }
      
      // Request contact info to get repeater position (if we don't already have it)
      if (!_knownRepeaters.containsKey(pubkey) && discovery['pubkey_bytes'] != null) {
        final pubkeyBytes = discovery['pubkey_bytes'] as Uint8List;
        _debugLog.logInfo('📞 Requesting position for $pubkeyShort');
        await _requestContactDetails(pubkeyBytes);
      }
      
      // Check if this response matches a pending ping
      final completer = _pendingPings[tag];
      if (completer != null && !completer.isCompleted) {
        // Add this response to the list
        _pingResponses[tag]?.add({
          'nodeId': pubkeyShort,
          'snr': snr,
          'rssi': rssi,
          'node_type': nodeType,
        });
        
        _debugLog.logPing('📡 Repeater $pubkeyShort responded (SNR=$snr, RSSI=$rssi)');
        
        // Note: We don't complete immediately - we wait for timeout to collect all responses
        // and then pick the best one (highest SNR)
      } else {
        _debugLog.logLoRa('⚠️ Discovery response for unknown/completed tag: 0x${tag.toRadixString(16)}');
      }
    } catch (e) {
      _debugLog.logError('Error handling control data push: $e');
    }
  }

  /// Handle RESP_CODE_CONTACT - contact details response
  void _handleContactResponse(Uint8List data) {
    final contact = _protocol.parseContactFrame(data);
    if (contact == null) {
      _debugLog.logError('Failed to parse contact frame');
      return;
    }
    
    // Clear from pending
    _pendingContactRequests.remove(contact.publicKeyHex);
    
    // Store node type for filtering
    _nodeTypes[contact.publicKeyPrefix] = contact.advType;
    
    _debugLog.logInfo('Contact: ${contact.advName ?? contact.publicKeyPrefix} (type: ${contact.advType})');
    
    // Only show repeaters (2) and room servers (3) on the map, and only if they have a position
    if (!contact.hasPosition || (contact.advType != ADV_TYPE_REPEATER && contact.advType != ADV_TYPE_ROOM_SERVER)) {
      return;
    }
    
    // Check if this repeater should be ignored (mobile companion)
    final shouldIgnore = _ignoredRepeaterPrefix != null && 
        contact.publicKeyPrefix.toUpperCase().startsWith(_ignoredRepeaterPrefix!.toUpperCase());
    
    if (shouldIgnore) {
      _debugLog.logInfo('⛔ Ignoring mobile repeater: ${contact.advName ?? contact.publicKeyPrefix}');
      return;
    }
    
    final repeater = Repeater(
      id: contact.publicKeyPrefix,
      position: LatLng(contact.advLat!, contact.advLon!),
      name: contact.advName,
      timestamp: DateTime.now(),
    );
    
    // If scanning, cache only; otherwise show immediately on map
    if (_scanCompleter != null && !_scanCompleter!.isCompleted) {
      _repeaterContactCache[repeater.id] = repeater;
      _knownRepeaters[repeater.id] = repeater; // mark as known
      _debugLog.logInfo('📋 Cached: ${repeater.name ?? repeater.id}');
      return;
    }
    
    // Mark as known
    _knownRepeaters[repeater.id] = repeater;
    
    if (!_discoveredRepeaters.any((r) => r.id == repeater.id)) {
      _discoveredRepeaters.add(repeater);
      _debugLog.logInfo('✅ Added to map: ${repeater.name ?? repeater.id} at (${contact.advLat}, ${contact.advLon})');
    } else {
      // Update existing repeater's timestamp
      final idx = _discoveredRepeaters.indexWhere((r) => r.id == repeater.id);
      if (idx != -1) {
        _discoveredRepeaters[idx] = repeater;
      }
    }
  }

  /// Handle RESP_CODE_BATT_AND_STORAGE
  void _handleBatteryResponse(Uint8List data) {
    if (data.length >= 2) {
      final milliVolts = data[0] | (data[1] << 8);
      // Rough battery percentage from voltage (adjust as needed)
      if (milliVolts > 3000) {
        final percent = ((milliVolts - 3000) / 1200 * 100).clamp(0, 100).toInt();
        _batteryPercent = percent;
        _batteryController.add(percent);
        _debugLog.logInfo('Battery: $percent% ($milliVolts mV)');
      }
    }
  }

  /// Handle PUSH_CODE_ACK_RECV (0x84) - ACK from zero-hop advertisement  
  /// ACKs indicate a repeater is in direct range and provide SNR/RSSI for coverage mapping
  Future<void> _handleAckReceived(Uint8List data) async {
    try {
      if (data.length < 36) {
        return;
      }
      
      // Parse SNR and RSSI (first 4 bytes)
      int snr = data[0] | (data[1] << 8);
      if (snr > 32767) snr -= 65536;
      
      int rssi = data[2] | (data[3] << 8);
      if (rssi > 32767) rssi -= 65536;
      
      // Parse public key (next 32 bytes)
      final publicKey = Uint8List.fromList(data.sublist(4, 36));
      final keyHex = publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
      final keyPrefix = keyHex.substring(0, 8).toUpperCase();
      
      _debugLog.logInfo('✅ ACK from $keyPrefix (SNR: $snr, RSSI: $rssi)');
      print('✅ ACK from repeater $keyPrefix (SNR=$snr, RSSI=$rssi)');
      
      // Check if this repeater should be ignored (mobile companion)
      final shouldIgnore = _ignoredRepeaterPrefix != null && 
          keyPrefix.toUpperCase().startsWith(_ignoredRepeaterPrefix!.toUpperCase());
      
      if (shouldIgnore) {
        _debugLog.logInfo('⛔ Ignoring ACK from mobile repeater: $keyPrefix');
        return;
      }
      
      // Request contact info to get repeater position (if we don't already have it)
      if (!_knownRepeaters.containsKey(keyPrefix)) {
        _debugLog.logInfo('📞 Requesting position for $keyPrefix');
        await _requestContactDetails(publicKey);
      } else {
        // Update signal strength for known repeater
        _updateRepeaterSignal(keyPrefix, snr: snr, rssi: rssi);
      }
      
      // If there's a pending ping waiting for responses, add this ACK as a response
      // Look for the most recent pending ping (should be the active one)
      if (_pendingPings.isNotEmpty) {
        final activePing = _pendingPings.entries.last;
        if (!activePing.value.isCompleted) {
          _pingResponses[activePing.key]?.add({
            'nodeId': keyPrefix,
            'snr': snr,
            'rssi': rssi,
            'node_type': ADV_TYPE_REPEATER,
          });
          _debugLog.logPing('📡 Added ACK from $keyPrefix to ping responses');
        }
      }
    } catch (e) {
      _debugLog.logError('Error parsing ACK frame: $e');
    }
  }

  void _updateRepeaterSignal(String repeaterId, {int? snr, int? rssi}) {
    try {
      final idx = _discoveredRepeaters.indexWhere((r) => r.id == repeaterId);
      if (idx != -1) {
        final c = _discoveredRepeaters[idx];
        _discoveredRepeaters[idx] = Repeater(
          id: c.id,
          position: c.position,
          elevation: c.elevation,
          timestamp: DateTime.now(),
          name: c.name,
          rssi: rssi ?? c.rssi,
          snr: snr ?? c.snr,
          distance: c.distance,
        );
      }
      if (_repeaterContactCache.containsKey(repeaterId)) {
        final c = _repeaterContactCache[repeaterId]!;
        _repeaterContactCache[repeaterId] = Repeater(
          id: c.id,
          position: c.position,
          elevation: c.elevation,
          timestamp: DateTime.now(),
          name: c.name,
          rssi: rssi ?? c.rssi,
          snr: snr ?? c.snr,
          distance: c.distance,
        );
      }
      if (_knownRepeaters.containsKey(repeaterId)) {
        final c = _knownRepeaters[repeaterId]!;
        _knownRepeaters[repeaterId] = Repeater(
          id: c.id,
          position: c.position,
          elevation: c.elevation,
          timestamp: DateTime.now(),
          name: c.name,
          rssi: rssi ?? c.rssi,
          snr: snr ?? c.snr,
          distance: c.distance,
        );
      }
    } catch (_) {}
  }

  /// Create command frame based on connection type (BLE vs USB)
  Uint8List _createCommandForDevice(int commandCode, [Uint8List? payload]) {
    if (_connectionType == ConnectionType.bluetooth) {
      return _protocol.createCommandFrameBLE(commandCode, payload);
    } else {
      return _protocol.createCommandFrame(commandCode, payload);
    }
  }

  /// Send binary frame to device (Bluetooth only for iOS)
  Future<void> _sendBinaryToDevice(Uint8List data) async {
    try {
      _debugLog.logLoRa('📤 TX: ${data.length} bytes - ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).take(20).join(' ')}${data.length > 20 ? '...' : ''}');
      
      if (_connectionType == ConnectionType.bluetooth && _txCharacteristic != null) {
        // BLE: Send the raw frame data without wrapper
        await _txCharacteristic!.write(data.toList());
        _debugLog.logLoRa('✅ BLE write complete');
      }
    } catch (e) {
      _debugLog.logError('Send error: $e');
    }
  }

  /// Process a complete line from LoRa device (legacy text mode)
  void _processDeviceLine(String line) {
    _debugLog.logLoRa(line);
    print('LoRa device: $line');
    
    // Try to parse battery percentage from device messages
    // Common formats:
    // - "Battery: 85%"
    // - "Batt=85%"
    // - "bat:85"
    final batteryRegex = RegExp(r'(?:battery|batt?|pwr)[:\s=]+?(\d+)', caseSensitive: false);
    final match = batteryRegex.firstMatch(line);
    if (match != null) {
      final percent = int.tryParse(match.group(1)!);
      if (percent != null && percent >= 0 && percent <= 100) {
        _batteryPercent = percent;
        _batteryController.add(_batteryPercent);
        print('Battery from device message: $percent%');
      }
    }
    
    // Parse repeater/node information if we're scanning
    if (_scanCompleter != null && !_scanCompleter!.isCompleted) {
      _parseRepeaterLine(line);
    }
  }

  /// Decrypt AES-ECB encrypted channel message
  Uint8List? _decryptChannelMessage(Uint8List encrypted, Uint8List key) {
    try {
      if (encrypted.length % 16 != 0) return null; // Must be block-aligned
      
      final cipher = AESEngine();
      cipher.init(false, KeyParameter(key));
      
      final decrypted = Uint8List(encrypted.length);
      for (int i = 0; i < encrypted.length; i += 16) {
        cipher.processBlock(encrypted, i, decrypted, i);
      }
      
      return decrypted;
    } catch (e) {
      print('Decryption error: $e');
      return null;
    }
  }

  // ============================================================================
  // BATTERY MONITORING
  // ============================================================================
  
  Timer? _batteryMonitorTimer;
  BluetoothCharacteristic? _batteryCharacteristic;
  
  void _startBatteryMonitoring() {
    // Poll battery every 30 seconds if we have a battery characteristic
    _batteryMonitorTimer?.cancel();
    _batteryMonitorTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_connectionType == ConnectionType.bluetooth && _batteryCharacteristic != null) {
        try {
          final value = await _batteryCharacteristic!.read();
          if (value.isNotEmpty) {
            _batteryPercent = value[0];
            _batteryController.add(_batteryPercent);
          }
        } catch (e) {
          print('Error reading battery: $e');
        }
      }
    });
  }
  
  void _stopBatteryMonitoring() {
    _batteryMonitorTimer?.cancel();
    _batteryMonitorTimer = null;
    _batteryCharacteristic = null;
    _batteryPercent = null;
    _batteryController.add(null);
  }

  // ============================================================================
  // UTILITIES
  // ============================================================================

  String _generateId() {
    final random = Random();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(8, (index) => chars[random.nextInt(chars.length)]).join();
  }

  // ============================================================================
  // DISCONNECT
  // ============================================================================

  /// Handle unexpected Bluetooth disconnection
  void _handleBluetoothDisconnection() {
    print('⚠️ Bluetooth device disconnected unexpectedly');
    _debugLog.logError('Bluetooth disconnected');
    
    _stopBatteryMonitoring();
    _connectionStateSubscription?.cancel();
    _deviceSubscription?.cancel();
    
    _bluetoothDevice = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _connectionType = ConnectionType.none;
    _deviceName = null;
    
    // Fail any pending pings
    for (final entry in _pendingPings.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(PingResult(
          timestamp: DateTime.now(),
          status: PingStatus.failed,
          error: 'Bluetooth connection lost',
        ));
      }
    }
    _pendingPings.clear();
    _pingResponses.clear();
  }

  Future<void> disconnectDevice() async {
    try {
      _stopBatteryMonitoring();
      await _connectionStateSubscription?.cancel();
      await _deviceSubscription?.cancel();
      
      if (_connectionType == ConnectionType.bluetooth && _bluetoothDevice != null) {
        await _bluetoothDevice!.disconnect();
      }

      _bluetoothDevice = null;
      _txCharacteristic = null;
      _rxCharacteristic = null;
      _connectionType = ConnectionType.none;
      _deviceName = null;
      _connectionStateSubscription = null;
      print('LoRa device disconnected');
    } catch (e) {
      print('Error disconnecting device: $e');
    }
  }

  Future<void> disconnectMqtt() async {
  Future<void> disconnectMqtt() async {
    // MQTT removed - no-op
  }


  void dispose() {
    disconnectDevice();
    _pingResultController.close();
    _batteryController.close();
  }
}
