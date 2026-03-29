import 'dart:typed_data';

/// MeshCore Companion Radio Binary Protocol
/// Protocol spec: https://github.com/meshcore-dev/MeshCore/wiki/Companion-Radio-Protocol

// Frame delimiters
const int FRAME_START_OUTBOUND = 0x3E; // '>' - radio -> app
const int FRAME_START_INBOUND = 0x3C;  // '<' - app -> radio

// Command codes (app -> radio) - from companion_radio/main.cpp
const int CMD_APP_START = 1;
const int CMD_SEND_MESSAGE = 2;  // CMD_SEND_TXT_MSG
const int CMD_SEND_CHANNEL_MESSAGE = 3;  // CMD_SEND_CHANNEL_TXT_MSG  
const int CMD_GET_CONTACTS = 4;
const int CMD_SEND_ADVERT = 7;  // CMD_SEND_SELF_ADVERT
const int CMD_SET_CHANNEL = 8;  // CMD_SET_ADVERT_NAME
const int CMD_GET_CHANNEL = 31;  // Get channel info by index
const int CMD_SET_CHANNEL_CONFIG = 32;  // Set channel configuration
const int CMD_SYNC_NEXT_MESSAGE = 10;
const int CMD_ADD_UPDATE_CONTACT = 9;
const int CMD_REMOVE_CONTACT = 15;
const int CMD_SET_NAME = 19;
const int CMD_SET_POSITION = 20;
const int CMD_GET_BATT_AND_STORAGE = 20;  // CMD_GET_BATTERY_VOLTAGE
const int CMD_SEND_LOGIN = 26;  // Send login to repeater/room server
const int CMD_SEND_STATUS_REQ = 27;  // Send status/data request after login
const int CMD_GET_CONTACT_BY_KEY = 30;  // Get contact by public key
const int CMD_SEND_BINARY_REQ = 50;  // Send arbitrary binary request to a contact
const int CMD_SEND_CONTROL_DATA = 55;
const int CMD_SEND_ANON_REQ = 57;  // Send anonymous request (for basic info)

// Response codes (radio -> app)
const int RESP_CODE_OK = 0;
const int RESP_CODE_ERR = 1;
const int RESP_CODE_APP_START = 2;
const int RESP_CODE_CONTACT = 3;
const int RESP_CODE_END_OF_CONTACTS = 4;
const int RESP_CODE_SELF_INFO = 5;
const int RESP_CODE_SENT = 6;
const int RESP_CODE_CHANNEL_INFO = 18;
const int RESP_CODE_CONTACT_MSG_RECV = 7;
const int RESP_CODE_CHANNEL_MSG_RECV = 8;
const int RESP_CODE_NO_MORE_MESSAGES = 10;
const int RESP_CODE_CHANNEL_MSG_RECV_V3 = 17;
const int RESP_CODE_EXPORT_CONTACT = 11;
const int RESP_CODE_BATT_AND_STORAGE = 12;

// Push codes (radio -> app, unsolicited)
const int PUSH_CODE_ADVERT = 0x80;
const int PUSH_CODE_PATH_UPDATED = 0x81;
const int PUSH_CODE_SEND_CONFIRMED = 0x82;
const int PUSH_CODE_MSG_WAITING = 0x83;
const int PUSH_CODE_RAW_DATA = 0x84;
const int PUSH_CODE_LOGIN_SUCCESS = 0x85;     // Login to repeater succeeded
const int PUSH_CODE_LOGIN_FAIL = 0x86;        // Login to repeater failed
const int PUSH_CODE_STATUS_RESPONSE = 0x87;   // Response to CMD_SEND_STATUS_REQ
const int PUSH_CODE_LOG_RX_DATA = 0x88;       // Raw radio log frame
const int PUSH_CODE_TRACE_DATA = 0x89;
const int PUSH_CODE_NEW_ADVERT = 0x8A;
const int PUSH_CODE_TELEMETRY_RESPONSE = 0x8B;
const int PUSH_CODE_BINARY_RESPONSE = 0x8C;   // Response to CMD_SEND_BINARY_REQ
const int PUSH_CODE_PATH_DISCOVERY_RESPONSE = 0x8D;
const int PUSH_CODE_CONTROL_DATA = 0x8E;      // Control data packet received
const int PUSH_CODE_CONTACT_DELETED = 0x8F;
const int PUSH_CODE_CONTACTS_FULL = 0x90;

// Legacy aliases — kept so existing handlers still compile
const int PUSH_CODE_NEW_CONTACT = PUSH_CODE_PATH_UPDATED;      // 0x81
const int PUSH_CODE_CONTACT_UPDATED = PUSH_CODE_SEND_CONFIRMED; // 0x82
const int PUSH_CODE_ACK_RECV = PUSH_CODE_RAW_DATA;              // 0x84
const int PUSH_CODE_CHANNEL_MSG_RECV = PUSH_CODE_LOGIN_SUCCESS;  // 0x85 (reused code)
const int PUSH_CODE_CHANNEL_ECHO = PUSH_CODE_LOG_RX_DATA;       // 0x88

// Advertisement types
const int ADV_TYPE_CHAT = 1;
const int ADV_TYPE_REPEATER = 2;
const int ADV_TYPE_ROOM_SERVER = 3;

// Text message types (CMD_SEND_MESSAGE txt_type field)
const int TXT_TYPE_PLAIN = 0;
const int TXT_TYPE_CLI_DATA = 1;

// Control data sub-types
const int CONTROL_SUBTYPE_DISCOVER_REQ = 0x8;
const int CONTROL_SUBTYPE_DISCOVER_RESP = 0x9;

// Repeater request types (used with CMD_SEND_STATUS_REQ after login)
const int REQ_TYPE_GET_STATUS = 0x01;
const int REQ_TYPE_KEEP_ALIVE = 0x02;
const int REQ_TYPE_GET_TELEMETRY_DATA = 0x03;
const int REQ_TYPE_GET_ACCESS_LIST = 0x05;
const int REQ_TYPE_GET_NEIGHBOURS = 0x06;
const int REQ_TYPE_GET_OWNER_INFO = 0x07;

// Repeater response for login
const int RESP_SERVER_LOGIN_OK = 0;

class MeshCoreFrame {
  final int code;
  final Uint8List data;

  MeshCoreFrame(this.code, this.data);

  int get length => data.length;
}

class MeshCoreContact {
  final Uint8List publicKey; // 32 bytes
  final int advType;
  final int flags;
  final int outPathLen;
  final Uint8List outPath; // 64 bytes
  final String? advName;
  final int? lastAdvert; // Unix timestamp
  final double? advLat;
  final double? advLon;

  MeshCoreContact({
    required this.publicKey,
    required this.advType,
    required this.flags,
    required this.outPathLen,
    required this.outPath,
    this.advName,
    this.lastAdvert,
    this.advLat,
    this.advLon,
  });

  String get publicKeyHex => publicKey
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join('');

  String get publicKeyPrefix => publicKeyHex.substring(0, 8).toUpperCase();

  bool get hasPosition => advLat != null && advLon != null;
}

class MeshCoreProtocol {
  final BytesBuilder _buffer = BytesBuilder();
  bool _useBLEMode = false;  // If true, parse unwrapped BLE frames
  
  /// Set protocol mode: BLE (unwrapped) vs USB (wrapped with '>')
  void setBLEMode(bool enabled) {
    _useBLEMode = enabled;
  }
  
  /// Parse incoming data and extract complete frames
  List<MeshCoreFrame> parseIncomingData(Uint8List data) {
    _buffer.add(data);
    final List<MeshCoreFrame> frames = [];

    if (_useBLEMode) {
      // BLE mode: frames are unwrapped [code] [payload...]
      // Each chunk of data is one complete frame
      final bytes = _buffer.toBytes();
      if (bytes.isNotEmpty) {
        final code = bytes[0];
        final payload = bytes.length > 1 
            ? Uint8List.fromList(bytes.sublist(1))
            : Uint8List(0);
        frames.add(MeshCoreFrame(code, payload));
      }
      _buffer.clear();
    } else {
      // USB mode: frames have wrapper '>' + length(2 bytes LE) + [code] [payload]
      while (true) {
        final bytes = _buffer.toBytes();
        if (bytes.isEmpty) break;

        // Look for frame start marker '>'
        final startIdx = bytes.indexOf(FRAME_START_OUTBOUND);
        if (startIdx == -1) {
          // No frame start found, clear invalid data
          _buffer.clear();
          break;
        }

        // Remove data before frame start
        if (startIdx > 0) {
          final remaining = bytes.sublist(startIdx);
          _buffer.clear();
          _buffer.add(remaining);
          continue;
        }

        // Need at least 3 bytes: start marker + 2 bytes length
        if (bytes.length < 3) break;

        // Read frame length (little-endian uint16)
        final frameLength = bytes[1] | (bytes[2] << 8);

        // Check if we have the complete frame
        if (bytes.length < 3 + frameLength) break; // Wait for more data

        // Extract frame data
        final frameData = Uint8List.fromList(bytes.sublist(3, 3 + frameLength));
        
        if (frameData.isNotEmpty) {
          final code = frameData[0];
          final payload = frameData.length > 1 
              ? Uint8List.fromList(frameData.sublist(1))
              : Uint8List(0);
          
          frames.add(MeshCoreFrame(code, payload));
        }

        // Remove processed frame from buffer
        final remaining = bytes.sublist(3 + frameLength);
        _buffer.clear();
        if (remaining.isNotEmpty) {
          _buffer.add(remaining);
        }
      }
    }

    return frames;
  }

  /// Create a command frame to send to the device (USB format with wrapper)
  Uint8List createCommandFrame(int commandCode, [Uint8List? payload]) {
    final frameData = BytesBuilder();
    frameData.addByte(commandCode);
    if (payload != null && payload.isNotEmpty) {
      frameData.add(payload);
    }

    final frameBytes = frameData.toBytes();
    final length = frameBytes.length;

    // Build complete frame: '<' + length(2 bytes LE) + frame data
    final result = BytesBuilder();
    result.addByte(FRAME_START_INBOUND);
    result.addByte(length & 0xFF); // Low byte
    result.addByte((length >> 8) & 0xFF); // High byte
    result.add(frameBytes);

    return result.toBytes();
  }

  /// Create a command frame for BLE (no wrapper, just frame data)
  Uint8List createCommandFrameBLE(int commandCode, [Uint8List? payload]) {
    final frameData = BytesBuilder();
    frameData.addByte(commandCode);
    if (payload != null && payload.isNotEmpty) {
      frameData.add(payload);
    }
    return frameData.toBytes();
  }

  /// Parse RESP_CODE_CONTACT frame data
  MeshCoreContact? parseContactFrame(Uint8List data) {
    try {
      if (data.length < 99) return null; // Minimum size

      int offset = 0;

      // Public key (32 bytes)
      final publicKey = data.sublist(offset, offset + 32);
      offset += 32;

      // Type (1 byte)
      final advType = data[offset++];

      // Flags (1 byte)
      final flags = data[offset++];

      // Out path length (1 byte, signed)
      final outPathLen = data[offset++];

      // Out path (64 bytes)
      final outPath = data.sublist(offset, offset + 64);
      offset += 64;

      // Name (32 bytes, null-terminated string)
      String? advName;
      final nameBytes = data.sublist(offset, offset + 32);
      final nullIdx = nameBytes.indexOf(0);
      if (nullIdx > 0) {
        advName = String.fromCharCodes(nameBytes.sublist(0, nullIdx));
      }
      offset += 32;

      // Optional fields (if frame is long enough)
      int? lastAdvert;
      double? advLat;
      double? advLon;

      if (data.length >= offset + 4) {
        // Last advert timestamp (4 bytes, uint32 LE)
        lastAdvert = data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24);
        offset += 4;
      }

      if (data.length >= offset + 8) {
        // Latitude (4 bytes, int32 LE, * 1E6)
        final latInt = data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24);
        advLat = _int32ToSigned(latInt) / 1000000.0;
        offset += 4;

        // Longitude (4 bytes, int32 LE, * 1E6)
        final lonInt = data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24);
        advLon = _int32ToSigned(lonInt) / 1000000.0;
        offset += 4;
      }

      return MeshCoreContact(
        publicKey: publicKey,
        advType: advType,
        flags: flags,
        outPathLen: outPathLen,
        outPath: outPath,
        advName: advName,
        lastAdvert: lastAdvert,
        advLat: advLat,
        advLon: advLon,
      );
    } catch (e) {
      print('Error parsing contact frame: $e');
      return null;
    }
  }

  /// Convert uint32 to signed int32
  int _int32ToSigned(int value) {
    if (value > 0x7FFFFFFF) {
      return value - 0x100000000;
    }
    return value;
  }

  /// Parse PUSH_CODE_ADVERT frame (contains 32-byte public key)
  Uint8List? parseAdvertFrame(Uint8List data) {
    if (data.length >= 32) {
      return data.sublist(0, 32);
    }
    return null;
  }

  /// Parse RESP_CODE_CHANNEL_INFO frame
  /// Returns map with 'index', 'name', 'key'
  Map<String, dynamic>? parseChannelInfoFrame(Uint8List data) {
    try {
      if (data.length < 49) return null; // 1 + 32 + 16 minimum
      
      int offset = 0;
      
      // Channel index (1 byte)
      final index = data[offset++];
      
      // Channel name (32 bytes, null-terminated)
      final nameBytes = data.sublist(offset, offset + 32);
      final nullIdx = nameBytes.indexOf(0);
      final name = nullIdx >= 0 
          ? String.fromCharCodes(nameBytes.sublist(0, nullIdx))
          : String.fromCharCodes(nameBytes);
      offset += 32;
      
      // Channel key (16 bytes)
      final key = data.sublist(offset, offset + 16);
      offset += 16;
      
      return {
        'index': index,
        'name': name,
        'key': key,
      };
    } catch (e) {
      print('Error parsing channel info frame: $e');
      return null;
    }
  }

  /// Create CMD_GET_CHANNEL command to query channel at specific index
  Uint8List createGetChannelPayload(int channelIdx) {
    final payload = BytesBuilder();
    payload.addByte(channelIdx);
    return payload.toBytes();
  }

  /// Create CMD_SET_CHANNEL payload
  /// channelIdx: 0-3 (channel slot)
  /// channelName: name like "#wardrive" (max 31 bytes)
  /// channelKey: 16-byte encryption key
  /// Returns payload only - caller must wrap with createCommandFrame() or createCommandFrameBLE()
  Uint8List createSetChannelPayload(int channelIdx, String channelName, Uint8List channelKey) {
    if (channelKey.length != 16) {
      throw ArgumentError('Channel key must be 16 bytes');
    }
    
    final payload = BytesBuilder();
    payload.addByte(channelIdx);
    
    // Channel name (32 bytes, null-terminated)
    final nameBytes = Uint8List(32);
    final encoded = channelName.codeUnits;
    final len = encoded.length < 31 ? encoded.length : 31;
    for (int i = 0; i < len; i++) {
      nameBytes[i] = encoded[i];
    }
    payload.add(nameBytes);
    
    // Channel key (16 bytes)
    payload.add(channelKey);
    
    return payload.toBytes();
  }

  /// Create CMD_SET_POSITION payload
  /// lat/lon: GPS coordinates in degrees
  /// Returns payload only - caller must wrap with createCommandFrame() or createCommandFrameBLE()
  Uint8List createPositionPayload(double latitude, double longitude) {
    final payload = BytesBuilder();
    
    // Latitude as int32 (degrees * 1E6, little-endian)
    final latInt = (latitude * 1000000).round();
    payload.addByte(latInt & 0xFF);
    payload.addByte((latInt >> 8) & 0xFF);
    payload.addByte((latInt >> 16) & 0xFF);
    payload.addByte((latInt >> 24) & 0xFF);
    
    // Longitude as int32 (degrees * 1E6, little-endian)
    final lonInt = (longitude * 1000000).round();
    payload.addByte(lonInt & 0xFF);
    payload.addByte((lonInt >> 8) & 0xFF);
    payload.addByte((lonInt >> 16) & 0xFF);
    payload.addByte((lonInt >> 24) & 0xFF);
    
    return payload.toBytes();
  }

  /// Create CMD_SEND_CHANNEL_MESSAGE payload
  /// channelIdx: 0-3 (channel slot)
  /// message: text message to send  
  /// Returns payload only - caller must wrap with createCommandFrame() or createCommandFrameBLE()
  Uint8List createChannelMessagePayload(int channelIdx, String message, {int txtType = 0}) {
    final payload = BytesBuilder();
    
    // txtType (1 byte) - 0 = plain text
    payload.addByte(txtType);
    
    // channelIdx (1 byte)
    payload.addByte(channelIdx);
    
    // senderTimestamp (4 bytes, uint32 LE) - epoch seconds
    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
    payload.addByte(timestamp & 0xFF);
    payload.addByte((timestamp >> 8) & 0xFF);
    payload.addByte((timestamp >> 16) & 0xFF);
    payload.addByte((timestamp >> 24) & 0xFF);
    
    // Message text (null-terminated)
    final msgBytes = message.codeUnits;
    payload.add(Uint8List.fromList(msgBytes));
    payload.addByte(0); // Null terminator
    
    return payload.toBytes();
  }

  /// Parse PUSH_CODE_LOG_RX_DATA (0x88) - raw radio log frame
  /// Format: [SNR] [RSSI] [raw_packet_bytes...]
  /// Raw packet format: [header(1)] [transport_codes(4)-optional] [path_len(1)] [path(path_len)] [payload...]
  /// SNR is multiplied by 4 in firmware, RSSI is raw value
  /// Returns map with 'snr', 'rssi', and parsed packet data if available
  Map<String, dynamic>? parseRawLogFrame(Uint8List data) {
    try {
      if (data.length < 2) {
        print('⚠️ Raw log frame too short: ${data.length} bytes');
        return null;
      }
      
      // SNR at byte 0 (scaled by 4x in firmware)
      final snrRaw = data[0];
      final snr = (snrRaw / 4.0).round(); // Convert back to actual SNR
      
      // RSSI at byte 1 (raw value)
      int rssi = data[1];
      if (rssi > 127) rssi -= 256; // Convert to signed byte
      
      print('📻 Raw log frame: SNR=${snr} (raw=$snrRaw), RSSI=$rssi, total=${data.length} bytes');
      
      // Parse raw MeshCore packet structure
      // Frame is: [SNR][RSSI][raw_packet...]
      // Raw packet is: [header][transport_codes?][pathLen][path...][payload...]
      String? repeater;
      Uint8List? repeaterKey;
      
      if (data.length > 4) { // Need at least SNR+RSSI+header+pathLen
        int offset = 2; // Skip SNR/RSSI
        
        // Parse packet header
        final header = data[offset++];
        final routeType = header & 0x03;
        final hasTransportCodes = routeType == 0x00 || routeType == 0x03;
        
        // Skip transport codes if present (4 bytes)
        if (hasTransportCodes) {
          if (data.length < offset + 4) {
            print('  Not enough data for transport codes');
            return {'snr': snr, 'rssi': rssi, 'sender': null, 'repeater': null, 'repeaterKey': null};
          }
          offset += 4;
        }
        
        // Read path_len (signed byte)
        if (data.length <= offset) {
          print('  No pathLen byte');
          return {'snr': snr, 'rssi': rssi, 'sender': null, 'repeater': null, 'repeaterKey': null};
        }
        
        int pathLen = data[offset++];
        // Convert unsigned byte to signed
        if (pathLen > 127) pathLen -= 256;
        print('  header=0x${header.toRadixString(16)}, routeType=$routeType, hasTransport=$hasTransportCodes, pathLen=$pathLen');
        
        // IMPORTANT: Flood packets with built-up paths store 1-byte prefixes per hop!
        // Direct packets (routeType=0x02) have full 32-byte keys per hop
        // Get LAST hop in path (most recent repeater)
        if (pathLen > 0 && routeType == 0x01) { // ROUTE_TYPE_FLOOD
          if (data.length >= offset + pathLen) {
            // Extract last byte from path (last repeater's 1-byte prefix)
            final lastHopByte = data[offset + pathLen - 1];
            repeater = lastHopByte.toRadixString(16).padLeft(2, '0').toUpperCase();
            print('  🎯 FLOOD packet with path! Last hop (${pathLen} hops): $repeater');
          } else {
            print('  Path exists but data too short: pathLen=$pathLen, available=${data.length - offset}');
          }
        } else if (pathLen > 0 && routeType == 0x02) { // ROUTE_TYPE_DIRECT  
          // Direct routes have full 32-byte keys (not used in wardrive typically)
          print('  Direct route with full keys (pathLen=$pathLen)');
        } else if (pathLen == 0 || pathLen < 0) {
          print('  Zero-hop packet (direct/flood with no path built)');
        }
      }
      
      return {
        'snr': snr,
        'rssi': rssi,
        'sender': null, // Not extracting sender from encrypted payload, use repeater instead
        'repeater': repeater,
        'repeaterKey': repeaterKey,
      };
    } catch (e) {
      print('Error parsing raw log frame: $e');
      return null;
    }
  }
  
  /// Parse PUSH_CODE_CHANNEL_MSG_RECV or PUSH_CODE_CHANNEL_ECHO frame
  /// Returns map with 'text', 'repeater' (first repeater public key hex), 'snr', 'rssi'
  Map<String, dynamic>? parseChannelMessageFrame(Uint8List data, {bool isEcho = false}) {
    try {
      // Debug: dump full payload
      print('🔍 Channel msg payload (${data.length} bytes): ${data.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
      
      int offset = 0;
      
      // Echo frames have additional header: [seq(2)] [flags(1)] before channel data
      if (isEcho && data.length >= 3) {
        final seq = data[offset] | (data[offset + 1] << 8);
        offset += 2;
        final flags = data[offset++];
        print('  echo: seq=$seq flags=0x${flags.toRadixString(16)}');
      }
      
      if (data.length < offset + 33) {
        print('⚠️ Payload too short: ${data.length} bytes (need at least ${offset + 33})');
        print('⚠️ Raw hex dump: ${data.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
        print('⚠️ isEcho=$isEcho, offset=$offset after header');
        return null;
      }
      
      // Channel index (1 byte)
      final channelIdx = data[offset++];
      print('  channelIdx=$channelIdx');
      
      
      // Sender public key (32 bytes)
      final senderKey = data.sublist(offset, offset + 32);
      final senderHex = senderKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
      print('  sender=${senderHex.substring(0, 8)}');
      offset += 32;
      
      // Path length (1 byte)
      final pathLen = data[offset++];
      print('  pathLen=$pathLen');
      
      // Path (pathLen * 32 bytes) - get first repeater
      String? firstRepeater;
      Uint8List? firstRepeaterFullKey;
      
      if (pathLen > 0 && data.length >= offset + 32) {
        final firstRepeaterKey = data.sublist(offset, offset + 32);
        firstRepeaterFullKey = Uint8List.fromList(firstRepeaterKey);
        firstRepeater = firstRepeaterKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').substring(0, 8).toUpperCase();
        print('  repeater=$firstRepeater');
        offset += pathLen * 32;
      } else if (pathLen > 0) {
        // Skip path if not enough data
        offset += pathLen * 32;
      }
      
      // SNR/RSSI always follow path (2 bytes each, signed)
      int? snr;
      int? rssi;
      if (data.length >= offset + 4) {
        snr = data[offset] | (data[offset + 1] << 8);
        if (snr > 32767) snr -= 65536; // Convert to signed
        offset += 2;
        
        rssi = data[offset] | (data[offset + 1] << 8);
        if (rssi > 32767) rssi -= 65536; // Convert to signed
        offset += 2;
        print('  snr=$snr, rssi=$rssi');
      }
      
      // Message text (remaining bytes, null-terminated)
      String? text;
      if (offset < data.length) {
        final textBytes = data.sublist(offset);
        final nullIdx = textBytes.indexOf(0);
        if (nullIdx >= 0) {
          text = String.fromCharCodes(textBytes.sublist(0, nullIdx));
        } else {
          text = String.fromCharCodes(textBytes);
        }
      }
      
      return {
        'channelIdx': channelIdx,
        'sender': senderHex.substring(0, 8).toUpperCase(),
        'senderKey': senderKey,  // Full 32-byte sender key
        'text': text,
        'repeater': firstRepeater,
        'repeaterKey': firstRepeaterFullKey,  // Full 32-byte key for contact requests
        'snr': snr,
        'rssi': rssi,
      };
    } catch (e) {
      print('Error parsing channel message frame: $e');
      return null;
    }
  }

  /// Create CMD_SEND_CONTROL_DATA payload for DISCOVER_REQ
  /// tag: 4-byte random identifier to match responses
  /// prefixOnly: if true, responses will contain 8-byte pubkey prefix instead of full 32 bytes
  Uint8List createDiscoveryRequestPayload(int tag, {bool prefixOnly = true}) {
    final payload = BytesBuilder();
    
    // flags byte: upper 4 bits = sub_type (0x8), lower bit 0 = prefix_only flag
    final flags = (CONTROL_SUBTYPE_DISCOVER_REQ << 4) | (prefixOnly ? 0x01 : 0x00);
    payload.addByte(flags);
    
    // type_filter: BITMASK for node types (bit 2 = repeaters, so 1 << 2 = 0x04)
    payload.addByte(1 << ADV_TYPE_REPEATER);
    
    // tag: 4 bytes (little-endian uint32)
    payload.addByte(tag & 0xFF);
    payload.addByte((tag >> 8) & 0xFF);
    payload.addByte((tag >> 16) & 0xFF);
    payload.addByte((tag >> 24) & 0xFF);
    
    // since: 4 bytes (optional, default 0 = all repeaters)
    payload.addByte(0);
    payload.addByte(0);
    payload.addByte(0);
    payload.addByte(0);
    
    return payload.toBytes();
  }

  /// Parse PUSH_CODE_CONTROL_DATA (0x8E) frame
  /// Format: [SNR*4 (signed)] [RSSI (signed)] [path_len] [path...] [payload...]
  /// Returns map with 'snr', 'rssi', 'path_len', 'payload'
  Map<String, dynamic>? parseControlDataPush(Uint8List data) {
    try {
      if (data.length < 3) {
        print('⚠️ Control data push too short: ${data.length} bytes');
        return null;
      }
      
      int offset = 0;
      
      // SNR at byte 0 (scaled by 4x)
      int snrRaw = data[offset++];
      if (snrRaw > 127) snrRaw -= 256; // Convert to signed
      final snr = (snrRaw / 4.0).round();
      
      // RSSI at byte 1 (signed)
      int rssi = data[offset++];
      if (rssi > 127) rssi -= 256;
      
      // Path length at byte 2
      final pathLen = data[offset++];
      
      // Skip path bytes if present
      if (data.length < offset + pathLen) {
        print('⚠️ Control data: not enough data for path');
        return null;
      }
      offset += pathLen;
      
      // Remaining bytes are the payload
      final payload = data.length > offset 
          ? Uint8List.fromList(data.sublist(offset))
          : Uint8List(0);
      
      return {
        'snr': snr,
        'rssi': rssi,
        'path_len': pathLen,
        'payload': payload,
      };
    } catch (e) {
      print('Error parsing control data push: $e');
      return null;
    }
  }

  /// Parse DISCOVER_RESP payload from control data
  /// Returns map with 'node_type', 'snr', 'tag', 'pubkey'
  Map<String, dynamic>? parseDiscoveryResponse(Uint8List payload) {
    try {
      if (payload.length < 6) {
        print('⚠️ Discovery response too short: ${payload.length} bytes');
        return null;
      }
      
      int offset = 0;
      
      // Flags byte: upper 4 bits = sub_type (0x9), lower 4 bits = node_type
      final flags = payload[offset++];
      final subType = (flags >> 4) & 0x0F;
      final nodeType = flags & 0x0F;
      
      if (subType != CONTROL_SUBTYPE_DISCOVER_RESP) {
        print('⚠️ Not a DISCOVER_RESP: sub_type=0x${subType.toRadixString(16)}');
        return null;
      }
      
      // SNR at byte 1 (already scaled by 4, signed)
      int snrRaw = payload[offset++];
      if (snrRaw > 127) snrRaw -= 256;
      final snr = (snrRaw / 4.0).round();
      
      // Tag: 4 bytes (little-endian uint32)
      if (payload.length < offset + 4) {
        print('⚠️ Discovery response: not enough data for tag');
        return null;
      }
      final tag = payload[offset] |
          (payload[offset + 1] << 8) |
          (payload[offset + 2] << 16) |
          (payload[offset + 3] << 24);
      offset += 4;
      
      // Public key: 8 or 32 bytes (depends on prefix_only flag in request)
      final pubkeyBytes = payload.sublist(offset);
      final pubkey = pubkeyBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('')
          .toUpperCase();
      
      return {
        'node_type': nodeType,
        'snr': snr,
        'tag': tag,
      'pubkey': pubkey,
      'pubkey_bytes': pubkeyBytes,
    };
    } catch (e) {
      print('Error parsing discovery response: $e');
      return null;
    }
  }

  // ============================================================================
  // CARPEATER MODE - Repeater login and neighbor operations
  // ============================================================================

  /// Create CMD_SEND_LOGIN payload to authenticate with a repeater
  Uint8List createLoginPayload(Uint8List recipientPubKey, String password) {
    if (recipientPubKey.length != 32) {
      throw ArgumentError('Recipient public key must be 32 bytes');
    }
    final payload = BytesBuilder();
    payload.add(recipientPubKey);
    final pwdBytes = password.codeUnits;
    final pwdLen = pwdBytes.length > 15 ? 15 : pwdBytes.length;
    for (int i = 0; i < pwdLen; i++) {
      payload.addByte(pwdBytes[i]);
    }
    return payload.toBytes();
  }

  /// Create CMD_SEND_MESSAGE payload for a CLI command to a logged-in repeater.
  /// Uses txt_type = TXT_TYPE_CLI_DATA so the repeater treats it as a command.
  Uint8List createCliCommandPayload(Uint8List recipientPubKey, String command) {
    if (recipientPubKey.length < 6) {
      throw ArgumentError('Recipient public key must be at least 6 bytes');
    }
    final payload = BytesBuilder();
    payload.addByte(TXT_TYPE_CLI_DATA);
    payload.addByte(0); // attempt = 0
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    payload.addByte(ts & 0xFF);
    payload.addByte((ts >> 8) & 0xFF);
    payload.addByte((ts >> 16) & 0xFF);
    payload.addByte((ts >> 24) & 0xFF);
    payload.add(recipientPubKey.sublist(0, 6));
    payload.add(Uint8List.fromList(command.codeUnits));
    return payload.toBytes();
  }

  /// Create CMD_SEND_BINARY_REQ payload.
  Uint8List createBinaryReqPayload(Uint8List recipientPubKey, Uint8List requestData) {
    if (recipientPubKey.length != 32) {
      throw ArgumentError('Recipient public key must be 32 bytes');
    }
    final payload = BytesBuilder();
    payload.add(recipientPubKey);
    payload.add(requestData);
    return payload.toBytes();
  }

  /// Build the inner request data for a GET_NEIGHBOURS binary request.
  Uint8List createGetNeighboursRequestData({
    int count = 32,
    int offset = 0,
    int orderBy = 0,
    int pubkeyPrefixLength = 8,
  }) {
    final data = BytesBuilder();
    data.addByte(REQ_TYPE_GET_NEIGHBOURS);
    data.addByte(0); // version = 0
    data.addByte(count);
    data.addByte(offset & 0xFF);
    data.addByte((offset >> 8) & 0xFF);
    data.addByte(orderBy);
    data.addByte(pubkeyPrefixLength);
    final rnd = DateTime.now().millisecondsSinceEpoch;
    data.addByte(rnd & 0xFF);
    data.addByte((rnd >> 8) & 0xFF);
    data.addByte((rnd >> 16) & 0xFF);
    data.addByte((rnd >> 24) & 0xFF);
    return data.toBytes();
  }

  /// Parse a PUSH_CODE_LOGIN_SUCCESS (0x85) frame.
  Map<String, dynamic>? parseLoginSuccessPush(Uint8List data) {
    try {
      if (data.length < 7) return null;
      int offset = 0;
      final isAdmin = data[offset++] != 0;
      final pubkeyPrefix = data.sublist(offset, offset + 6);
      offset += 6;
      int? serverTimestamp;
      int permissions = 0;
      int? firmwareVersion;
      if (data.length >= 14) {
        serverTimestamp = data[offset] | (data[offset + 1] << 8) |
            (data[offset + 2] << 16) | (data[offset + 3] << 24);
        offset += 4;
        permissions = data[offset++];
        firmwareVersion = data[offset++];
      }
      return {
        'success': true,
        'is_admin': isAdmin,
        'pubkey_prefix': pubkeyPrefix
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join('').toUpperCase(),
        'timestamp': serverTimestamp,
        'permissions': permissions,
        'firmware_version': firmwareVersion,
      };
    } catch (e) {
      print('Error parsing login success push: $e');
      return null;
    }
  }

  /// Parse a PUSH_CODE_LOGIN_FAIL (0x86) frame.
  Map<String, dynamic> parseLoginFailPush(Uint8List data) {
    String? prefix;
    if (data.length >= 7) {
      prefix = data.sublist(1, 7)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('').toUpperCase();
    }
    return {'success': false, 'error_code': 'rejected', 'pubkey_prefix': prefix};
  }

  /// Parse a PUSH_CODE_BINARY_RESPONSE (0x8C) containing GET_NEIGHBOURS reply.
  Map<String, dynamic>? parseBinaryResponseNeighbours(Uint8List data, int pubkeyPrefixLength) {
    try {
      if (data.length < 9) return null;
      int offset = 0;
      offset++; // reserved
      final tag = data[offset] | (data[offset + 1] << 8) |
          (data[offset + 2] << 16) | (data[offset + 3] << 24);
      offset += 4;
      final totalCount = data[offset] | (data[offset + 1] << 8);
      offset += 2;
      final resultCount = data[offset] | (data[offset + 1] << 8);
      offset += 2;
      final neighbours = <Map<String, dynamic>>[];
      final entrySize = pubkeyPrefixLength + 4 + 1;
      for (int i = 0; i < resultCount && offset + entrySize <= data.length; i++) {
        final pubkeyBytes = data.sublist(offset, offset + pubkeyPrefixLength);
        final pubkey = pubkeyBytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join('').toUpperCase();
        offset += pubkeyPrefixLength;
        final heardSecondsAgo = data[offset] | (data[offset + 1] << 8) |
            (data[offset + 2] << 16) | (data[offset + 3] << 24);
        offset += 4;
        int snrRaw = data[offset++];
        if (snrRaw > 127) snrRaw -= 256;
        final snr = snrRaw / 4.0;
        neighbours.add({
          'pubkey': pubkey,
          'pubkey_bytes': Uint8List.fromList(pubkeyBytes),
          'heard_seconds_ago': heardSecondsAgo,
          'snr': snr,
        });
      }
      return {
        'tag': tag,
        'total_count': totalCount,
        'result_count': resultCount,
        'neighbours': neighbours,
      };
    } catch (e) {
      print('Error parsing binary response neighbours: $e');
      return null;
    }
  }
}
