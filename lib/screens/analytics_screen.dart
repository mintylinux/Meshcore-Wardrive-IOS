import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:geohash_plus/geohash_plus.dart' as geohash;
import '../models/models.dart';
import '../services/aggregation_service.dart';
import '../services/database_service.dart';
import '../services/settings_service.dart';

class AnalyticsScreen extends StatefulWidget {
  final List<Sample> samples;
  final int coveragePrecision;
  final LatLng? currentPosition;

  const AnalyticsScreen({
    super.key,
    required this.samples,
    required this.coveragePrecision,
    this.currentPosition,
  });

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
      ),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _TimeOfDayTab(samples: widget.samples),
          _CoverageGoalTab(
            samples: widget.samples,
            coveragePrecision: widget.coveragePrecision,
            currentPosition: widget.currentPosition,
          ),
          _CoverageComparisonTab(coveragePrecision: widget.coveragePrecision),
          _RepeaterReliabilityTab(samples: widget.samples),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 12,
        unselectedFontSize: 11,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.schedule), label: 'Time'),
          BottomNavigationBarItem(icon: Icon(Icons.flag), label: 'Goals'),
          BottomNavigationBarItem(icon: Icon(Icons.compare_arrows), label: 'Compare'),
          BottomNavigationBarItem(icon: Icon(Icons.cell_tower), label: 'Repeaters'),
        ],
      ),
    );
  }
}

// =============================================================================
// TAB 1: Time-of-Day Breakdown
// =============================================================================

class _TimeOfDayTab extends StatelessWidget {
  final List<Sample> samples;
  const _TimeOfDayTab({required this.samples});

  @override
  Widget build(BuildContext context) {
    final pingSamples = samples.where((s) => s.pingSuccess != null).toList();

    if (pingSamples.isEmpty) {
      return const Center(
        child: Text('No ping data yet.\nDo some wardriving first!', textAlign: TextAlign.center),
      );
    }

    // Group by hour
    final Map<int, List<Sample>> byHour = {};
    for (int h = 0; h < 24; h++) {
      byHour[h] = [];
    }
    for (final s in pingSamples) {
      byHour[s.timestamp.hour]!.add(s);
    }

    // Calculate success rate per hour
    final rates = <int, double>{};
    final counts = <int, int>{};
    for (int h = 0; h < 24; h++) {
      final hourSamples = byHour[h]!;
      counts[h] = hourSamples.length;
      if (hourSamples.isEmpty) {
        rates[h] = -1; // No data
      } else {
        final successes = hourSamples.where((s) => s.pingSuccess == true).length;
        rates[h] = successes / hourSamples.length;
      }
    }

    // Find best/worst hours (with data)
    final validHours = rates.entries.where((e) => e.value >= 0).toList();
    validHours.sort((a, b) => b.value.compareTo(a.value));
    final bestHour = validHours.isNotEmpty ? validHours.first.key : null;
    final worstHour = validHours.isNotEmpty ? validHours.last.key : null;

    // Period breakdown
    final periods = {
      'Night (0-6)': _periodRate(pingSamples, 0, 6),
      'Morning (6-12)': _periodRate(pingSamples, 6, 12),
      'Afternoon (12-18)': _periodRate(pingSamples, 12, 18),
      'Evening (18-24)': _periodRate(pingSamples, 18, 24),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Success Rate by Hour',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('${pingSamples.length} pings analyzed',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 16),
          SizedBox(
            height: 220,
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: 1.0,
                minY: 0,
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final h = group.x;
                      final rate = rates[h]!;
                      final count = counts[h]!;
                      if (rate < 0) return null;
                      return BarTooltipItem(
                        '${h.toString().padLeft(2, '0')}:00\n${(rate * 100).toStringAsFixed(0)}% ($count pings)',
                        const TextStyle(color: Colors.white, fontSize: 11),
                      );
                    },
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      getTitlesWidget: (value, meta) {
                        return Text('${(value * 100).toInt()}%',
                            style: const TextStyle(fontSize: 9));
                      },
                      interval: 0.25,
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (value, meta) {
                        if (value.toInt() % 3 != 0) return const SizedBox.shrink();
                        return Text('${value.toInt()}',
                            style: const TextStyle(fontSize: 9));
                      },
                    ),
                  ),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 0.25,
                ),
                barGroups: List.generate(24, (h) {
                  final rate = rates[h]!;
                  final hasData = rate >= 0;
                  return BarChartGroupData(
                    x: h,
                    barRods: [
                      BarChartRodData(
                        toY: hasData ? rate : 0,
                        color: !hasData
                            ? Colors.grey.withValues(alpha: 0.2)
                            : rate > 0.7
                                ? Colors.green
                                : rate > 0.3
                                    ? Colors.orange
                                    : Colors.red,
                        width: 8,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Summary
          if (bestHour != null) ...[
            const Text('Summary', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _summaryRow('Best hour', '${bestHour.toString().padLeft(2, '0')}:00 — ${(rates[bestHour]! * 100).toStringAsFixed(0)}%', Colors.green),
            _summaryRow('Worst hour', '${worstHour.toString().padLeft(2, '0')}:00 — ${(rates[worstHour]! * 100).toStringAsFixed(0)}%', Colors.red),
            const SizedBox(height: 16),
          ],
          const Text('By Period', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...periods.entries.map((e) {
            final rate = e.value;
            final label = rate != null ? '${(rate * 100).toStringAsFixed(0)}%' : 'No data';
            final color = rate == null
                ? Colors.grey
                : rate > 0.7
                    ? Colors.green
                    : rate > 0.3
                        ? Colors.orange
                        : Colors.red;
            return _summaryRow(e.key, label, color);
          }),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  double? _periodRate(List<Sample> samples, int startHour, int endHour) {
    final period = samples.where((s) => s.timestamp.hour >= startHour && s.timestamp.hour < endHour).toList();
    if (period.isEmpty) return null;
    final successes = period.where((s) => s.pingSuccess == true).length;
    return successes / period.length;
  }
}

// =============================================================================
// TAB 2: Coverage Goal Tracker
// =============================================================================

class _CoverageGoalTab extends StatefulWidget {
  final List<Sample> samples;
  final int coveragePrecision;
  final LatLng? currentPosition;

  const _CoverageGoalTab({
    required this.samples,
    required this.coveragePrecision,
    this.currentPosition,
  });

  @override
  State<_CoverageGoalTab> createState() => _CoverageGoalTabState();
}

class _CoverageGoalTabState extends State<_CoverageGoalTab> {
  final SettingsService _settings = SettingsService();
  double? _goalLat;
  double? _goalLon;
  double _goalRadiusMeters = 8047.0; // 5 miles
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadGoal();
  }

  Future<void> _loadGoal() async {
    final lat = await _settings.getGoalCenterLat();
    final lon = await _settings.getGoalCenterLon();
    final radius = await _settings.getGoalRadiusMeters();
    setState(() {
      _goalLat = lat;
      _goalLon = lon;
      _goalRadiusMeters = radius;
      _loading = false;
    });
  }

  bool get _hasGoal => _goalLat != null && _goalLon != null;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (!_hasGoal) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.flag_outlined, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('No coverage goal set',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Set a target area to track your wardriving progress.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _setGoal,
                icon: const Icon(Icons.add_location),
                label: const Text('Set Goal Area'),
              ),
            ],
          ),
        ),
      );
    }

    // Calculate goal progress
    final goalResult = _calculateGoalProgress();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Coverage Goal',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton(onPressed: _setGoal, child: const Text('Edit')),
              TextButton(
                onPressed: () async {
                  await _settings.clearGoal();
                  setState(() { _goalLat = null; _goalLon = null; });
                },
                child: const Text('Clear', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
          Text(
            'Center: ${_goalLat!.toStringAsFixed(4)}, ${_goalLon!.toStringAsFixed(4)}\n'
            'Radius: ${_formatRadius(_goalRadiusMeters)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          // Progress ring
          Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 160,
                    height: 160,
                    child: CircularProgressIndicator(
                      value: goalResult.totalCells > 0
                          ? goalResult.coveredCells / goalResult.totalCells
                          : 0,
                      strokeWidth: 14,
                      backgroundColor: Colors.grey.withValues(alpha: 0.2),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        goalResult.coveragePercent > 70
                            ? Colors.green
                            : goalResult.coveragePercent > 30
                                ? Colors.orange
                                : Colors.red,
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${goalResult.coveragePercent.toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                      ),
                      const Text('covered', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Stats
          _goalStatRow('Total cells in area', '${goalResult.totalCells}'),
          _goalStatRow('Covered (>0% success)', '${goalResult.coveredCells}', Colors.green),
          _goalStatRow('Partial (<30% success)', '${goalResult.partialCells}', Colors.orange),
          _goalStatRow('Uncovered', '${goalResult.uncoveredCells}', Colors.red),
          _goalStatRow('Pings in area', '${goalResult.pingsInArea}'),
        ],
      ),
    );
  }

  Widget _goalStatRow(String label, String value, [Color? color]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(value, style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: color,
          )),
        ],
      ),
    );
  }

  _GoalProgress _calculateGoalProgress() {
    final center = LatLng(_goalLat!, _goalLon!);
    const distance = Distance();

    // Generate all geohash cells that fit within the goal radius
    // Strategy: scan a grid of points within the bounding box, collect unique geohashes
    final Set<String> cellsInArea = {};

    // Calculate bounding box
    final north = distance.offset(center, _goalRadiusMeters, 0);
    final south = distance.offset(center, _goalRadiusMeters, 180);
    final east = distance.offset(center, _goalRadiusMeters, 90);
    final west = distance.offset(center, _goalRadiusMeters, 270);

    // Step size based on precision (approximate cell size in degrees)
    final stepDeg = _geohashStepDegrees(widget.coveragePrecision);

    for (double lat = south.latitude; lat <= north.latitude; lat += stepDeg) {
      for (double lon = west.longitude; lon <= east.longitude; lon += stepDeg) {
        final point = LatLng(lat, lon);
        final dist = distance.as(LengthUnit.Meter, center, point);
        if (dist <= _goalRadiusMeters) {
          final hash = geohash.GeoHash.encode(lat, lon, precision: widget.coveragePrecision).hash;
          cellsInArea.add(hash);
        }
      }
    }

    if (cellsInArea.isEmpty) {
      return _GoalProgress(totalCells: 0, coveredCells: 0, partialCells: 0, uncoveredCells: 0, pingsInArea: 0);
    }

    // Build coverage for current samples
    final result = AggregationService.buildIndexes(widget.samples, [], coveragePrecision: widget.coveragePrecision);
    final coverageMap = {for (final c in result.coverages) c.id: c};

    int covered = 0;
    int partial = 0;
    int pingsInArea = 0;

    for (final cellHash in cellsInArea) {
      final cov = coverageMap[cellHash];
      if (cov != null) {
        final total = cov.received + cov.lost;
        if (total > 0) {
          pingsInArea += total.round();
          final rate = cov.received / total;
          if (rate >= 0.3) {
            covered++;
          } else {
            partial++;
          }
        }
      }
    }

    final uncovered = cellsInArea.length - covered - partial;

    return _GoalProgress(
      totalCells: cellsInArea.length,
      coveredCells: covered,
      partialCells: partial,
      uncoveredCells: uncovered,
      pingsInArea: pingsInArea,
    );
  }

  double _geohashStepDegrees(int precision) {
    // Approximate latitude step for each geohash precision level
    switch (precision) {
      case 4: return 0.18;   // ~20km
      case 5: return 0.044;  // ~5km
      case 6: return 0.011;  // ~1.2km
      case 7: return 0.0014; // ~153m
      case 8: return 0.00034; // ~38m
      default: return 0.011;
    }
  }

  String _formatRadius(double meters) {
    if (meters >= 1609) {
      return '${(meters / 1609.34).toStringAsFixed(1)} miles';
    }
    return '${meters.toStringAsFixed(0)} m';
  }

  Future<void> _setGoal() async {
    final radiusOptions = [
      {'label': '1 mile', 'meters': 1609.34},
      {'label': '5 miles', 'meters': 8046.72},
      {'label': '10 miles', 'meters': 16093.4},
      {'label': '25 miles', 'meters': 40233.6},
    ];

    double selectedRadius = _goalRadiusMeters;
    final useCurrentPos = widget.currentPosition != null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Set Coverage Goal'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (useCurrentPos)
                const Text('Center: Your current GPS location',
                    style: TextStyle(fontSize: 13))
              else
                Text(
                  'Center: ${(_goalLat ?? 0).toStringAsFixed(4)}, ${(_goalLon ?? 0).toStringAsFixed(4)}',
                  style: const TextStyle(fontSize: 13),
                ),
              const SizedBox(height: 16),
              const Text('Radius:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...radiusOptions.map((opt) => RadioListTile<double>(
                title: Text(opt['label'] as String),
                value: opt['meters'] as double,
                groupValue: selectedRadius,
                onChanged: (v) => setDialogState(() => selectedRadius = v!),
                dense: true,
              )),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Set Goal'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final lat = useCurrentPos ? widget.currentPosition!.latitude : (_goalLat ?? 0);
      final lon = useCurrentPos ? widget.currentPosition!.longitude : (_goalLon ?? 0);
      await _settings.setGoal(lat, lon, selectedRadius);
      setState(() {
        _goalLat = lat;
        _goalLon = lon;
        _goalRadiusMeters = selectedRadius;
      });
    }
  }
}

class _GoalProgress {
  final int totalCells;
  final int coveredCells;
  final int partialCells;
  final int uncoveredCells;
  final int pingsInArea;

  double get coveragePercent =>
      totalCells > 0 ? (coveredCells / totalCells) * 100 : 0;

  _GoalProgress({
    required this.totalCells,
    required this.coveredCells,
    required this.partialCells,
    required this.uncoveredCells,
    required this.pingsInArea,
  });
}

// =============================================================================
// TAB 3: Coverage Comparison
// =============================================================================

class _CoverageComparisonTab extends StatefulWidget {
  final int coveragePrecision;
  const _CoverageComparisonTab({required this.coveragePrecision});

  @override
  State<_CoverageComparisonTab> createState() => _CoverageComparisonTabState();
}

class _CoverageComparisonTabState extends State<_CoverageComparisonTab> {
  final DatabaseService _dbService = DatabaseService();
  List<WSession> _sessions = [];
  WSession? _sessionA;
  WSession? _sessionB;
  _ComparisonResult? _result;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await _dbService.getAllSessions();
    setState(() {
      _sessions = sessions.where((s) => s.endTime != null && s.pingCount > 0).toList();
      _loading = false;
    });
  }

  Future<void> _compare() async {
    if (_sessionA == null || _sessionB == null) return;

    setState(() => _loading = true);

    // Load samples for each session
    final samplesA = await _dbService.getSamplesByTimeRange(
      _sessionA!.startTime, _sessionA!.endTime!,
    );
    final samplesB = await _dbService.getSamplesByTimeRange(
      _sessionB!.startTime, _sessionB!.endTime!,
    );

    // Aggregate each
    final resultA = AggregationService.buildIndexes(samplesA, [], coveragePrecision: widget.coveragePrecision);
    final resultB = AggregationService.buildIndexes(samplesB, [], coveragePrecision: widget.coveragePrecision);

    final mapA = {for (final c in resultA.coverages) c.id: c};
    final mapB = {for (final c in resultB.coverages) c.id: c};

    final allKeys = {...mapA.keys, ...mapB.keys};

    int newCells = 0, lostCells = 0, improved = 0, degraded = 0, unchanged = 0;

    for (final key in allKeys) {
      final a = mapA[key];
      final b = mapB[key];

      if (a == null && b != null) {
        newCells++;
      } else if (a != null && b == null) {
        lostCells++;
      } else if (a != null && b != null) {
        final rateA = (a.received + a.lost) > 0 ? a.received / (a.received + a.lost) : 0.0;
        final rateB = (b.received + b.lost) > 0 ? b.received / (b.received + b.lost) : 0.0;
        if (rateB - rateA > 0.1) {
          improved++;
        } else if (rateA - rateB > 0.1) {
          degraded++;
        } else {
          unchanged++;
        }
      }
    }

    // Stats
    final pingsA = samplesA.where((s) => s.pingSuccess != null).toList();
    final pingsB = samplesB.where((s) => s.pingSuccess != null).toList();
    final successA = pingsA.where((s) => s.pingSuccess == true).length;
    final successB = pingsB.where((s) => s.pingSuccess == true).length;
    final rateA = pingsA.isNotEmpty ? successA / pingsA.length : 0.0;
    final rateB = pingsB.isNotEmpty ? successB / pingsB.length : 0.0;

    final repeatersA = <String>{};
    final repeatersB = <String>{};
    for (final s in samplesA) {
      if (s.path != null) repeatersA.add(s.path!);
    }
    for (final s in samplesB) {
      if (s.path != null) repeatersB.add(s.path!);
    }

    setState(() {
      _result = _ComparisonResult(
        samplesA: samplesA.length,
        samplesB: samplesB.length,
        rateA: rateA,
        rateB: rateB,
        repeatersA: repeatersA.length,
        repeatersB: repeatersB.length,
        distanceA: _sessionA!.distanceMeters,
        distanceB: _sessionB!.distanceMeters,
        newCells: newCells,
        lostCells: lostCells,
        improved: improved,
        degraded: degraded,
        unchanged: unchanged,
      );
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_sessions.length < 2) {
      return const Center(
        child: Text('Need at least 2 completed sessions\nwith ping data to compare.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Compare Sessions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _sessionPicker('Session A (baseline)', _sessionA, (s) => setState(() { _sessionA = s; _result = null; })),
          const SizedBox(height: 8),
          _sessionPicker('Session B (compare)', _sessionB, (s) => setState(() { _sessionB = s; _result = null; })),
          const SizedBox(height: 12),
          Center(
            child: ElevatedButton.icon(
              onPressed: _sessionA != null && _sessionB != null && _sessionA!.id != _sessionB!.id
                  ? _compare
                  : null,
              icon: const Icon(Icons.compare_arrows),
              label: const Text('Compare'),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            // Side-by-side stats
            _compRow('Samples', '${_result!.samplesA}', '${_result!.samplesB}'),
            _compRow('Success Rate',
                '${(_result!.rateA * 100).toStringAsFixed(0)}%',
                '${(_result!.rateB * 100).toStringAsFixed(0)}%',
                delta: _result!.rateB - _result!.rateA),
            _compRow('Repeaters', '${_result!.repeatersA}', '${_result!.repeatersB}',
                delta: (_result!.repeatersB - _result!.repeatersA).toDouble()),
            _compRow('Distance',
                '${(_result!.distanceA / 1609.34).toStringAsFixed(1)} mi',
                '${(_result!.distanceB / 1609.34).toStringAsFixed(1)} mi'),
            const SizedBox(height: 16),
            const Text('Coverage Changes',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _changeRow('New coverage', _result!.newCells, Colors.green),
            _changeRow('Lost coverage', _result!.lostCells, Colors.red),
            _changeRow('Improved (>10%)', _result!.improved, Colors.lightGreen),
            _changeRow('Degraded (>10%)', _result!.degraded, Colors.orange),
            _changeRow('Unchanged', _result!.unchanged, Colors.grey),
          ],
        ],
      ),
    );
  }

  Widget _sessionPicker(String label, WSession? selected, void Function(WSession) onPicked) {
    final fmt = DateFormat('MMM d, h:mm a');
    return InkWell(
      onTap: () async {
        final picked = await showDialog<WSession>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(label),
            children: _sessions.map((s) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Text(
                '${fmt.format(s.startTime)} — ${s.pingCount} pings, '
                '${(s.successRate * 100).toStringAsFixed(0)}%',
              ),
            )).toList(),
          ),
        );
        if (picked != null) onPicked(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selected != null
                    ? '${fmt.format(selected.startTime)} — ${selected.pingCount} pings'
                    : label,
                style: TextStyle(
                  color: selected != null ? null : Colors.grey,
                  fontSize: 13,
                ),
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Widget _compRow(String label, String valueA, String valueB, {double? delta}) {
    Widget? deltaWidget;
    if (delta != null && delta != 0) {
      final isPositive = delta > 0;
      deltaWidget = Text(
        isPositive ? '▲' : '▼',
        style: TextStyle(color: isPositive ? Colors.green : Colors.red, fontSize: 12),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(label, style: const TextStyle(fontSize: 12))),
          Expanded(child: Text(valueA, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13))),
          const Text('→', style: TextStyle(color: Colors.grey)),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(valueB, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                if (deltaWidget != null) ...[const SizedBox(width: 4), deltaWidget],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _changeRow(String label, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 13)),
          ]),
          Text('$count', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _ComparisonResult {
  final int samplesA, samplesB;
  final double rateA, rateB;
  final int repeatersA, repeatersB;
  final double distanceA, distanceB;
  final int newCells, lostCells, improved, degraded, unchanged;

  _ComparisonResult({
    required this.samplesA, required this.samplesB,
    required this.rateA, required this.rateB,
    required this.repeatersA, required this.repeatersB,
    required this.distanceA, required this.distanceB,
    required this.newCells, required this.lostCells,
    required this.improved, required this.degraded, required this.unchanged,
  });
}

// =============================================================================
// TAB 4: Repeater Reliability Scores
// =============================================================================

class _RepeaterReliabilityTab extends StatefulWidget {
  final List<Sample> samples;
  const _RepeaterReliabilityTab({required this.samples});

  @override
  State<_RepeaterReliabilityTab> createState() => _RepeaterReliabilityTabState();
}

class _RepeaterReliabilityTabState extends State<_RepeaterReliabilityTab> {
  String _sortBy = 'reliability'; // 'reliability', 'responseTime', 'pings'

  @override
  Widget build(BuildContext context) {
    // Group samples by repeater (path)
    final Map<String, List<Sample>> byRepeater = {};
    for (final s in widget.samples) {
      if (s.pingSuccess != null && s.path != null && s.path!.isNotEmpty) {
        byRepeater.putIfAbsent(s.path!, () => []);
        byRepeater[s.path!]!.add(s);
      }
    }

    if (byRepeater.isEmpty) {
      return const Center(
        child: Text('No repeater data yet.\nDo some wardriving first!',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
      );
    }

    // Compute stats per repeater
    final stats = byRepeater.entries.map((e) => _computeRepeaterStats(e.key, e.value)).toList();

    // Sort
    switch (_sortBy) {
      case 'responseTime':
        stats.sort((a, b) => (a.avgResponseMs ?? 99999).compareTo(b.avgResponseMs ?? 99999));
        break;
      case 'pings':
        stats.sort((a, b) => b.totalPings.compareTo(a.totalPings));
        break;
      default: // reliability
        stats.sort((a, b) => b.responseRate.compareTo(a.responseRate));
    }

    return Column(
      children: [
        // Sort selector
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text('${stats.length} repeaters',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const Spacer(),
              const Text('Sort: ', style: TextStyle(fontSize: 12)),
              DropdownButton<String>(
                value: _sortBy,
                isDense: true,
                items: const [
                  DropdownMenuItem(value: 'reliability', child: Text('Reliability', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 'responseTime', child: Text('Response Time', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 'pings', child: Text('Ping Count', style: TextStyle(fontSize: 12))),
                ],
                onChanged: (v) => setState(() => _sortBy = v!),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: stats.length,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemBuilder: (context, index) => _buildRepeaterCard(stats[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildRepeaterCard(_RepeaterStats stats) {
    final displayId = stats.id.length > 8
        ? stats.id.substring(0, 8).toUpperCase()
        : stats.id.toUpperCase();

    Color rateColor;
    if (stats.responseRate > 0.7) {
      rateColor = Colors.green;
    } else if (stats.responseRate > 0.3) {
      rateColor = Colors.orange;
    } else {
      rateColor = Colors.red;
    }

    String trendIcon;
    Color trendColor;
    switch (stats.trend) {
      case 'improving':
        trendIcon = '▲';
        trendColor = Colors.green;
        break;
      case 'degrading':
        trendIcon = '▼';
        trendColor = Colors.red;
        break;
      default:
        trendIcon = '—';
        trendColor = Colors.grey;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cell_tower, size: 18, color: rateColor),
                const SizedBox(width: 8),
                Text(displayId, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(trendIcon, style: TextStyle(color: trendColor, fontSize: 16)),
                const SizedBox(width: 4),
                Text(
                  '${(stats.responseRate * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: rateColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _miniStat('Pings', '${stats.totalPings}'),
                _miniStat('Avg Response', stats.avgResponseMs != null ? '${stats.avgResponseMs!.toStringAsFixed(0)} ms' : '—'),
                _miniStat('Consistency', stats.consistencyScore != null ? stats.consistencyScore!.toStringAsFixed(0) : '—'),
                _miniStat('Trend', stats.trend),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'First seen: ${DateFormat('MMM d').format(stats.firstSeen)} • '
              'Last: ${DateFormat('MMM d').format(stats.lastSeen)}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  _RepeaterStats _computeRepeaterStats(String id, List<Sample> samples) {
    final successes = samples.where((s) => s.pingSuccess == true).length;
    final totalPings = samples.length;
    final responseRate = totalPings > 0 ? successes / totalPings : 0.0;

    // Response times
    final responseTimes = samples
        .where((s) => s.responseTimeMs != null)
        .map((s) => s.responseTimeMs!.toDouble())
        .toList();

    double? avgResponse;
    double? stddev;
    if (responseTimes.isNotEmpty) {
      avgResponse = responseTimes.reduce((a, b) => a + b) / responseTimes.length;
      final variance = responseTimes.map((t) => (t - avgResponse!) * (t - avgResponse!)).reduce((a, b) => a + b) / responseTimes.length;
      stddev = sqrt(variance);
    }

    // Trend: compare last 7 days vs prior 7 days
    final now = DateTime.now();
    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    final fourteenDaysAgo = now.subtract(const Duration(days: 14));

    final recent = samples.where((s) => s.timestamp.isAfter(sevenDaysAgo)).toList();
    final prior = samples.where((s) => s.timestamp.isAfter(fourteenDaysAgo) && s.timestamp.isBefore(sevenDaysAgo)).toList();

    String trend = 'stable';
    if (recent.length >= 3 && prior.length >= 3) {
      final recentRate = recent.where((s) => s.pingSuccess == true).length / recent.length;
      final priorRate = prior.where((s) => s.pingSuccess == true).length / prior.length;
      if (recentRate - priorRate > 0.1) {
        trend = 'improving';
      } else if (priorRate - recentRate > 0.1) {
        trend = 'degrading';
      }
    }

    // First/last seen
    samples.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final firstSeen = samples.first.timestamp;
    final lastSeen = samples.last.timestamp;

    return _RepeaterStats(
      id: id,
      totalPings: totalPings,
      responseRate: responseRate,
      avgResponseMs: avgResponse,
      consistencyScore: stddev,
      trend: trend,
      firstSeen: firstSeen,
      lastSeen: lastSeen,
    );
  }
}

class _RepeaterStats {
  final String id;
  final int totalPings;
  final double responseRate;
  final double? avgResponseMs;
  final double? consistencyScore; // stddev of response times
  final String trend; // 'improving', 'stable', 'degrading'
  final DateTime firstSeen;
  final DateTime lastSeen;

  _RepeaterStats({
    required this.id,
    required this.totalPings,
    required this.responseRate,
    this.avgResponseMs,
    this.consistencyScore,
    required this.trend,
    required this.firstSeen,
    required this.lastSeen,
  });
}
