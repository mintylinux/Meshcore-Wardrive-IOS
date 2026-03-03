import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';

class SignalTrendScreen extends StatefulWidget {
  final List<Sample> samples;

  const SignalTrendScreen({super.key, required this.samples});

  @override
  State<SignalTrendScreen> createState() => _SignalTrendScreenState();
}

class _SignalTrendScreenState extends State<SignalTrendScreen> {
  String _metric = 'rssi'; // 'rssi', 'snr', 'responseTime'

  @override
  Widget build(BuildContext context) {
    // Filter to samples that have signal data, sorted by time
    final signalSamples = widget.samples
        .where((s) => s.pingSuccess != null)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Signal Trends'),
      ),
      body: Column(
        children: [
          // Metric selector
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'rssi', label: Text('RSSI')),
                ButtonSegment(value: 'snr', label: Text('SNR')),
                ButtonSegment(value: 'responseTime', label: Text('Response')),
              ],
              selected: {_metric},
              onSelectionChanged: (v) => setState(() => _metric = v.first),
            ),
          ),
          // Chart
          Expanded(
            child: signalSamples.isEmpty
                ? const Center(child: Text('No signal data yet.\nDo some wardriving with pings enabled.', textAlign: TextAlign.center))
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 24, 16),
                    child: _buildChart(signalSamples),
                  ),
          ),
          // Stats summary
          if (signalSamples.isNotEmpty) _buildStats(signalSamples),
        ],
      ),
    );
  }

  Widget _buildChart(List<Sample> samples) {
    final spots = <FlSpot>[];
    final timestamps = <double, DateTime>{};

    for (int i = 0; i < samples.length; i++) {
      final s = samples[i];
      double? value;
      if (_metric == 'rssi') {
        value = s.rssi?.toDouble();
      } else if (_metric == 'snr') {
        value = s.snr?.toDouble();
      } else {
        value = s.responseTimeMs?.toDouble();
      }
      if (value != null) {
        spots.add(FlSpot(i.toDouble(), value));
        timestamps[i.toDouble()] = s.timestamp;
      }
    }

    if (spots.isEmpty) {
      final label = _metric == 'responseTime' ? 'response time' : _metric.toUpperCase();
      return Center(child: Text('No $label data available.'));
    }

    final minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final range = maxY - minY;
    final padding = range > 0 ? range * 0.1 : 10;

    String yLabel;
    Color lineColor;
    if (_metric == 'rssi') {
      yLabel = 'dBm';
      lineColor = Colors.blue;
    } else if (_metric == 'snr') {
      yLabel = 'dB';
      lineColor = Colors.green;
    } else {
      yLabel = 'ms';
      lineColor = Colors.orange;
    }

    return LineChart(
      LineChartData(
        minY: minY - padding,
        maxY: maxY + padding,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: range > 0 ? (range / 5).ceilToDouble().clamp(1, double.infinity) : 10,
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            axisNameWidget: Text(yLabel, style: const TextStyle(fontSize: 12)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(fontSize: 10),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              interval: spots.length > 10 ? (spots.length / 5).ceilToDouble() : 1,
              getTitlesWidget: (value, meta) {
                final ts = timestamps[value];
                if (ts == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    DateFormat('HH:mm').format(ts),
                    style: const TextStyle(fontSize: 9),
                  ),
                );
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: true),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            color: lineColor,
            barWidth: 2,
            dotData: FlDotData(show: spots.length < 30),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withValues(alpha: 0.15),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final ts = timestamps[spot.x];
                final timeStr = ts != null ? DateFormat('MMM d HH:mm').format(ts) : '';
                return LineTooltipItem(
                  '${spot.y.toStringAsFixed(_metric == 'responseTime' ? 0 : 1)} $yLabel\n$timeStr',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStats(List<Sample> samples) {
    List<double> values;
    String unit;
    if (_metric == 'rssi') {
      values = samples.where((s) => s.rssi != null).map((s) => s.rssi!.toDouble()).toList();
      unit = 'dBm';
    } else if (_metric == 'snr') {
      values = samples.where((s) => s.snr != null).map((s) => s.snr!.toDouble()).toList();
      unit = 'dB';
    } else {
      values = samples.where((s) => s.responseTimeMs != null).map((s) => s.responseTimeMs!.toDouble()).toList();
      unit = 'ms';
    }

    if (values.isEmpty) return const SizedBox.shrink();

    final avg = values.reduce((a, b) => a + b) / values.length;
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _statCard('Min', '${min.toStringAsFixed(0)} $unit', Colors.red),
          _statCard('Avg', '${avg.toStringAsFixed(0)} $unit', Colors.blue),
          _statCard('Max', '${max.toStringAsFixed(0)} $unit', Colors.green),
          _statCard('Pts', '${values.length}', Colors.grey),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
