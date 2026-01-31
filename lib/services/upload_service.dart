import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'database_service.dart';
import '../models/models.dart';
import '../constants/app_version.dart';

class UploadService {
  bool _isDefaultEndpoint(String url) {
    String norm(String u) {
      var s = u.trim().toLowerCase();
      if (s.endsWith('/')) s = s.substring(0, s.length - 1);
      return s;
    }
    return norm(url) == norm(defaultApiUrl);
  }
  static const String _apiUrlKey = 'upload_api_url';
  static const String _autoUploadKey = 'auto_upload_enabled';
  static const String _lastUploadKey = 'last_upload_timestamp';
  static const String _uploadEndpointsKey = 'upload_endpoints'; // JSON list of endpoints
  static const String _selectedEndpointsKey = 'selected_endpoints'; // JSON list of selected endpoint names
  
  // Default URL (user can change this)
  static const String defaultApiUrl = 'https://meshwar-map.pages.dev/api/samples';
  
  final DatabaseService _db = DatabaseService();
  
  Future<String> getApiUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiUrlKey) ?? defaultApiUrl;
  }
  
  Future<void> setApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiUrlKey, url);
  }
  
  Future<bool> isAutoUploadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoUploadKey) ?? false;
  }
  
  Future<void> setAutoUploadEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoUploadKey, enabled);
  }
  
  Future<DateTime?> getLastUploadTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_lastUploadKey);
    return timestamp != null ? DateTime.fromMillisecondsSinceEpoch(timestamp) : null;
  }
  
  Future<void> _setLastUploadTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastUploadKey, time.millisecondsSinceEpoch);
  }
  
  /// Upload all unuploaded samples to the configured API
  /// Splits large uploads into batches to avoid timeouts
  Future<UploadResult> uploadAllSamples({
    Map<String, String>? repeaterNames,
    Function(int current, int total)? onProgress,
  }) async {
    try {
      final apiUrl = await getApiUrl();
      final bool isDefault = _isDefaultEndpoint(apiUrl);
      final samples = isDefault
          ? await _db.getUnuploadedSamples()
          : await _db.getAllSamples();
      
      if (samples.isEmpty) {
        return UploadResult(success: true, message: 'No new samples to upload');
      }
      
      // Convert samples to JSON (include stable id for server-side dedupe)
      final samplesJson = samples.map((sample) => {
        'id': sample.id,
        'nodeId': (sample.path == null || sample.path!.isEmpty)
            ? 'Unknown'
            : (sample.path!.length > 8 ? sample.path!.substring(0, 8).toUpperCase() : sample.path!.toUpperCase()),
        'repeaterName': (() {
          final name = (sample.path != null && repeaterNames != null)
              ? repeaterNames![sample.path]
              : null;
          if (name != null && name.isNotEmpty) return name;
          if (sample.path == null || sample.path!.isEmpty) return 'Unknown';
          final short = sample.path!.length > 8 ? sample.path!.substring(0,8).toUpperCase() : sample.path!.toUpperCase();
          return short;
        })(),
        'latitude': sample.position.latitude,
        'longitude': sample.position.longitude,
        'rssi': sample.rssi,
        'snr': sample.snr,
        'pingSuccess': sample.pingSuccess,
        'timestamp': sample.timestamp.toIso8601String(),
        'appVersion': appVersion, // App version from constants
      }).toList();
      
      print('Uploading ${samplesJson.length} samples in batches...');
      
      // Split into batches of 100 samples each
      const batchSize = 100;
      final totalBatches = (samplesJson.length / batchSize).ceil();
      int totalCells = 0;
      
      for (int i = 0; i < totalBatches; i++) {
        final start = i * batchSize;
        final end = (start + batchSize < samplesJson.length) 
            ? start + batchSize 
            : samplesJson.length;
        final batch = samplesJson.sublist(start, end);
        
        // Report progress
        if (onProgress != null) {
          onProgress(i + 1, totalBatches);
        }
        
        print('Uploading batch ${i + 1}/$totalBatches (${batch.length} samples)');
        
        // Try up to 2 times (original + 1 retry)
        bool success = false;
        http.Response? response;
        String? error;
        
        for (int attempt = 0; attempt < 2; attempt++) {
          try {
            response = await http.post(
              Uri.parse(apiUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'samples': batch}),
            ).timeout(const Duration(seconds: 60));
            
            if (response.statusCode == 200) {
              success = true;
              final responseData = jsonDecode(response.body);
              totalCells = responseData['totalCells'] ?? totalCells;
              break; // Success, exit retry loop
            } else {
              error = 'Server error: ${response.statusCode}';
              if (attempt == 0) {
                print('Batch ${i + 1} failed with ${response.statusCode}, retrying...');
                await Future.delayed(const Duration(seconds: 2));
              }
            }
          } catch (e) {
            error = e.toString();
            if (attempt == 0) {
              print('Batch ${i + 1} failed: $e, retrying...');
              await Future.delayed(const Duration(seconds: 2));
            }
          }
        }
        
        if (!success) {
          return UploadResult(
            success: false,
            message: 'Failed at batch ${i + 1}/$totalBatches: $error',
          );
        }
      }
      
      // All batches successful
      await _setLastUploadTime(DateTime.now());
      
      // Mark samples as uploaded only for the default endpoint
      final sampleIds = samples.map((s) => s.id).toList();
      if (isDefault) {
        await _db.markSamplesAsUploaded(sampleIds);
      }
      
      return UploadResult(
        success: true,
        message: 'Upload Complete',
        uploadedCount: samples.length,
        totalCount: totalCells,
      );
    } catch (e) {
      return UploadResult(
        success: false,
        message: 'Upload failed: $e',
      );
    }
  }
  
  /// Upload only samples since last upload (deprecated - use uploadAllSamples instead)
  Future<UploadResult> uploadNewSamples({Map<String, String>? repeaterNames}) async {
    // Just redirect to uploadAllSamples since it now only uploads unuploaded samples
    return uploadAllSamples(repeaterNames: repeaterNames);
  }
  
  /// Get list of configured upload endpoints
  Future<List<UploadEndpoint>> getUploadEndpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_uploadEndpointsKey);
    
    if (json == null || json.isEmpty) {
      // Return default endpoint
      return [UploadEndpoint(name: 'Default', url: defaultApiUrl)];
    }
    
    final List<dynamic> decoded = jsonDecode(json);
    return decoded.map((e) => UploadEndpoint.fromJson(e as Map<String, dynamic>)).toList();
  }
  
  /// Save upload endpoints
  Future<void> setUploadEndpoints(List<UploadEndpoint> endpoints) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(endpoints.map((e) => e.toJson()).toList());
    await prefs.setString(_uploadEndpointsKey, json);
  }
  
  /// Get list of selected endpoint names (for multi-upload)
  Future<List<String>> getSelectedEndpoints() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_selectedEndpointsKey);
    
    if (json == null || json.isEmpty) {
      return ['Default']; // Default to the default endpoint
    }
    
    final List<dynamic> decoded = jsonDecode(json);
    return decoded.cast<String>();
  }
  
  /// Set selected endpoint names
  Future<void> setSelectedEndpoints(List<String> names) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(names);
    await prefs.setString(_selectedEndpointsKey, json);
  }
  
  /// Upload to all selected endpoints
  Future<Map<String, UploadResult>> uploadToSelectedEndpoints({
    Map<String, String>? repeaterNames,
    Function(String endpointName, int current, int total)? onProgress,
  }) async {
    final endpoints = await getUploadEndpoints();
    final selectedNames = await getSelectedEndpoints();
    final results = <String, UploadResult>{};
    
    for (final endpoint in endpoints) {
      if (selectedNames.contains(endpoint.name)) {
        // Temporarily set this as the active endpoint
        final originalUrl = await getApiUrl();
        await setApiUrl(endpoint.url);
        
        // Upload to this endpoint
        final result = await uploadAllSamples(
          repeaterNames: repeaterNames,
          onProgress: (current, total) {
            if (onProgress != null) {
              onProgress(endpoint.name, current, total);
            }
          },
        );
        
        results[endpoint.name] = result;
        
        // Restore original URL
        await setApiUrl(originalUrl);
      }
    }
    
    return results;
  }
}

class UploadEndpoint {
  final String name;
  final String url;
  
  UploadEndpoint({
    required this.name,
    required this.url,
  });
  
  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
  };
  
  factory UploadEndpoint.fromJson(Map<String, dynamic> json) {
    return UploadEndpoint(
      name: json['name'] as String,
      url: json['url'] as String,
    );
  }
}

class UploadResult {
  final bool success;
  final String message;
  final int? uploadedCount;
  final int? totalCount;
  
  UploadResult({
    required this.success,
    required this.message,
    this.uploadedCount,
    this.totalCount,
  });
}
