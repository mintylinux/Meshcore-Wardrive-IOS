import 'dart:async';
import 'dart:typed_data';
import 'meshcore_protocol.dart';
import 'lora_companion_service.dart';
import 'settings_service.dart';
import 'debug_log_service.dart';

/// Carpeater Mode Service
/// 
/// Enables "Car Repeater" wardrive mode where instead of using the companion
/// radio directly for discovery, we log into a target repeater and use IT to
/// discover neighbors. Useful for leveraging a more powerful antenna or
/// mapping from the repeater's vantage point.

enum CarpeaterState {
  disabled,
  connecting,
  loggingIn,
  loggedIn,
  discovering,
  fetchingNeighbours,
  error,
}

class CarpeaterService {
  final LoRaCompanionService _loraService;
  final SettingsService _settingsService;
  final _debugLog = DebugLogService();
  final _protocol = MeshCoreProtocol();
  
  // State
  CarpeaterState _state = CarpeaterState.disabled;
  String? _targetRepeaterId;
  String? _targetRepeaterPassword;
  Uint8List? _targetRepeaterPubKeyBytes;
  int _discoveryIntervalSeconds = 30;
  bool _isAdmin = false;
  Completer<void>? _stopSignal;

  // Cycle tracking
  int _cyclesCompleted = 0;
  int _totalNeighboursFound = 0;
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 3;

  // Results
  final _neighboursController = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _stateController = StreamController<CarpeaterState>.broadcast();
  final _discoveryStartedController = StreamController<void>.broadcast();
  List<Map<String, dynamic>> _lastNeighbours = [];
  DateTime? _lastDiscoveryTime;

  // Response completers
  Completer<Map<String, dynamic>?>? _loginCompleter;
  Completer<bool>? _sentCompleter;
  Completer<Map<String, dynamic>?>? _neighboursCompleter;
  
  CarpeaterService(this._loraService, this._settingsService);
  
  // Public getters
  CarpeaterState get state => _state;
  Stream<CarpeaterState> get stateStream => _stateController.stream;
  Stream<List<Map<String, dynamic>>> get neighboursStream => _neighboursController.stream;
  Stream<void> get discoveryStartedStream => _discoveryStartedController.stream;
  List<Map<String, dynamic>> get lastNeighbours => List.unmodifiable(_lastNeighbours);
  DateTime? get lastDiscoveryTime => _lastDiscoveryTime;
  int get cyclesCompleted => _cyclesCompleted;
  int get totalNeighboursFound => _totalNeighboursFound;
  bool get isLoggedIn => _state == CarpeaterState.loggedIn || 
                          _state == CarpeaterState.discovering || 
                          _state == CarpeaterState.fetchingNeighbours;
  bool get isAdmin => _isAdmin;
  String? get targetRepeaterId => _targetRepeaterId;
  
  /// Initialize Carpeater mode with settings
  Future<void> initialize() async {
    final enabled = await _settingsService.getCarpeaterEnabled();
    if (!enabled) {
      _setState(CarpeaterState.disabled);
      return;
    }
    
    _targetRepeaterId = await _settingsService.getCarpeaterRepeaterId();
    _targetRepeaterPassword = await _settingsService.getCarpeaterPassword();
    _discoveryIntervalSeconds = await _settingsService.getCarpeaterInterval();
    
    if (_targetRepeaterId == null || _targetRepeaterId!.isEmpty) {
      _debugLog.logError('Carpeater: No target repeater ID configured');
      _setState(CarpeaterState.error);
      return;
    }
    
    if (_targetRepeaterPassword == null || _targetRepeaterPassword!.isEmpty) {
      _debugLog.logError('Carpeater: No password configured');
      _setState(CarpeaterState.error);
      return;
    }
    
    _debugLog.logInfo('Carpeater: Initialized for repeater $_targetRepeaterId');
  }
  
  /// Start Carpeater mode
  Future<bool> start() async {
    if (!_loraService.isDeviceConnected) {
      _debugLog.logError('Carpeater: LoRa device not connected');
      _setState(CarpeaterState.error);
      return false;
    }
    
    await initialize();
    
    if (_state == CarpeaterState.error) {
      return false;
    }
    
    _cyclesCompleted = 0;
    _totalNeighboursFound = 0;
    _consecutiveFailures = 0;
    
    final loggedIn = await _connectAndLogin();
    if (!loggedIn) return false;
    
    _startDiscoveryLoop();
    return true;
  }
  
  /// Connect to repeater and login. Returns true on success.
  Future<bool> _connectAndLogin() async {
    _setState(CarpeaterState.connecting);
    
    final found = await _findTargetRepeater();
    if (!found) {
      _debugLog.logError('Carpeater: Target repeater not found in contacts');
      _setState(CarpeaterState.error);
      return false;
    }
    
    _setState(CarpeaterState.loggingIn);
    final loggedIn = await _loginToRepeater();
    if (!loggedIn) {
      _debugLog.logError('Carpeater: Login failed');
      _setState(CarpeaterState.error);
      return false;
    }
    
    _setState(CarpeaterState.loggedIn);
    _debugLog.logInfo('Carpeater: Logged in successfully (admin=$_isAdmin)');
    return true;
  }
  
  /// Stop Carpeater mode
  void stop() {
    if (_stopSignal != null && !_stopSignal!.isCompleted) {
      _stopSignal!.complete();
    }
    _stopSignal = null;
    _loginCompleter?.complete(null);
    _sentCompleter?.complete(false);
    _neighboursCompleter?.complete(null);
    _loginCompleter = null;
    _sentCompleter = null;
    _neighboursCompleter = null;
    _loraService.setCarpeaterCallback(null);
    _setState(CarpeaterState.disabled);
    _debugLog.logInfo('Carpeater: Stopped');
  }
  
  /// Find the target repeater in the contact list
  Future<bool> _findTargetRepeater() async {
    if (_targetRepeaterId == null) return false;

    _debugLog.logInfo('Carpeater: Looking for repeater $_targetRepeaterId');

    _targetRepeaterPubKeyBytes = _loraService.getContactPubKey(_targetRepeaterId!);
    if (_targetRepeaterPubKeyBytes != null) {
      _debugLog.logInfo('Carpeater: Found pubkey in contact cache');
      return true;
    }

    await _loraService.refreshContactList();
    await Future.delayed(const Duration(seconds: 3));

    _targetRepeaterPubKeyBytes = _loraService.getContactPubKey(_targetRepeaterId!);
    if (_targetRepeaterPubKeyBytes != null) {
      _debugLog.logInfo('Carpeater: Found pubkey after contact refresh');
      return true;
    }

    _debugLog.logError(
      'Carpeater: Repeater $_targetRepeaterId not found in contacts',
    );
    return false;
  }
  
  /// Login to the target repeater (retries up to 3 times)
  Future<bool> _loginToRepeater() async {
    if (_targetRepeaterId == null || _targetRepeaterPassword == null) return false;
    if (_targetRepeaterPubKeyBytes == null) return false;

    const maxAttempts = 3;
    const retryDelay = Duration(seconds: 5);

    _loraService.setCarpeaterCallback(_handleIncomingPayload);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        _debugLog.logInfo('Carpeater: Login retry $attempt/$maxAttempts');
        await Future.delayed(retryDelay);
      }

      try {
        _loginCompleter = Completer<Map<String, dynamic>?>();

        final sent = await _loraService.sendRepeaterLogin(
          targetPubKey: _targetRepeaterPubKeyBytes!,
          password: _targetRepeaterPassword!,
        );
        if (!sent) {
          _loginCompleter = null;
          continue;
        }

        final response = await _loginCompleter!.future
            .timeout(const Duration(seconds: 10), onTimeout: () => null);
        _loginCompleter = null;

        if (response == null) {
          _debugLog.logError('Carpeater: Login timed out (attempt $attempt)');
          continue;
        }
        if (response['success'] != true) {
          _debugLog.logError('Carpeater: Login rejected — giving up');
          _loraService.setCarpeaterCallback(null);
          return false;
        }

        _isAdmin = response['is_admin'] as bool? ?? false;
        return true;
      } catch (e) {
        _debugLog.logError('Carpeater: Login error (attempt $attempt): $e');
        _loginCompleter = null;
      }
    }

    _loraService.setCarpeaterCallback(null);
    return false;
  }
  
  /// Kick off the sequential discovery loop
  void _startDiscoveryLoop() {
    _stopSignal = Completer<void>();
    _debugLog.logInfo(
      'Carpeater: Discovery loop started (interval: ${_discoveryIntervalSeconds}s)',
    );
    _runDiscoveryLoop();
  }

  Future<void> _runDiscoveryLoop() async {
    while (_stopSignal != null && !_stopSignal!.isCompleted) {
      await _runDiscoveryCycle();
      if (_stopSignal == null || _stopSignal!.isCompleted) break;
      if (_state == CarpeaterState.disabled) break;
      
      // Auto-reconnect after consecutive failures
      if (_state == CarpeaterState.error) {
        if (_consecutiveFailures >= _maxConsecutiveFailures) {
          _debugLog.logInfo('Carpeater: $_consecutiveFailures consecutive failures — attempting re-login...');
          _consecutiveFailures = 0;
          final reconnected = await _connectAndLogin();
          if (!reconnected) {
            _debugLog.logError('Carpeater: Re-login failed — stopping');
            break;
          }
        }
      }
      
      _debugLog.logInfo(
        'Carpeater: Cycle $cyclesCompleted complete — waiting ${_discoveryIntervalSeconds}s...',
      );
      await Future.any([
        Future.delayed(Duration(seconds: _discoveryIntervalSeconds)),
        _stopSignal!.future,
      ]);
    }
    _debugLog.logInfo('Carpeater: Discovery loop exited');
  }
  
  /// Run a single discovery cycle
  Future<void> _runDiscoveryCycle() async {
    if (_state == CarpeaterState.disabled) return;
    
    try {
      _setState(CarpeaterState.discovering);
      
      // Step 1: Clear neighbour table
      final clearOk = await _clearPreviousNeighbours();
      if (!clearOk) {
        _debugLog.logError('Carpeater: Could not clear neighbours — continuing anyway');
      }

      // Step 2: Trigger discovery
      final advertOk = await _triggerRepeaterAdvert();
      if (!advertOk) {
        _debugLog.logError('Carpeater: Could not trigger advert — skipping cycle');
        _consecutiveFailures++;
        _setState(CarpeaterState.loggedIn);
        return;
      }

      // Notify listeners to snapshot GPS position
      _discoveryStartedController.add(null);
      
      // Step 3: Wait for responses (respects stop signal)
      const discoveryWaitSeconds = 30;
      _debugLog.logInfo('Carpeater: Waiting ${discoveryWaitSeconds}s for responses...');
      await Future.any([
        Future.delayed(const Duration(seconds: discoveryWaitSeconds)),
        if (_stopSignal != null) _stopSignal!.future,
      ]);
      if (_stopSignal == null || _stopSignal!.isCompleted) return;
      
      // Step 4: Fetch neighbours
      _setState(CarpeaterState.fetchingNeighbours);
      final neighbours = await _fetchNeighbours();
      
      if (neighbours != null && neighbours.isNotEmpty) {
        _lastNeighbours = neighbours;
        _lastDiscoveryTime = DateTime.now();
        _neighboursController.add(neighbours);
        _totalNeighboursFound += neighbours.length;
        _debugLog.logInfo('Carpeater: Found ${neighbours.length} neighbours');
        _consecutiveFailures = 0;
      } else {
        _debugLog.logInfo('Carpeater: No neighbours found this cycle');
        _neighboursController.add([]);
      }
      
      _cyclesCompleted++;
      _setState(CarpeaterState.loggedIn);
      
    } catch (e) {
      _debugLog.logError('Carpeater: Discovery cycle error: $e');
      _consecutiveFailures++;
      _setState(CarpeaterState.error);
    }
  }
  
  Future<bool> _triggerRepeaterAdvert() async {
    if (_targetRepeaterPubKeyBytes == null) return false;

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) await Future.delayed(const Duration(seconds: 3));
      try {
        _sentCompleter = Completer<bool>();
        final enqueued = await _loraService.sendRepeaterCliCommand(
          targetPubKey: _targetRepeaterPubKeyBytes!,
          command: 'discover.neighbors',
        );
        if (!enqueued) { _sentCompleter = null; continue; }
        final acked = await _sentCompleter!.future
            .timeout(const Duration(seconds: 10), onTimeout: () => false);
        _sentCompleter = null;
        if (acked) return true;
      } catch (e) {
        _sentCompleter = null;
      }
    }
    return false;
  }
  
  Future<List<Map<String, dynamic>>?> _fetchNeighbours() async {
    if (_targetRepeaterPubKeyBytes == null) return null;

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) await Future.delayed(const Duration(seconds: 5));
      try {
        _neighboursCompleter = Completer<Map<String, dynamic>?>();
        final sent = await _loraService.sendRepeaterGetNeighbours(
          targetPubKey: _targetRepeaterPubKeyBytes!,
        );
        if (!sent) { _neighboursCompleter = null; continue; }
        final response = await _neighboursCompleter!.future
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        _neighboursCompleter = null;
        if (response == null) continue;
        return (response['neighbours'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      } catch (e) {
        _neighboursCompleter = null;
      }
    }
    return null;
  }
  
  Future<bool> _clearPreviousNeighbours() async {
    if (_targetRepeaterPubKeyBytes == null) return false;

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) await Future.delayed(const Duration(seconds: 3));
      try {
        _sentCompleter = Completer<bool>();
        final enqueued = await _loraService.sendRepeaterCliCommand(
          targetPubKey: _targetRepeaterPubKeyBytes!,
          command: 'neighbor.remove ',
        );
        if (!enqueued) { _sentCompleter = null; continue; }
        final acked = await _sentCompleter!.future
            .timeout(const Duration(seconds: 10), onTimeout: () => false);
        _sentCompleter = null;
        if (acked) return true;
      } catch (e) {
        _sentCompleter = null;
      }
    }
    return false;
  }

  void _handleIncomingPayload(int pushCode, Uint8List data) {
    switch (pushCode) {
      case PUSH_CODE_LOGIN_SUCCESS:
        if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
          _loginCompleter!.complete(_protocol.parseLoginSuccessPush(data));
        }
        break;
      case PUSH_CODE_LOGIN_FAIL:
        if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
          _loginCompleter!.complete(_protocol.parseLoginFailPush(data));
        }
        break;
      case RESP_CODE_SENT:
        if (_sentCompleter != null && !_sentCompleter!.isCompleted) {
          _sentCompleter!.complete(true);
        }
        break;
      case PUSH_CODE_BINARY_RESPONSE:
        if (_neighboursCompleter != null && !_neighboursCompleter!.isCompleted) {
          final result = _protocol.parseBinaryResponseNeighbours(data, 8);
          if (result != null) {
            _neighboursCompleter!.complete(result);
          }
        }
        break;
      default:
        _debugLog.logLoRa(
          'Carpeater: Unhandled push 0x${pushCode.toRadixString(16)} '
          '(${data.length} bytes)',
        );
    }
  }
  
  void _setState(CarpeaterState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }
  
  void dispose() {
    stop();
    _neighboursController.close();
    _stateController.close();
    _discoveryStartedController.close();
  }
}
