import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'database_service.dart';

/// Atmospheric ducting risk levels
class DuctingRisk {
  static const String none = 'none';         // Normal atmosphere
  static const String possible = 'possible'; // Super-refraction
  static const String likely = 'likely';     // Trapping/ducting
  static const String unknown = 'unknown';   // No data available
}

/// Cached ducting data point
class DuctingDataPoint {
  final int timestamp;    // Unix ms
  final double lat;
  final double lon;
  final String risk;
  final double? nSurface;
  final double? n925;
  final double? gradient;
  final int fetchedAt;    // Unix ms

  DuctingDataPoint({
    required this.timestamp,
    required this.lat,
    required this.lon,
    required this.risk,
    this.nSurface,
    this.n925,
    this.gradient,
    required this.fetchedAt,
  });
}

/// Service for monitoring atmospheric ducting conditions.
/// Fetches pressure-level data from Open-Meteo, computes the refractivity
/// gradient, and caches results locally for offline use.
class DuctingService {
  final DatabaseService _dbService = DatabaseService();

  /// Height difference between surface (~1000hPa) and 925hPa in meters.
  /// Approximate standard atmosphere: ~750m difference.
  static const double _heightDiffMeters = 750.0;

  /// Cache validity duration (6 hours)
  static const Duration _cacheValidity = Duration(hours: 6);

  /// Minimum interval between API fetches (1 hour)
  static const Duration _fetchInterval = Duration(hours: 1);

  DateTime? _lastFetchTime;

  /// Fetch atmospheric data from Open-Meteo and cache locally.
  /// Returns true if fresh data was fetched, false if skipped or failed.
  Future<bool> fetchAndCache(double lat, double lon) async {
    // Don't fetch more often than once per hour
    if (_lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < _fetchInterval) {
      return false;
    }

    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=${lat.toStringAsFixed(4)}'
        '&longitude=${lon.toStringAsFixed(4)}'
        '&hourly=temperature_2m,relative_humidity_2m,surface_pressure,'
        'temperature_1000hPa,relative_humidity_1000hPa,'
        'temperature_925hPa,relative_humidity_925hPa'
        '&forecast_days=1'
        '&timeformat=unixtime',
      );

      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode != 200) return false;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final hourly = json['hourly'] as Map<String, dynamic>?;
      if (hourly == null) return false;

      final times = (hourly['time'] as List<dynamic>?)?.cast<int>() ?? [];
      final temp2m = _parseDoubleList(hourly['temperature_2m']);
      final rh2m = _parseDoubleList(hourly['relative_humidity_2m']);
      final surfPressure = _parseDoubleList(hourly['surface_pressure']);
      final temp1000 = _parseDoubleList(hourly['temperature_1000hPa']);
      final rh1000 = _parseDoubleList(hourly['relative_humidity_1000hPa']);
      final temp925 = _parseDoubleList(hourly['temperature_925hPa']);
      final rh925 = _parseDoubleList(hourly['relative_humidity_925hPa']);

      if (times.isEmpty) return false;

      final db = await _dbService.database;
      final batch = db.batch();
      final now = DateTime.now().millisecondsSinceEpoch;

      // Clear old cache entries (older than 24 hours)
      batch.delete(
        DatabaseService.tableDuctingCache,
        where: 'fetched_at < ?',
        whereArgs: [now - const Duration(hours: 24).inMilliseconds],
      );

      for (int i = 0; i < times.length; i++) {
        // Use 1000hPa data for surface if available, fall back to 2m + surface pressure
        final surfTempC = temp1000.length > i && temp1000[i] != null
            ? temp1000[i]!
            : (temp2m.length > i ? temp2m[i] : null);
        final surfRh = rh1000.length > i && rh1000[i] != null
            ? rh1000[i]!
            : (rh2m.length > i ? rh2m[i] : null);
        final surfP = surfPressure.length > i ? surfPressure[i] : null;

        final upperTempC = temp925.length > i ? temp925[i] : null;
        final upperRh = rh925.length > i ? rh925[i] : null;

        if (surfTempC == null || surfRh == null || surfP == null ||
            upperTempC == null || upperRh == null) {
          continue;
        }

        final nSurface = _computeRefractivity(surfP, surfTempC, surfRh);
        final n925 = _computeRefractivity(925.0, upperTempC, upperRh);
        final gradient = _computeGradient(nSurface, n925, _heightDiffMeters);
        final risk = _classifyGradient(gradient);

        batch.insert(DatabaseService.tableDuctingCache, {
          'timestamp': times[i] * 1000, // API returns seconds, we store ms
          'lat': lat,
          'lon': lon,
          'risk': risk,
          'n_surface': nSurface,
          'n_925': n925,
          'gradient': gradient,
          'fetched_at': now,
        });
      }

      await batch.commit(noResult: true);
      _lastFetchTime = DateTime.now();
      return true;
    } catch (e) {
      // Silently fail — offline is fine, we'll use cached data
      print('Ducting fetch failed (offline?): $e');
      return false;
    }
  }

  /// Get the ducting risk for a specific timestamp from cache.
  /// Returns the risk for the nearest cached hour within cache validity.
  Future<String> getCurrentRisk(DateTime timestamp) async {
    try {
      final db = await _dbService.database;
      final tsMs = timestamp.millisecondsSinceEpoch;
      final validAfter = tsMs - _cacheValidity.inMilliseconds;

      // Find the closest cached entry within validity window
      final results = await db.rawQuery('''
        SELECT risk, ABS(timestamp - ?) AS diff
        FROM ${DatabaseService.tableDuctingCache}
        WHERE fetched_at > ?
        ORDER BY diff ASC
        LIMIT 1
      ''', [tsMs, validAfter]);

      if (results.isNotEmpty) {
        return results.first['risk'] as String;
      }
    } catch (e) {
      print('Ducting cache lookup failed: $e');
    }
    return DuctingRisk.unknown;
  }

  /// Get the most recent ducting risk for the UI badge.
  Future<String> getLatestRisk() async {
    try {
      final db = await _dbService.database;
      final validAfter = DateTime.now().millisecondsSinceEpoch -
          _cacheValidity.inMilliseconds;

      final results = await db.query(
        DatabaseService.tableDuctingCache,
        columns: ['risk'],
        where: 'fetched_at > ?',
        whereArgs: [validAfter],
        orderBy: 'timestamp DESC',
        limit: 1,
      );

      if (results.isNotEmpty) {
        return results.first['risk'] as String;
      }
    } catch (e) {
      print('Ducting latest risk lookup failed: $e');
    }
    return DuctingRisk.unknown;
  }

  /// Compute radio refractivity N at a given pressure level.
  ///
  /// N = 77.6 * (P/T) + 3.73e5 * (e/T²)
  /// where P = pressure (hPa), T = temperature (K),
  /// e = water vapor pressure (hPa)
  static double _computeRefractivity(
      double pressureHpa, double tempCelsius, double relativeHumidity) {
    final tKelvin = tempCelsius + 273.15;
    // Saturation vapor pressure (Magnus formula)
    final es = 6.112 * exp((17.67 * tempCelsius) / (tempCelsius + 243.5));
    // Actual vapor pressure
    final e = (relativeHumidity / 100.0) * es;
    // Refractivity
    return 77.6 * (pressureHpa / tKelvin) + 3.73e5 * (e / (tKelvin * tKelvin));
  }

  /// Compute the refractivity gradient dN/dh in N-units per km.
  static double _computeGradient(
      double nSurface, double nUpper, double heightDiffMeters) {
    return ((nUpper - nSurface) / heightDiffMeters) * 1000.0;
  }

  /// Classify ducting risk from the refractivity gradient.
  ///
  /// Standard atmosphere: dN/dh ≈ -40 N/km
  /// Super-refraction: -157 < dN/dh ≤ -79
  /// Ducting/trapping: dN/dh ≤ -157
  static String _classifyGradient(double gradientPerKm) {
    if (gradientPerKm <= -157.0) {
      return DuctingRisk.likely;
    } else if (gradientPerKm <= -79.0) {
      return DuctingRisk.possible;
    } else {
      return DuctingRisk.none;
    }
  }

  /// Parse a list of nullable doubles from JSON (handles int and double values).
  static List<double?> _parseDoubleList(dynamic list) {
    if (list == null) return [];
    return (list as List<dynamic>).map((v) {
      if (v == null) return null;
      return (v as num).toDouble();
    }).toList();
  }

  /// Get a human-readable label for a ducting risk level.
  static String riskLabel(String risk) {
    switch (risk) {
      case DuctingRisk.none:
        return 'None';
      case DuctingRisk.possible:
        return 'Possible';
      case DuctingRisk.likely:
        return 'Likely';
      default:
        return 'Unknown';
    }
  }
}
