import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:latlong2/latlong.dart';
import 'debug_log_service.dart';
import 'meshcore_protocol.dart';
import '../models/models.dart';

enum ConnectionType { usb, bluetooth, none }
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
  UsbPort? _usbPort;
  StreamSubscription? _deviceSubscription;
  String? _deviceName; // Connected device's advertised name
  
  // State
  final _pingResultController = StreamController<PingResult>.broadcast();
  final _pendingPings = <String, Completer<PingResult>>{};
  int? _batteryPercent;
  final _batteryController = StreamController<int?>.broadcast();
  
  // Channel discovery callback
  Function(bool meshwarFound)? onChannelDiscoveryComplete;
  
  // Track pending contact requests
  final Set<String> _pendingContactRequests = {};
  
  // Repeater scanning
  List<Repeater> _discoveredRepeaters = []; // Repeaters that have echoed during wardriving
  Map<String, Repeater> _repeaterContactCache = {}; // All known repeater contacts (from scan)
  Map<String, int> _nodeTypes = {}; // Map of node ID -> advType (1=companion, 2=repeater, 3=room)
  Completer<List<Repeater>>? _scanCompleter;
  String? _pendingScanMessage; // Track scan broadcast messages
  Map<String, Repeater> _knownRepeaters = {}; // Map of repeater ID -> location from internet map
  
  // Throttle contact lookups to avoid dumping full list repeatedly
  final Map<String, DateTime> _lastContactRequestAt = {}; // keyPrefix -> time
  Duration _contactRequestCooldown = const Duration(minutes: 5);
  
  // Wardrive channel
  // Default to index 1, user can change in settings
  int _wardriveChannelIdx = 1;
  bool _channelDiscoveryComplete = true; // Skip auto setup
  
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
  
  Uint8List? _hexToBytes(String hex) {
    final cleaned = hex.trim().toLowerCase();
    final re = RegExp(r'^[0-9a-f]{32}$');
    if (!re.hasMatch(cleaned)) return null;
    final out = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// Manually set the wardrive channel key (hex) and persist.
  Future<bool> setManualWardriveChannelKey(String hex) async {
    final key = _hexToBytes(hex);
    if (key == null) return false;
    _channelKeys[_wardriveChannelIdx] = key;
    await _secureStorage.write(key: 'meshcore_manual_channel_key_${_wardriveChannelIdx}', value: hex);
    _debugLog.logInfo('🔐 Manual wardrive channel key set for index ${_wardriveChannelIdx}');
    return true;
  }

  /// Load manual wardrive channel key if previously saved.
  Future<void> _loadManualWardriveChannelKey() async {
    try {
      final saved = await _secureStorage.read(key: 'meshcore_manual_channel_key_${_wardriveChannelIdx}');
      if (saved != null) {
        final key = _hexToBytes(saved);
        if (key != null) {
          _channelKeys[_wardriveChannelIdx] = key;
          _debugLog.logInfo('🔐 Loaded manual wardrive channel key for index ${_wardriveChannelIdx}');
        }
      }
    } catch (e) {
      _debugLog.logError('Failed to load manual wardrive key: $e');
    }
  }

  /// Set the channel index for wardrive pings
  void setWardriveChannelIndex(int index) {
    if (index < 0 || index > 7) {
      throw ArgumentError('Channel index must be between 0 and 7');
    }
    _wardriveChannelIdx = index;
    _debugLog.logInfo('Wardrive channel index set to: $index');
    print('Wardrive channel index set to: $index');
    
    // Request channel key if connected
    if (isDeviceConnected) {
      _requestChannelInfo(index);
    }
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
          // Look for LoRa/Meshtastic devices
          final name = r.device.platformName.toLowerCase();
          if (name.contains('lora') ||
              name.contains('meshtastic') ||
              name.contains('meshcore') ||
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
        
      // Discover or create #meshwar channel
      await Future.delayed(const Duration(milliseconds: 200));
      await _discoverOrCreateMeshwarChannel();

      // Apply manual/default wardrive key if available
      await _loadManualWardriveChannelKey();

      // Immediately load full contact list so repeaters appear on the map
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
  // DEVICE CONNECTION - USB
  // ============================================================================

  /// Scan for USB LoRa devices
  Future<List<UsbDevice>> scanUsbDevices() async {
    try {
      return await UsbSerial.listDevices();
    } catch (e) {
      print('Error scanning USB: $e');
      return [];
    }
  }

  /// Connect to LoRa device via USB
  Future<bool> connectUsb(UsbDevice device) async {
    try {
      _usbPort = await device.create();
      if (_usbPort == null) return false;

      bool opened = await _usbPort!.open();
      if (!opened) return false;

      await _usbPort!.setDTR(true);
      await _usbPort!.setRTS(true);
      await _usbPort!.setPortParameters(
        115200, // Standard baud rate for Meshtastic
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      _deviceSubscription = _usbPort!.inputStream?.listen((data) {
        _handleDeviceData(Uint8List.fromList(data));
      });

      _connectionType = ConnectionType.usb;
      print('Connected to LoRa device via USB');
      
      // Ensure USB mode in protocol parser (wrapped frames with '>')
      _protocol.setBLEMode(false);
      _debugLog.logInfo('Protocol set to USB mode (wrapped frames)');
      
      // Send handshake
      await Future.delayed(const Duration(milliseconds: 500));
      final handshake = _createCommandForDevice(CMD_APP_START);
      await _sendBinaryToDevice(handshake);
      _debugLog.logInfo('Sent handshake');

      // Apply manual/default wardrive key if available
      await _loadManualWardriveChannelKey();
      
      // Load full contact list so repeaters appear on the map
      await Future.delayed(const Duration(milliseconds: 150));
      await _requestAllContacts();
      
      return true;
    } catch (e) {
      print('USB connection error: $e');
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
  /// Caches contact info but doesn't add to map until they echo
  Future<List<Repeater>> scanForRepeaters({int timeoutSeconds = 20}) async {
    if (!isDeviceConnected) {
      _debugLog.logError('Cannot scan - LoRa device not connected');
      return [];
    }

    try {
      _debugLog.logInfo('🔍 Loading repeater contacts from device...');
      _repeaterContactCache.clear();
      _scanCompleter = Completer<List<Repeater>>();

      // Send a broadcast ping message to discover repeaters
      // Use a special marker so we can identify scan responses
      final scanMessage = 'SCAN ${_generateId()}';
      final payload = _protocol.createChannelMessagePayload(_wardriveChannelIdx, scanMessage);
      final channelMsg = _createCommandForDevice(CMD_SEND_CHANNEL_MESSAGE, payload);
      await _sendBinaryToDevice(channelMsg);
      
      _debugLog.logInfo('Sent scan broadcast on channel $_wardriveChannelIdx');
      print('📡 Scanning for repeater contacts...');
      
      // Store the scan message so we can identify repeats
      _pendingScanMessage = scanMessage;

      // Wait for repeater responses
      Timer(Duration(seconds: timeoutSeconds), () {
        if (_scanCompleter != null && !_scanCompleter!.isCompleted) {
          _pendingScanMessage = null;
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
  
  /// Get repeater location by ID (from cache or fetch)
  Repeater? getRepeaterLocation(String repeaterId) {
    return _knownRepeaters[repeaterId];
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
  
  // Channel encryption key storage
  Map<int, Uint8List> _channelKeys = {};
  Map<int, String> _channelNames = {}; // index -> name
  Completer<void>? _channelDiscoveryCompleter;
  int _channelsQueried = 0;
  bool _meshwarFound = false;
  
  /// Discover existing #meshwar channel or create it
  Future<void> _discoverOrCreateMeshwarChannel() async {
    try {
      print('🔍 Searching for #meshwar channel...');
      _debugLog.logInfo('Discovering #meshwar channel');
      
      _channelDiscoveryCompleter = Completer<void>();
      _channelsQueried = 0;
      _meshwarFound = false;
      
      // Query channels 0-7 to find #meshwar
      for (int i = 0; i <= 7; i++) {
        await _requestChannelInfo(i);
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      // Wait up to 3 seconds for responses
      await _channelDiscoveryCompleter!.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _debugLog.logInfo('Channel discovery timeout');
        },
      );
      
      if (!_meshwarFound) {
        _debugLog.logError('#meshwar channel not found');
        print('⚠️ #meshwar channel not found - user needs to join it in MeshCore app first');
        
        // Choose a target slot: first empty slot from 1..7, else 3 if empty, else skip
        int? targetIdx;
        for (int i = 1; i <= 7; i++) {
          final n = _channelNames[i];
          if (n == null || n.trim().isEmpty) { targetIdx = i; break; }
        }
        // Don't try to create channel - user must join #meshwar in MeshCore app first
        print('⚠️ #meshwar channel not found on device');
        print('⚠️ Please open MeshCore app and join the #meshwar channel before using this app');
        
        // Notify UI that #meshwar was not found
        if (onChannelDiscoveryComplete != null) {
          onChannelDiscoveryComplete!(false);
        }
      }
      
      _channelDiscoveryCompleter = null;
    } catch (e) {
      _debugLog.logError('Channel discovery error: $e');
    }
  }
  
  
  /// Request channel info to get encryption key
  Future<void> _requestChannelInfo(int channelIdx) async {
    try {
      print('📡 Requesting channel $channelIdx info for encryption key');
      _debugLog.logInfo('Requesting channel $channelIdx info');
      
      final payload = _protocol.createGetChannelPayload(channelIdx);
      final cmd = _createCommandForDevice(CMD_GET_CHANNEL, payload);
      await _sendBinaryToDevice(cmd);
    } catch (e) {
      _debugLog.logError('Failed to request channel info: $e');
    }
  }
  
  /// Handle RESP_CODE_CHANNEL_INFO - channel information with encryption key
  void _handleChannelInfo(Uint8List data) {
    final channelInfo = _protocol.parseChannelInfoFrame(data);
    if (channelInfo == null) {
      _debugLog.logError('Failed to parse channel info');
      return;
    }
    
    final index = channelInfo['index'] as int;
    final name = channelInfo['name'] as String;
    final key = channelInfo['key'] as Uint8List;
    
    // Store the channel name and key for decryption
    _channelNames[index] = name;
    _channelKeys[index] = key;
    
    _debugLog.logInfo('🔑 Channel $index "$name" key stored');
    print('🔑 Got encryption key for channel $index: $name');
    
    // Check if this is #meshwar during discovery
    if (_channelDiscoveryCompleter != null && !_channelDiscoveryCompleter!.isCompleted) {
      _channelsQueried++;
      
      if (name.toLowerCase().contains('meshwar')) {
        _meshwarFound = true;
        _wardriveChannelIdx = index;
        print('✅ Found #meshwar on channel $index!');
        _debugLog.logInfo('Found #meshwar on channel $index');
        
        // Notify UI that #meshwar was found
        if (onChannelDiscoveryComplete != null) {
          onChannelDiscoveryComplete!(true);
        }
        
        _channelDiscoveryCompleter!.complete();
      } else if (_channelsQueried >= 8) {
        // All channels queried, none found
        _channelDiscoveryCompleter!.complete();
      }
    }
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

  /// Send ping via wardrive channel message
  /// Repeaters will hear and echo the message back
  Future<PingResult> ping({
    double? latitude,
    double? longitude,
    int timeoutSeconds = 10,
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

    try {
      // First, update device position so repeaters know where message came from
      await _updateDevicePosition(latitude, longitude);
      
      // Format message: "<lat> <lon> [<ignored_id>]"
      String message = '${latitude.toStringAsFixed(4)} ${longitude.toStringAsFixed(4)}';
      if (_ignoredRepeaterPrefix != null) {
        message += ' $_ignoredRepeaterPrefix';
      }
      
      // Send channel message to configured channel index
      final payload = _protocol.createChannelMessagePayload(_wardriveChannelIdx, message);
      _debugLog.logInfo('📤 Creating ping payload: ${payload.length} bytes, channel=$_wardriveChannelIdx');
      
      final channelMsg = _createCommandForDevice(CMD_SEND_CHANNEL_MESSAGE, payload);
      _debugLog.logInfo('📤 Sending CMD_SEND_CHANNEL_MESSAGE (0x03) frame: ${channelMsg.length} bytes');
      
      await _sendBinaryToDevice(channelMsg);
      
      _debugLog.logPing('📍 Ping sent to channel $_wardriveChannelIdx: $message');
      _debugLog.logInfo('⏳ Waiting for repeat (timeout: ${timeoutSeconds}s)...');
      print('📍 Ping sent: $message, waiting for repeat...');

      // Wait for repeat (echo) from repeater
      final completer = Completer<PingResult>();
      _pendingPings[message] = completer;

      Timer(Duration(seconds: timeoutSeconds), () {
        if (!completer.isCompleted) {
          _pendingPings.remove(message);
          final result = PingResult(
            timestamp: DateTime.now(),
            status: PingStatus.timeout,
            latitude: latitude,
            longitude: longitude,
            error: 'No repeat heard - dead zone',
          );
          completer.complete(result);
          _pingResultController.add(result);
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
      case RESP_CODE_CHANNEL_INFO:
        _handleChannelInfo(frame.data);
        break;
      case PUSH_CODE_CHANNEL_MSG_RECV:
        _handleChannelMessage(frame.data);
        break;
      case PUSH_CODE_CHANNEL_ECHO:
        _debugLog.logLoRa('🔁 Channel echo received (0x88), payload len=${frame.data.length}');
        print('🔁 ECHO frame: ${frame.data.take(40).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
        _handleChannelEcho(frame.data);  // Echo format has extra header
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
    if (_pendingScanMessage != null && _scanCompleter != null && !_scanCompleter!.isCompleted) {
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

  /// Handle PUSH_CODE_CHANNEL_ECHO (0x88) - actually raw radio log frame
  void _handleChannelEcho(Uint8List data) {
    // 0x88 is PUSH_CODE_LOG_RX_DATA - raw log with SNR/RSSI at bytes 0-1
    final msgData = _protocol.parseRawLogFrame(data);
    if (msgData == null) {
      _debugLog.logError('Failed to parse raw log frame (${data.length} bytes)');
      print('❌ Failed to parse 0x88 frame - raw hex: ${data.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
      return;
    }
    _processChannelMessage(msgData);
  }

  /// Handle PUSH_CODE_CHANNEL_MSG_RECV - incoming channel message (repeat)
  void _handleChannelMessage(Uint8List data) {
    final msgData = _protocol.parseChannelMessageFrame(data);
    if (msgData == null) {
      _debugLog.logError('Failed to parse channel message');
      return;
    }
    _processChannelMessage(msgData);
  }
  
  /// Process parsed channel message/echo data
  Future<void> _processChannelMessage(Map<String, dynamic> msgData) async {
    
    final text = msgData['text'] as String?;
    final repeater = msgData['repeater'] as String?;
    final snr = msgData['snr'] as int?;
    final rssi = msgData['rssi'] as int?;
    
    _debugLog.logLoRa('📡 Channel message from ${msgData['sender']}: "$text" via $repeater');
    print('📡 Channel message received: "$text", repeater=$repeater, snr=$snr, rssi=$rssi');

    // Update repeater signal metrics in UI caches
    if (repeater != null && (snr != null || rssi != null)) {
      _updateRepeaterSignal(repeater, snr: snr, rssi: rssi);
    }
    
    // Check if this is a scan broadcast response
    // During scan, we accept ANY echo and request contact details to cache
    if (_pendingScanMessage != null && _scanCompleter != null && !_scanCompleter!.isCompleted) {
      // Use repeater ID if available, otherwise use sender (for direct echoes)
      final nodeId = repeater ?? msgData['sender'] as String?;
      
      // Ignore companion nodes (not repeaters)
      if (nodeId != null && _isCompanionNode(nodeId)) {
        _debugLog.logInfo('📱 Ignoring companion node: $nodeId');
        return;
      }
      
      if (nodeId != null && !_repeaterContactCache.containsKey(nodeId)) {
        _debugLog.logInfo('📡 Echo from: $nodeId (SNR: $snr, RSSI: $rssi)');
        print('📡 Echo from: $nodeId (SNR: $snr, RSSI: $rssi)');
        
        // Request contact details to cache
        final senderKey = msgData['repeaterKey'] as Uint8List? ?? msgData['senderKey'] as Uint8List?;
        if (senderKey != null) {
          await _requestContactDetails(senderKey);
        } else {
          print('⚠️ No sender key available for $nodeId');
        }
      }
      return; // Don't process as normal ping
    }
    
    // Check if this is a repeat of one of our pings
    // Accept ANY echo when we have pending pings (messages are encrypted)
    // Use repeater if available, otherwise sender (for direct echoes)
    final echoSource = repeater ?? msgData['sender'] as String?;
    
    if (_pendingPings.isNotEmpty && echoSource != null) {
      print('Echo received from $echoSource (repeater=$repeater, sender=${msgData['sender']}) with pending pings: ${_pendingPings.keys.toList()}');
      
      // Ignore companion nodes (not repeaters)
      if (_isCompanionNode(echoSource)) {
        _debugLog.logInfo('📱 Ignoring companion node echo: $echoSource');
        return;
      }
      
      // Get the oldest pending ping
      final pingMsg = _pendingPings.keys.first;
      final completer = _pendingPings.remove(pingMsg);
      
      if (completer == null || completer.isCompleted) {
        print('⚠️ Completer was null or already completed');
        return;
      }
      
      // Check if this is from ignored repeater
      if (_ignoredRepeaterPrefix != null && 
          echoSource.toUpperCase().startsWith(_ignoredRepeaterPrefix!.toUpperCase())) {
        _debugLog.logInfo('Ignoring repeat from mobile repeater: $echoSource');
        // Don't complete - wait for other repeaters
        _pendingPings[pingMsg] = completer;
        return;
      }
      
      // Do NOT request contact details here; some firmware returns full contact list.
      // We rely on the connect-time contact load or manual scan to populate repeater details.
      
      // Repeater echo verifies good connection - complete the ping immediately
      _debugLog.logPing('🔁 Heard repeat from $echoSource! SNR: $snr RSSI: $rssi');
      print('🔁 Heard repeat from $echoSource! SNR: $snr, RSSI: $rssi');
      
      final result = PingResult(
        timestamp: DateTime.now(),
        status: PingStatus.success,
        rssi: rssi,
        snr: snr,
        nodeId: echoSource,
      );
      
      completer.complete(result);
      _pingResultController.add(result);
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

  /// Send binary frame to device (handles BLE vs USB frame formats)
  Future<void> _sendBinaryToDevice(Uint8List data) async {
    try {
      _debugLog.logLoRa('📤 TX: ${data.length} bytes - ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).take(20).join(' ')}${data.length > 20 ? '...' : ''}');
      
      if (_connectionType == ConnectionType.bluetooth && _txCharacteristic != null) {
        // BLE: Send the raw frame data without wrapper
        await _txCharacteristic!.write(data.toList());
        _debugLog.logLoRa('✅ BLE write complete');
      } else if (_connectionType == ConnectionType.usb && _usbPort != null) {
        // USB: Data should already have '< + length' wrapper
        await _usbPort!.write(data);
        _debugLog.logLoRa('✅ USB write complete');
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

  Future<void> disconnectDevice() async {
    try {
      _stopBatteryMonitoring();
      await _deviceSubscription?.cancel();
      
      if (_connectionType == ConnectionType.bluetooth && _bluetoothDevice != null) {
        await _bluetoothDevice!.disconnect();
      } else if (_connectionType == ConnectionType.usb && _usbPort != null) {
        await _usbPort!.close();
      }

      _bluetoothDevice = null;
      _txCharacteristic = null;
      _rxCharacteristic = null;
      _usbPort = null;
      _connectionType = ConnectionType.none;
      print('LoRa device disconnected');
    } catch (e) {
      print('Error disconnecting device: $e');
    }
  }

  Future<void> disconnectMqtt() async {
    // MQTT removed - no-op
  }


  void dispose() {
    disconnectDevice();
    _pingResultController.close();
    _batteryController.close();
  }
}
