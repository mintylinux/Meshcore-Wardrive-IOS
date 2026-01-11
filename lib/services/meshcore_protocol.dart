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
const int RESP_CODE_EXPORT_CONTACT = 11;
const int RESP_CODE_BATT_AND_STORAGE = 12;

// Push codes (radio -> app, unsolicited)
const int PUSH_CODE_ADVERT = 0x80;
const int PUSH_CODE_NEW_CONTACT = 0x81;
const int PUSH_CODE_CONTACT_UPDATED = 0x82;
const int PUSH_CODE_MSG_WAITING = 0x83;
const int PUSH_CODE_ACK_RECV = 0x84;
const int PUSH_CODE_CHANNEL_MSG_RECV = 0x85;
const int PUSH_CODE_CHANNEL_ECHO = 0x88;  // Channel message echo/repeat (136 decimal)

// Advertisement types
const int ADV_TYPE_CHAT = 1;
const int ADV_TYPE_REPEATER = 2;
const int ADV_TYPE_ROOM_SERVER = 3;

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
      
      print('📻 Raw log frame: SNR=${snr} (raw=$snrRaw), RSSI=$rssi');
      
      // If there's more data, it's the raw packet - try to parse sender/repeater
      String? sender;
      String? repeater;
      Uint8List? senderKey;
      Uint8List? repeaterKey;
      
      if (data.length > 34) { // At least channel(1) + sender(32) + pathLen(1)
        int offset = 2;
        
        // Channel index
        final channelIdx = data[offset++];
        
        // Sender public key (32 bytes)
        if (data.length >= offset + 32) {
          senderKey = Uint8List.fromList(data.sublist(offset, offset + 32));
          sender = senderKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').substring(0, 8).toUpperCase();
          offset += 32;
        }
        
        // Path length
        if (data.length > offset) {
          final pathLen = data[offset++];
          
          // First repeater key if path exists
          if (pathLen > 0 && data.length >= offset + 32) {
            repeaterKey = Uint8List.fromList(data.sublist(offset, offset + 32));
            repeater = repeaterKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').substring(0, 8).toUpperCase();
          }
        }
        
        print('  Parsed packet: channel=$channelIdx, sender=$sender, repeater=$repeater');
      }
      
      return {
        'snr': snr,
        'rssi': rssi,
        'sender': sender,
        'senderKey': senderKey,
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
}
