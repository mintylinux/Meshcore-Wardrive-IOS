import '../models/models.dart';
import '../utils/geohash_utils.dart';

class AggregationService {
  /// Build indexes from samples and repeaters
  /// @param coveragePrecision: Geohash precision for coverage squares (4-8, default 6)
  static AggregationResult buildIndexes(
    List<Sample> samples, 
    List<Repeater> repeaters, 
    {int coveragePrecision = 6}
  ) {
    final Map<String, Coverage> hashToCoverage = {};
    final Map<String, Map<String, dynamic>> idToRepeaters = {};
    final List<Edge> edgeList = [];

    // Build repeaters map
    for (final repeater in repeaters) {
      idToRepeaters[repeater.id] = {
        'pos': repeater.position,
        'elevation': repeater.elevation,
        'repeater': repeater,
      };
    }

    // Group samples by coverage area and analyze for contradictions
    final Map<String, List<Sample>> coverageToSamples = {};
    for (final sample in samples) {
      final coverageHash = GeohashUtils.coverageKey(
        sample.position.latitude,
        sample.position.longitude,
        precision: coveragePrecision,
      );
      coverageToSamples.putIfAbsent(coverageHash, () => []);
      coverageToSamples[coverageHash]!.add(sample);
    }
    
    // Aggregate samples into coverage areas with smart weighting
    for (final entry in coverageToSamples.entries) {
      final coverageHash = entry.key;
      final samplesInArea = entry.value;
      
      // Sort by timestamp (newest first)
      samplesInArea.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      
      // Get or create coverage
      if (!hashToCoverage.containsKey(coverageHash)) {
        final pos = GeohashUtils.posFromHash(coverageHash);
        hashToCoverage[coverageHash] = Coverage(
          id: coverageHash,
          position: pos,
        );
      }

      final coverage = hashToCoverage[coverageHash]!;
      
      // Process samples with time-based weighting
      // Newer samples get more weight, contradicting old samples are discounted
      for (int i = 0; i < samplesInArea.length; i++) {
        final sample = samplesInArea[i];
        
        // Skip GPS-only samples (pingSuccess == null)
        if (sample.pingSuccess == null) continue;
        
        // Calculate age-based weight (newer = more weight)
        final ageInDays = GeohashUtils.ageInDays(sample.timestamp);
        double weight = 1.0;
        
        // Reduce weight for older samples
        if (ageInDays > 30) {
          weight = 0.2; // Very old data, minimal weight
        } else if (ageInDays > 7) {
          weight = 0.5; // Week-old data, half weight
        } else if (ageInDays > 1) {
          weight = 0.8; // Day-old data, slight reduction
        }
        
        // Check for contradictions with newer samples (up to 10 most recent)
        bool contradictedByNewer = false;
        final newerSamples = samplesInArea.sublist(0, i > 10 ? 10 : i);
        
        if (newerSamples.isNotEmpty) {
          // Count how many newer samples contradict this one
          int contradictions = 0;
          int agreements = 0;
          
          for (final newer in newerSamples) {
            if (newer.pingSuccess == null) continue;
            
            // Check if newer samples consistently show opposite result
            if (newer.pingSuccess != sample.pingSuccess) {
              contradictions++;
            } else {
              agreements++;
            }
          }
          
          // If majority of recent samples contradict, heavily discount this sample
          if (contradictions > agreements && contradictions >= 2) {
            weight *= 0.1; // Contradicted data gets 10% weight
            contradictedByNewer = true;
          }
        }
        
        // Apply weighted sample to coverage stats
        if (sample.pingSuccess == true) {
          coverage.received += weight; // Successful ping (observer heard us)
          
          // Track which repeater actually responded (from sample.path = nodeId)
          if (sample.path != null && sample.path!.isNotEmpty) {
            if (!coverage.repeaters.contains(sample.path!)) {
              coverage.repeaters.add(sample.path!);
            }
          }
          
          // Update lastReceived only if not contradicted
          if (!contradictedByNewer && 
              (coverage.lastReceived == null || sample.timestamp.isAfter(coverage.lastReceived!))) {
            coverage.lastReceived = sample.timestamp;
          }
        } else if (sample.pingSuccess == false) {
          coverage.lost += weight; // Failed ping (dead zone)
        }
        
        // Update timestamp
        if (coverage.updated == null || 
            sample.timestamp.isAfter(coverage.updated!)) {
          coverage.updated = sample.timestamp;
        }
      }
    }

    // Build edges from coverage to repeaters
    for (final coverage in hashToCoverage.values) {
      if (idToRepeaters.isNotEmpty) {
        final bestRepeaterId = GeohashUtils.getBestRepeater(
          coverage.position,
          idToRepeaters,
        );

        if (bestRepeaterId != null) {
          final repeaterData = idToRepeaters[bestRepeaterId];
          if (repeaterData != null) {
            edgeList.add(Edge(
              coverage: coverage,
              repeater: repeaterData['repeater'] as Repeater,
            ));
          }
        }
      }
    }

    // Calculate top repeaters by connection count
    final Map<String, int> repeaterConnections = {};
    for (final edge in edgeList) {
      final id = edge.repeater.id;
      repeaterConnections[id] = (repeaterConnections[id] ?? 0) + 1;
    }

    final topRepeaters = repeaterConnections.entries
        .toList()
        ..sort((a, b) => b.value.compareTo(a.value));

    return AggregationResult(
      coverages: hashToCoverage.values.toList(),
      edges: edgeList,
      topRepeaters: topRepeaters.take(15).toList(),
      repeaters: repeaters,
    );
  }

  /// Get coverage color based on received count
  static int getCoverageColor(Coverage coverage, String colorMode) {
    if (colorMode == 'age') {
      if (coverage.lastReceived == null) return 0xFF808080;
      
      final age = GeohashUtils.ageInDays(coverage.lastReceived!);
      if (age < 1) return 0xFF00FF00; // Green - fresh
      if (age < 7) return 0xFF88FF00; // Yellow-green
      if (age < 30) return 0xFFFFFF00; // Yellow
      if (age < 90) return 0xFFFF8800; // Orange
      return 0xFFFF0000; // Red - old
    } else {
      // Default: coverage based on ping success rate
      final received = coverage.received; // Successful pings
      final lost = coverage.lost;         // Failed pings
      final total = received + lost;
      
      // No pings attempted here (just GPS tracking)
      if (total == 0) {
        return 0xFFCCCCCC; // Gray
      }
      
      // Calculate success rate
      final successRate = received / total;
      
      // Color based on success rate thresholds
      if (successRate >= 0.80) {
        return 0xFF00FF00; // Bright green - very reliable (80%+)
      } else if (successRate >= 0.50) {
        return 0xFF88FF00; // Yellow-green - usually works (50-80%)
      } else if (successRate >= 0.30) {
        return 0xFFFFFF00; // Yellow - spotty (30-50%)
      } else if (successRate >= 0.10) {
        return 0xFFFFAA00; // Orange - rarely works (10-30%)
      } else {
        return 0xFFFF0000; // Red - dead zone (<10%)
      }
    }
  }

  /// Get opacity based on coverage stats
  static double getCoverageOpacity(Coverage coverage) {
    final received = coverage.received;
    if (received >= 20) return 0.7;
    if (received >= 10) return 0.5;
    if (received >= 5) return 0.4;
    return 0.3;
  }
}

class AggregationResult {
  final List<Coverage> coverages;
  final List<Edge> edges;
  final List<MapEntry<String, int>> topRepeaters;
  final List<Repeater> repeaters;

  AggregationResult({
    required this.coverages,
    required this.edges,
    required this.topRepeaters,
    required this.repeaters,
  });
}
