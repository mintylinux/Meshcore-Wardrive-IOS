import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/models.dart';
import '../services/database_service.dart';
import '../services/settings_service.dart';

class SessionHistoryScreen extends StatefulWidget {
  /// Optional callback when a session is selected (for map filtering)
  final void Function(WSession session)? onSessionSelected;
  
  const SessionHistoryScreen({super.key, this.onSessionSelected});

  @override
  State<SessionHistoryScreen> createState() => _SessionHistoryScreenState();
}

class _SessionHistoryScreenState extends State<SessionHistoryScreen> {
  final DatabaseService _dbService = DatabaseService();
  final SettingsService _settings = SettingsService();
  List<WSession> _sessions = [];
  bool _loading = true;
  String _distanceUnit = 'miles';

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await _dbService.getAllSessions();
    final unit = await _settings.getDistanceUnit();
    setState(() {
      _sessions = sessions;
      _distanceUnit = unit;
      _loading = false;
    });
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}s';
  }

  String _formatDistance(double meters) {
    if (_distanceUnit == 'km') {
      final km = meters / 1000.0;
      return '${km.toStringAsFixed(1)} km';
    } else {
      final miles = meters / 1609.34;
      return '${miles.toStringAsFixed(1)} mi';
    }
  }

  Future<void> _deleteSession(WSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Session?'),
        content: const Text('This will remove the session record. Sample data is not affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true && session.id != null) {
      await _dbService.deleteSession(session.id!);
      await _loadSessions();
    }
  }

  Future<void> _editNotes(WSession session) async {
    final controller = TextEditingController(text: session.notes ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session Notes'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Add notes about this session...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (result != null) {
      final updated = WSession(
        id: session.id,
        startTime: session.startTime,
        endTime: session.endTime,
        distanceMeters: session.distanceMeters,
        sampleCount: session.sampleCount,
        pingCount: session.pingCount,
        successCount: session.successCount,
        notes: result.isEmpty ? null : result,
      );
      await _dbService.updateSession(updated);
      await _loadSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Session History'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? const Center(
                  child: Text(
                    'No sessions yet.\n\nStart tracking to record your first session!',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: _sessions.length,
                  padding: const EdgeInsets.all(8),
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    return _buildSessionCard(session);
                  },
                ),
    );
  }

  Widget _buildSessionCard(WSession session) {
    final dateFormat = DateFormat('MMM d, yyyy');
    final timeFormat = DateFormat('h:mm a');
    final duration = session.duration;
    final successRate = session.successRate;
    
    // Determine status color based on success rate
    Color statusColor;
    if (session.pingCount == 0) {
      statusColor = Colors.grey;
    } else if (successRate != null && successRate >= 70) {
      statusColor = Colors.green;
    } else if (successRate != null && successRate >= 30) {
      statusColor = Colors.orange;
    } else {
      statusColor = Colors.red;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: widget.onSessionSelected != null
            ? () {
                widget.onSessionSelected!(session);
                Navigator.pop(context);
              }
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: date + actions
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    dateFormat.format(session.startTime),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.note_add, size: 20),
                        onPressed: () => _editNotes(session),
                        tooltip: 'Edit Notes',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(4),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                        onPressed: () => _deleteSession(session),
                        tooltip: 'Delete',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(4),
                      ),
                    ],
                  ),
                ],
              ),
              
              // Time range
              Text(
                '${timeFormat.format(session.startTime)}'
                '${session.endTime != null ? ' – ${timeFormat.format(session.endTime!)}' : ' – In progress'}',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              
              const SizedBox(height: 8),
              
              // Stats row
              Row(
                children: [
                  _buildStat(Icons.timer, duration != null ? _formatDuration(duration) : '--'),
                  const SizedBox(width: 16),
                  _buildStat(Icons.straighten, _formatDistance(session.distanceMeters)),
                  const SizedBox(width: 16),
                  _buildStat(Icons.location_on, '${session.sampleCount} pts'),
                ],
              ),
              
              const SizedBox(height: 4),
              
              // Ping stats row
              Row(
                children: [
                  _buildStat(Icons.cell_tower, '${session.pingCount} pings'),
                  const SizedBox(width: 16),
                  _buildStat(
                    Icons.check_circle,
                    '${session.successCount} heard',
                    color: Colors.green,
                  ),
                  const SizedBox(width: 16),
                  if (session.pingCount > 0)
                    _buildStat(
                      Icons.percent,
                      '${successRate?.toStringAsFixed(0)}%',
                      color: statusColor,
                    ),
                ],
              ),
              
              // Notes
              if (session.notes != null && session.notes!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  session.notes!,
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              
              // Tap hint when callback is provided
              if (widget.onSessionSelected != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Tap to view on map',
                  style: TextStyle(color: Theme.of(context).primaryColor, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStat(IconData icon, String text, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color ?? Colors.grey[600]),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(fontSize: 13, color: color ?? Colors.grey[600]),
        ),
      ],
    );
  }
}
