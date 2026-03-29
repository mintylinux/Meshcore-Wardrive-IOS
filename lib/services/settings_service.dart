import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const String _showSamplesKey = 'show_samples';
  static const String _showGpsSamplesKey = 'show_gps_samples';
  static const String _showCoverageKey = 'show_coverage';
  static const String _showEdgesKey = 'show_edges';
  static const String _showRepeatersKey = 'show_repeaters';
  static const String _colorModeKey = 'color_mode';
  static const String _pingIntervalKey = 'ping_interval_meters';
  static const String _coveragePrecisionKey = 'coverage_precision';
  static const String _ignoredRepeaterPrefixKey = 'ignored_repeater_prefix';
  static const String _includeOnlyRepeatersKey = 'include_only_repeaters';
  static const String _filterEdgesByWhitelistKey = 'filter_edges_by_whitelist';
  static const String _distanceUnitKey = 'distance_unit';
  static const String _colorBlindModeKey = 'color_blind_mode';
  static const String _discoveryTimeoutKey = 'discovery_timeout_seconds';
  static const String _totalDistanceDrivenKey = 'total_distance_driven_meters';
  static const String _vehicleMpgKey = 'vehicle_mpg';
  static const String _gasPriceKey = 'gas_price_per_gallon';
  static const String _fuelUnitKey = 'fuel_unit';
  static const String _showRouteTrailKey = 'show_route_trail';
  static const String _showHeatmapKey = 'show_heatmap';
  static const String _showPredictionRingsKey = 'show_prediction_rings';
  static const String _showDuctingKey = 'show_ducting';
  static const String _goalCenterLatKey = 'goal_center_lat';
  static const String _goalCenterLonKey = 'goal_center_lon';
  static const String _goalRadiusMetersKey = 'goal_radius_meters';
  static const String _carpeaterEnabledKey = 'carpeater_enabled';
  static const String _carpeaterRepeaterIdKey = 'carpeater_repeater_id';
  static const String _carpeaterPasswordKey = 'carpeater_password';
  static const String _carpeaterIntervalKey = 'carpeater_interval_seconds';
  
  Future<bool> getShowSamples() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showSamplesKey) ?? false;
  }
  
  Future<void> setShowSamples(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showSamplesKey, value);
  }
  
  Future<bool> getShowGpsSamples() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showGpsSamplesKey) ?? true;
  }
  
  Future<void> setShowGpsSamples(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showGpsSamplesKey, value);
  }
  
  Future<bool> getShowCoverage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showCoverageKey) ?? true;
  }
  
  Future<void> setShowCoverage(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showCoverageKey, value);
  }
  
  Future<bool> getShowEdges() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showEdgesKey) ?? true;
  }
  
  Future<void> setShowEdges(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showEdgesKey, value);
  }
  
  Future<bool> getShowRepeaters() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showRepeatersKey) ?? true;
  }
  
  Future<void> setShowRepeaters(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showRepeatersKey, value);
  }
  
  Future<String> getColorMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_colorModeKey) ?? 'quality';
  }
  
  Future<void> setColorMode(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorModeKey, value);
  }
  
  Future<double> getPingInterval() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_pingIntervalKey) ?? 805.0; // Default 0.5 miles
  }
  
  Future<void> setPingInterval(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_pingIntervalKey, value);
  }
  
  Future<int> getCoveragePrecision() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_coveragePrecisionKey) ?? 6; // Default precision 6
  }
  
  Future<void> setCoveragePrecision(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_coveragePrecisionKey, value);
  }
  
  Future<String?> getIgnoredRepeaterPrefix() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ignoredRepeaterPrefixKey);
  }
  
  Future<void> setIgnoredRepeaterPrefix(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_ignoredRepeaterPrefixKey);
    } else {
      await prefs.setString(_ignoredRepeaterPrefixKey, value);
    }
  }
  
  /// Get comma-separated list of repeater prefixes to ONLY hear from (whitelist)
  /// Empty or null = hear from all repeaters
  Future<String?> getIncludeOnlyRepeaters() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_includeOnlyRepeatersKey);
  }
  
  Future<void> setIncludeOnlyRepeaters(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_includeOnlyRepeatersKey);
    } else {
      await prefs.setString(_includeOnlyRepeatersKey, value);
    }
  }
  
  /// Whether to filter edges (purple lines) by the Include Only Repeaters whitelist
  Future<bool> getFilterEdgesByWhitelist() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_filterEdgesByWhitelistKey) ?? false;
  }
  
  Future<void> setFilterEdgesByWhitelist(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_filterEdgesByWhitelistKey, value);
  }
  
  /// Get distance unit ('miles' or 'km')
  Future<String> getDistanceUnit() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_distanceUnitKey) ?? 'miles';
  }
  
  Future<void> setDistanceUnit(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_distanceUnitKey, value);
  }
  
  /// Get color blind mode ('normal', 'deuteranopia', 'protanopia', 'tritanopia')
  Future<String> getColorBlindMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_colorBlindModeKey) ?? 'normal';
  }
  
  Future<void> setColorBlindMode(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorBlindModeKey, value);
  }
  
  /// Get discovery timeout in seconds (10-30 seconds, default 20)
  Future<int> getDiscoveryTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_discoveryTimeoutKey) ?? 20;
  }
  
  Future<void> setDiscoveryTimeout(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_discoveryTimeoutKey, value);
  }
  
  /// Get total distance driven across all sessions (in meters)
  Future<double> getTotalDistanceDriven() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_totalDistanceDrivenKey) ?? 0.0;
  }
  
  /// Add distance from a session to the persistent total
  Future<void> addToTotalDistanceDriven(double meters) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getDouble(_totalDistanceDrivenKey) ?? 0.0;
    await prefs.setDouble(_totalDistanceDrivenKey, current + meters);
  }
  
  /// Reset total distance driven
  Future<void> resetTotalDistanceDriven() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_totalDistanceDrivenKey, 0.0);
  }
  
  /// Get vehicle MPG (miles per gallon), null if not set
  Future<double?> getVehicleMpg() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_vehicleMpgKey);
  }
  
  /// Set vehicle MPG
  Future<void> setVehicleMpg(double? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_vehicleMpgKey);
    } else {
      await prefs.setDouble(_vehicleMpgKey, value);
    }
  }
  
  /// Get gas price per gallon (default 3.50)
  Future<double> getGasPrice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_gasPriceKey) ?? 3.50;
  }
  
  /// Set gas price per gallon
  Future<void> setGasPrice(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_gasPriceKey, value);
  }
  
  /// Get fuel unit ('imperial' or 'metric')
  Future<String> getFuelUnit() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_fuelUnitKey) ?? 'imperial';
  }
  
  /// Set fuel unit ('imperial' or 'metric')
  Future<void> setFuelUnit(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fuelUnitKey, value);
  }
  
  /// Get show route trail setting
  Future<bool> getShowRouteTrail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showRouteTrailKey) ?? false;
  }
  
  /// Set show route trail setting
  Future<void> setShowRouteTrail(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showRouteTrailKey, value);
  }
  
  /// Get show heatmap setting
  Future<bool> getShowHeatmap() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showHeatmapKey) ?? false;
  }
  
  /// Set show heatmap setting
  Future<void> setShowHeatmap(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showHeatmapKey, value);
  }
  
  /// Get show prediction rings setting
  Future<bool> getShowPredictionRings() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showPredictionRingsKey) ?? false;
  }
  
  /// Set show prediction rings setting
  Future<void> setShowPredictionRings(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showPredictionRingsKey, value);
  }
  
  /// Get show ducting monitor setting
  Future<bool> getShowDucting() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showDuctingKey) ?? false;
  }
  
  /// Set show ducting monitor setting
  Future<void> setShowDucting(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showDuctingKey, value);
  }
  
  // Coverage goal settings
  
  Future<double?> getGoalCenterLat() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_goalCenterLatKey);
  }
  
  Future<double?> getGoalCenterLon() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_goalCenterLonKey);
  }
  
  Future<double> getGoalRadiusMeters() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_goalRadiusMetersKey) ?? 8047.0; // Default 5 miles
  }
  
  Future<void> setGoal(double lat, double lon, double radiusMeters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_goalCenterLatKey, lat);
    await prefs.setDouble(_goalCenterLonKey, lon);
    await prefs.setDouble(_goalRadiusMetersKey, radiusMeters);
  }
  
  Future<void> clearGoal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_goalCenterLatKey);
    await prefs.remove(_goalCenterLonKey);
    await prefs.remove(_goalRadiusMetersKey);
  }
  
  // Carpeater mode settings
  
  Future<bool> getCarpeaterEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_carpeaterEnabledKey) ?? false;
  }
  
  Future<void> setCarpeaterEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_carpeaterEnabledKey, value);
  }
  
  Future<String?> getCarpeaterRepeaterId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_carpeaterRepeaterIdKey);
  }
  
  Future<void> setCarpeaterRepeaterId(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_carpeaterRepeaterIdKey);
    } else {
      await prefs.setString(_carpeaterRepeaterIdKey, value);
    }
  }
  
  Future<String?> getCarpeaterPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_carpeaterPasswordKey);
  }
  
  Future<void> setCarpeaterPassword(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_carpeaterPasswordKey);
    } else {
      await prefs.setString(_carpeaterPasswordKey, value);
    }
  }
  
  Future<int> getCarpeaterInterval() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_carpeaterIntervalKey) ?? 30;
  }
  
  Future<void> setCarpeaterInterval(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_carpeaterIntervalKey, value);
  }
}
