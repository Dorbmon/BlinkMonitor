import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'backend/blink_backend.dart';
import 'data/history.dart';

enum MonitorState {
  idle,
  starting,
  calibrating,
  tracking,
  noFace,
  paused,
  denied,
  failed,
}

class MonitorController extends ChangeNotifier {
  MonitorController(this.backend, this.store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final BlinkBackend backend;
  final HistoryStore store;
  final DateTime Function() _now;
  HistoryDocument history = HistoryDocument();
  MonitorState state = MonitorState.idle;
  bool running = false;
  bool ready = false;
  String? notice;
  String detail = '';
  List<CameraDevice> cameras = [];
  MonitoringSession? current;
  double? liveRate;
  double openness = 0;
  double calibration = 0;
  int page = 0;
  VoidCallback? onQuit;
  RollingRate _rolling = RollingRate();
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _timer;
  String? _runId;
  DateTime _lastPublish = DateTime(1970);
  DateTime _lastFrame = DateTime(1970);
  DateTime _lastSave = DateTime(1970);
  bool _stopping = false;
  bool _resumeAfterSleep = false;
  bool _closed = false;
  bool _saveFailureShown = false;

  List<MonitoringSession> get sessions => [
    ...history.sessions,
    if (current != null) current!,
  ];
  String get title => switch (state) {
    MonitorState.idle => 'Ready when you are',
    MonitorState.starting => 'Starting camera',
    MonitorState.calibrating => 'Calibrating your eyes',
    MonitorState.tracking => 'Tracking live',
    MonitorState.noFace => 'Looking for your face',
    MonitorState.paused => 'Monitoring paused',
    MonitorState.denied => 'Camera access needed',
    MonitorState.failed => 'Camera unavailable',
  };
  String get statusDetail => switch (state) {
    MonitorState.idle =>
      'A little awareness, one blink at a time. Your camera is off.',
    MonitorState.starting =>
      'Waiting for the camera. Allow access if your system asks.',
    MonitorState.calibrating =>
      'Look at the screen with your eyes naturally open for a few seconds.',
    MonitorState.tracking =>
      liveRate == null
          ? 'Collecting five seconds of tracked time for your first reading.'
          : 'Your rate uses the last 60 seconds of tracked time.',
    MonitorState.noFace =>
      detail.isEmpty ? 'Keep your face visible and use even lighting.' : detail,
    MonitorState.paused => 'Your camera is off. Resume whenever you’re ready.',
    MonitorState.denied || MonitorState.failed => detail,
  };
  String get menuTitle => state == MonitorState.tracking && liveRate != null
      ? '${liveRate!.round()} /min'
      : running
      ? '— /min'
      : 'Paused';

  Future<void> initialize() async {
    try {
      history = await store.load();
    } catch (error) {
      notice = '$error';
    }
    _prune();
    _subscription = backend.events.listen(
      _receive,
      onError: (Object error) {
        unawaited(_fail('$error'));
      },
    );
    await refreshCameras();
    ready = true;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    notifyListeners();
  }

  Future<void> refreshCameras() async {
    try {
      cameras = await backend.cameras();
    } catch (error) {
      notice = 'Could not list cameras: $error';
    }
    if (!_closed) notifyListeners();
  }

  void setPage(int value) {
    page = value;
    notifyListeners();
  }

  void dismissNotice() {
    notice = null;
    notifyListeners();
  }

  Future<void> start() async {
    if (!ready || running || _stopping || _closed) return;
    final id =
        '${_now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    _runId = id;
    current = MonitoringSession(id, _now());
    running = true;
    state = MonitorState.starting;
    detail = '';
    _rolling = RollingRate();
    liveRate = null;
    openness = 0;
    calibration = 0;
    _lastFrame = _now();
    _lastSave = _now();
    notifyListeners();
    try {
      await backend.start(id, history.cameraId, history.sensitivity);
      if (_runId == id && state == MonitorState.starting) {
        state = MonitorState.calibrating;
        _lastFrame = _now();
        notifyListeners();
      }
    } catch (error) {
      if (_runId == id) await _fail('$error');
    }
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _runId = null;
    running = false;
    if (current != null && current!.trackedSeconds > 0) {
      history.sessions.add(current!);
    }
    current = null;
    state = MonitorState.paused;
    liveRate = null;
    openness = 0;
    calibration = 0;
    _rolling = RollingRate();
    notifyListeners();
    try {
      await backend.stop();
    } catch (error) {
      notice = 'Could not stop the camera cleanly: $error';
    }
    await save();
    _stopping = false;
    if (!_closed) notifyListeners();
  }

  Future<void> recalibrate() async {
    if (!running) return;
    _rolling = RollingRate();
    liveRate = null;
    state = MonitorState.calibrating;
    calibration = 0;
    notifyListeners();
    try {
      await backend.recalibrate(history.sensitivity);
    } catch (error) {
      await _fail('$error');
    }
  }

  Future<void> selectCamera(String id) async {
    history.cameraId = id;
    if (running) {
      await stop();
      await start();
    }
    await save();
    notifyListeners();
  }

  void setSensitivity(double value) {
    history.sensitivity = value.clamp(.4, .8);
    notifyListeners();
  }

  Future<void> applySensitivity() async {
    await recalibrate();
    await save();
  }

  Future<void> clearHistory() async {
    history.sessions.clear();
    if (current != null) current = MonitoringSession(current!.id, _now());
    _rolling = RollingRate();
    liveRate = null;
    await save();
    notifyListeners();
  }

  Future<void> save() async {
    _prune();
    _lastSave = _now();
    try {
      await store.save(
        HistoryDocument(
          sessions: sessions,
          cameraId: history.cameraId,
          sensitivity: history.sensitivity,
        ),
      );
    } catch (error) {
      if (!_saveFailureShown) {
        notice = 'Could not save history: $error';
        _saveFailureShown = true;
        if (!_closed) notifyListeners();
      }
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _timer?.cancel();
    await stop();
    await _subscription?.cancel();
    await backend.dispose();
    _closed = true;
  }

  void _receive(Map<String, dynamic> event) {
    if (_closed) return;
    switch (event['type']) {
      case 'action':
        switch (event['action']) {
          case 'toggle':
            unawaited(running ? stop() : start());
          case 'settings':
            setPage(2);
          case 'quit':
            onQuit?.call();
          case 'sleep':
            _resumeAfterSleep = running;
            unawaited(stop());
          case 'wake':
            if (_resumeAfterSleep) {
              _resumeAfterSleep = false;
              unawaited(start());
            }
        }
      case 'error':
        if (event['runId'] == null || event['runId'] == _runId) {
          unawaited(
            _fail(event['message'] as String? ?? 'Unknown camera error'),
          );
        }
      case 'frame':
        if (!running || event['runId'] != _runId) return;
        try {
          final at = DateTime.fromMicrosecondsSinceEpoch(
            ((event['timestamp'] as num).toDouble() * 1000000).round(),
          );
          final seconds = (event['trackedDuration'] as num).toDouble();
          final blink = event['didBlink'] == true;
          _lastFrame = _now();
          current?.record(at, seconds, blink);
          _rolling.record(at, seconds, blink);
          if (_now().difference(_lastPublish).inMilliseconds < 250 && !blink) {
            return;
          }
          _lastPublish = _now();
          state = switch (event['state']) {
            'tracking' => MonitorState.tracking,
            'calibrating' => MonitorState.calibrating,
            _ => MonitorState.noFace,
          };
          detail = event['hint'] as String? ?? '';
          openness = (event['openness'] as num).toDouble().clamp(0, 1);
          calibration = (event['calibrationProgress'] as num).toDouble().clamp(
            0,
            1,
          );
          liveRate = state == MonitorState.tracking ? _rolling.at(at) : null;
          notifyListeners();
        } catch (error) {
          unawaited(_fail('Invalid tracking data: $error'));
        }
    }
  }

  Future<void> _fail(String message) async {
    await stop();
    state =
        message.toLowerCase().contains('permission') ||
            message.toLowerCase().contains('denied')
        ? MonitorState.denied
        : MonitorState.failed;
    detail = message;
    if (!_closed) notifyListeners();
  }

  void _tick() {
    if (!running) return;
    if (state != MonitorState.starting &&
        _now().difference(_lastFrame).inSeconds > 10) {
      unawaited(
        _fail(
          'The camera stopped delivering frames. Check its connection and try again.',
        ),
      );
    } else if (_now().difference(_lastSave).inSeconds >= 10) {
      unawaited(save());
    }
  }

  void _prune() {
    final cutoff = _now().subtract(const Duration(days: 90));
    history.sessions.removeWhere((session) => session.endedAt.isBefore(cutoff));
    for (final session in history.sessions) {
      session.minutes.removeWhere((row) => row.start.isBefore(cutoff));
    }
  }
}
