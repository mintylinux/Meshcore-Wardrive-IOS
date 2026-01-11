import 'dart:math';
import 'package:geohash_plus/geohash_plus.dart' as geohash;
import 'package:latlong2/latlong.dart';

class GeohashUtils {
  // Center position (Puget Sound area - matching the original)
  static const LatLng centerPos = LatLng(47.7776, -122.4247);
  static const double maxDistanceMiles = 60.0;

  /// Generate a geohash for samples (8 character precision)
  static String sampleKey(double lat, double lon) {
    return geohash.GeoHash.encode(lat, lon, precision: 8).hash;
  }

  /// Generate a geohash for coverage areas with configurable precision
  /// Precision 4: ~20km x 20km (regional overview)
  /// Precision 5: ~5km x 5km (city-level)
  /// Precision 6: ~1.2km x 610m (default, neighborhood)
  /// Precision 7: ~153m x 153m (street-level)
  /// Precision 8: ~38m x 19m (building-level)
  static String coverageKey(double lat, double lon, {int precision = 6}) {
    return geohash.GeoHash.encode(lat, lon, precision: precision).hash;
  }

  /// Get position from geohash
  static LatLng posFromHash(String hash) {
    final decoded = geohash.GeoHash.decode(hash);
    return LatLng(decoded.center.latitude, decoded.center.longitude);
  }

  /// Calculate haversine distance in miles
  static double haversineMiles(LatLng a, LatLng b) {
    const double earthRadiusMiles = 3958.8;
    final double lat1 = a.latitudeInRad;
    final double lat2 = b.latitudeInRad;
    final double lon1 = a.longitudeInRad;
    final double lon2 = b.longitudeInRad;

    final double dLat = lat2 - lat1;
    final double dLon = lon2 - lon1;

    final double a1 = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);

    final double c = 2 * atan2(sqrt(a1), sqrt(1 - a1));

    return earthRadiusMiles * c;
  }

  /// Check if location is valid (basic lat/lng bounds check)
  static bool isValidLocation(LatLng pos) {
    // Only validate that coordinates are within Earth's valid range
    // Removed Seattle-area geofence to allow global usage
    if (pos.latitude < -90 ||
        pos.latitude > 90 ||
        pos.longitude < -180 ||
        pos.longitude > 180) {
      return false;
    }

    return true; // Valid anywhere on Earth
  }

  /// Calculate age in days from timestamp
  static int ageInDays(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    return difference.inDays;
  }

  /// Get the best repeater for a given position
  /// This adjusts distance based on elevation
  static String? getBestRepeater(
    LatLng fromPos,
    Map<String, dynamic> repeaterMap,
  ) {
    if (repeaterMap.isEmpty) return null;

    String? bestId;
    double bestDistance = double.infinity;

    repeaterMap.forEach((id, repeater) {
      final LatLng repeaterPos = repeater['pos'] as LatLng;
      double distance = haversineMiles(fromPos, repeaterPos);

      // Adjust distance based on elevation (if available)
      final double? elevation = repeater['elevation'] as double?;
      if (elevation != null) {
        // Higher elevation gives better coverage
        // Reduce effective distance by 0.5% per 100ft elevation
        final double elevationFactor = 1.0 - (elevation / 100.0 * 0.005);
        distance *= elevationFactor.clamp(0.5, 1.0);
      }

      if (distance < bestDistance) {
        bestDistance = distance;
        bestId = id;
      }
    });

    return bestId;
  }

  /// Sigmoid function for smoothing values
  static double sigmoid(double x) {
    return 1.0 / (1.0 + exp(-x));
  }
}
