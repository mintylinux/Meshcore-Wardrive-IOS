import 'package:latlong2/latlong.dart';

class Sample {
  final String id;
  final LatLng position;
  final DateTime timestamp;
  final String? path;
  final String geohash;
  final int? rssi;
  final int? snr;
  final bool? pingSuccess;

  Sample({
    required this.id,
    required this.position,
    required this.timestamp,
    this.path,
    required this.geohash,
    this.rssi,
    this.snr,
    this.pingSuccess,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': position.latitude,
        'lon': position.longitude,
        'timestamp': timestamp.toIso8601String(),
        'path': path,
        'geohash': geohash,
        'rssi': rssi,
        'snr': snr,
        'pingSuccess': pingSuccess,
      };

  factory Sample.fromJson(Map<String, dynamic> json) {
    return Sample(
      id: json['id'] as String,
      position: LatLng(json['lat'] as double, json['lon'] as double),
      timestamp: DateTime.parse(json['timestamp'] as String),
      path: json['path'] as String?,
      geohash: json['geohash'] as String,
      rssi: json['rssi'] as int?,
      snr: json['snr'] as int?,
      pingSuccess: json['pingSuccess'] as bool?,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'lat': position.latitude,
        'lon': position.longitude,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'path': path,
        'geohash': geohash,
        'rssi': rssi,
        'snr': snr,
        'pingSuccess': pingSuccess == true ? 1 : (pingSuccess == false ? 0 : null),
      };

  factory Sample.fromMap(Map<String, dynamic> map) {
    final pingSuccessInt = map['pingSuccess'] as int?;
    return Sample(
      id: map['id'] as String,
      position: LatLng(map['lat'] as double, map['lon'] as double),
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      path: map['path'] as String?,
      geohash: map['geohash'] as String,
      rssi: map['rssi'] as int?,
      snr: map['snr'] as int?,
      pingSuccess: pingSuccessInt == null ? null : pingSuccessInt == 1,
    );
  }
}

class Coverage {
  final String id; // geohash
  final LatLng position;
  double received; // Changed to double to support weighted samples
  double lost;     // Changed to double to support weighted samples
  DateTime? lastReceived;
  DateTime? updated;
  List<String> repeaters;

  Coverage({
    required this.id,
    required this.position,
    this.received = 0.0,
    this.lost = 0.0,
    this.lastReceived,
    this.updated,
    List<String>? repeaters,
  }) : repeaters = repeaters ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': position.latitude,
        'lon': position.longitude,
        'rcv': received,
        'lost': lost,
        'lht': lastReceived?.millisecondsSinceEpoch,
        'ut': updated?.millisecondsSinceEpoch,
        'rptr': repeaters,
      };

  factory Coverage.fromJson(Map<String, dynamic> json) {
    return Coverage(
      id: json['id'] as String,
      position: LatLng(json['lat'] as double, json['lon'] as double),
      received: (json['rcv'] as num?)?.toDouble() ?? 0.0,
      lost: (json['lost'] as num?)?.toDouble() ?? 0.0,
      lastReceived: json['lht'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['lht'] as int)
          : null,
      updated: json['ut'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['ut'] as int)
          : null,
      repeaters: (json['rptr'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

class Repeater {
  final String id;
  final LatLng position;
  final double? elevation;
  final DateTime? timestamp;
  final String? name;
  final int? rssi;
  final int? snr;
  final double? distance;

  Repeater({
    required this.id,
    required this.position,
    this.elevation,
    this.timestamp,
    this.name,
    this.rssi,
    this.snr,
    this.distance,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': position.latitude,
        'lon': position.longitude,
        'elevation': elevation,
        'timestamp': timestamp?.toIso8601String(),
        'name': name,
        'rssi': rssi,
        'snr': snr,
        'distance': distance,
      };

  factory Repeater.fromJson(Map<String, dynamic> json) {
    return Repeater(
      id: json['id'] as String,
      position: LatLng(json['lat'] as double, json['lon'] as double),
      elevation: json['elevation'] as double?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
      name: json['name'] as String?,
      rssi: json['rssi'] as int?,
      snr: json['snr'] as int?,
      distance: json['distance'] as double?,
    );
  }
}

class Edge {
  final Coverage coverage;
  final Repeater repeater;

  Edge({
    required this.coverage,
    required this.repeater,
  });
}

class NodeData {
  final List<Sample> samples;
  final List<Repeater> repeaters;

  NodeData({
    required this.samples,
    required this.repeaters,
  });

  factory NodeData.fromJson(Map<String, dynamic> json) {
    return NodeData(
      samples: (json['samples'] as List<dynamic>?)
              ?.map((s) => Sample.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      repeaters: (json['repeaters'] as List<dynamic>?)
              ?.map((r) => Repeater.fromJson(r as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

