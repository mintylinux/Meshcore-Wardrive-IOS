import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import 'dart:io';

class DatabaseService {
  static Database? _database;
  static const String _databaseName = 'meshcore_wardrive.db';
  static const int _databaseVersion = 7;

  static const String tableSamples = 'samples';
  static const String tableUploads = 'uploads';
  static const String tableSessions = 'sessions';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String path = join(appDocDir.path, _databaseName);

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableSamples (
        id TEXT PRIMARY KEY,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        timestamp INTEGER NOT NULL,
        path TEXT,
        geohash TEXT NOT NULL,
        rssi INTEGER,
        snr INTEGER,
        pingSuccess INTEGER,
        observerNames TEXT,
        uploaded INTEGER DEFAULT 0,
        response_time_ms INTEGER
      )
    ''');

    // Create index on geohash for faster queries
    await db.execute('''
      CREATE INDEX idx_samples_geohash ON $tableSamples (geohash)
    ''');

    // Create index on timestamp for sorting
    await db.execute('''
      CREATE INDEX idx_samples_timestamp ON $tableSamples (timestamp)
    ''');
    
    // Create uploads tracking table (per-endpoint upload tracking)
    await db.execute('''
      CREATE TABLE $tableUploads (
        sample_id TEXT NOT NULL,
        endpoint_url TEXT NOT NULL,
        uploaded_at INTEGER NOT NULL,
        PRIMARY KEY (sample_id, endpoint_url)
      )
    ''');
    
    // Create index on endpoint_url for faster queries
    await db.execute('''
      CREATE INDEX idx_uploads_endpoint ON $tableUploads (endpoint_url)
    ''');
    
    // Create sessions table
    await db.execute('''
      CREATE TABLE $tableSessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_time INTEGER NOT NULL,
        end_time INTEGER,
        distance_meters REAL DEFAULT 0,
        sample_count INTEGER DEFAULT 0,
        ping_count INTEGER DEFAULT 0,
        success_count INTEGER DEFAULT 0,
        notes TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add new columns for ping data
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN rssi INTEGER');
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN snr INTEGER');
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN pingSuccess INTEGER');
    }
    if (oldVersion < 3) {
      // Add observer names column
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN observerNames TEXT');
    }
    if (oldVersion < 4) {
      // Add uploaded tracking column
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN uploaded INTEGER DEFAULT 0');
    }
    if (oldVersion < 5) {
      // Create uploads tracking table for per-endpoint upload tracking
      await db.execute('''
        CREATE TABLE $tableUploads (
          sample_id TEXT NOT NULL,
          endpoint_url TEXT NOT NULL,
          uploaded_at INTEGER NOT NULL,
          PRIMARY KEY (sample_id, endpoint_url)
        )
      ''');
      
      await db.execute('''
        CREATE INDEX idx_uploads_endpoint ON $tableUploads (endpoint_url)
      ''');
      
      // Migrate existing uploaded samples to new table (assume default endpoint)
      await db.execute('''
        INSERT INTO $tableUploads (sample_id, endpoint_url, uploaded_at)
        SELECT id, 'https://meshwar-map.pages.dev/api/samples', ?
        FROM $tableSamples WHERE uploaded = 1
      ''', [DateTime.now().millisecondsSinceEpoch]);
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE $tableSessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          start_time INTEGER NOT NULL,
          end_time INTEGER,
          distance_meters REAL DEFAULT 0,
          sample_count INTEGER DEFAULT 0,
          ping_count INTEGER DEFAULT 0,
          success_count INTEGER DEFAULT 0,
          notes TEXT
        )
      ''');
    }
    if (oldVersion < 7) {
      await db.execute('ALTER TABLE $tableSamples ADD COLUMN response_time_ms INTEGER');
    }
  }

  /// Insert a sample into the database
  Future<void> insertSample(Sample sample) async {
    final db = await database;
    await db.insert(
      tableSamples,
      sample.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Insert multiple samples
  Future<void> insertSamples(List<Sample> samples) async {
    final db = await database;
    final batch = db.batch();
    for (final sample in samples) {
      batch.insert(
        tableSamples,
        sample.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Get all samples
  Future<List<Sample>> getAllSamples() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get samples within a time range
  Future<List<Sample>> getSamplesByTimeRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'timestamp >= ? AND timestamp <= ?',
      whereArgs: [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch],
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get samples since a specific time
  Future<List<Sample>> getSamplesSince(DateTime since) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'timestamp > ?',
      whereArgs: [since.millisecondsSinceEpoch],
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get only samples that haven't been uploaded yet
  Future<List<Sample>> getUnuploadedSamples() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      where: 'uploaded = 0',
      orderBy: 'timestamp DESC',
    );

    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Mark specific samples as uploaded
  Future<void> markSamplesAsUploaded(List<String> sampleIds) async {
    final db = await database;
    final batch = db.batch();
    for (final id in sampleIds) {
      batch.update(
        tableSamples,
        {'uploaded': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }
  
  /// Mark samples as uploaded to a specific endpoint
  Future<void> markSamplesAsUploadedToEndpoint(List<String> sampleIds, String endpointUrl) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    
    for (final id in sampleIds) {
      batch.insert(
        tableUploads,
        {
          'sample_id': id,
          'endpoint_url': endpointUrl,
          'uploaded_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }
  
  /// Get samples that haven't been uploaded to a specific endpoint
  Future<List<Sample>> getUnuploadedSamplesForEndpoint(String endpointUrl) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT s.* FROM $tableSamples s
      LEFT JOIN $tableUploads u ON s.id = u.sample_id AND u.endpoint_url = ?
      WHERE u.sample_id IS NULL
      ORDER BY s.timestamp DESC
    ''', [endpointUrl]);
    
    return maps.map((map) => Sample.fromMap(map)).toList();
  }

  /// Get count of unuploaded samples
  Future<int> getUnuploadedSampleCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableSamples WHERE uploaded = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Get the most recent sample
  Future<Sample?> getMostRecentSample() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tableSamples,
      orderBy: 'timestamp DESC',
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Sample.fromMap(maps.first);
  }

  /// Get sample count
  Future<int> getSampleCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM $tableSamples');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Delete all samples
  Future<void> deleteAllSamples() async {
    final db = await database;
    await db.delete(tableSamples);
  }

  /// Delete samples older than a certain date
  Future<void> deleteSamplesOlderThan(DateTime date) async {
    final db = await database;
    await db.delete(
      tableSamples,
      where: 'timestamp < ?',
      whereArgs: [date.millisecondsSinceEpoch],
    );
  }

  /// Export all samples as JSON
  Future<List<Map<String, dynamic>>> exportSamples() async {
    final samples = await getAllSamples();
    return samples.map((s) => s.toJson()).toList();
  }

  /// Import samples from JSON (skips duplicates by ID)
  Future<int> importSamples(List<Map<String, dynamic>> jsonData) async {
    final db = await database;
    int importedCount = 0;
    
    for (final json in jsonData) {
      try {
        final sample = Sample.fromJson(json);
        
        // Check if sample with this ID already exists
        final existing = await db.query(
          tableSamples,
          where: 'id = ?',
          whereArgs: [sample.id],
          limit: 1,
        );
        
        if (existing.isEmpty) {
          await db.insert(
            tableSamples,
            sample.toMap(),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          importedCount++;
        }
      } catch (e) {
        print('Error importing sample: $e');
        // Skip invalid samples
      }
    }
    
    return importedCount;
  }

  /// Create a new session, returns the session ID
  Future<int> createSession(WSession session) async {
    final db = await database;
    return await db.insert(tableSessions, session.toMap());
  }
  
  /// Update an existing session
  Future<void> updateSession(WSession session) async {
    final db = await database;
    await db.update(
      tableSessions,
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }
  
  /// Get all sessions, newest first
  Future<List<WSession>> getAllSessions() async {
    final db = await database;
    final maps = await db.query(
      tableSessions,
      orderBy: 'start_time DESC',
    );
    return maps.map((m) => WSession.fromMap(m)).toList();
  }
  
  /// Delete a session by ID
  Future<void> deleteSession(int id) async {
    final db = await database;
    await db.delete(tableSessions, where: 'id = ?', whereArgs: [id]);
  }
  
  /// Get sample counts for a session's time range
  Future<Map<String, int>> getSessionSampleCounts(DateTime start, DateTime end) async {
    final db = await database;
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    
    final totalResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE timestamp >= ? AND timestamp <= ?',
      [startMs, endMs],
    );
    final pingResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE timestamp >= ? AND timestamp <= ? AND pingSuccess IS NOT NULL',
      [startMs, endMs],
    );
    final successResult = await db.rawQuery(
      'SELECT COUNT(*) FROM $tableSamples WHERE timestamp >= ? AND timestamp <= ? AND pingSuccess = 1',
      [startMs, endMs],
    );
    
    return {
      'total': Sqflite.firstIntValue(totalResult) ?? 0,
      'pings': Sqflite.firstIntValue(pingResult) ?? 0,
      'successes': Sqflite.firstIntValue(successResult) ?? 0,
    };
  }

  /// Close the database
  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
