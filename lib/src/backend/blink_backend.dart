import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class CameraDevice {
  const CameraDevice(this.id, this.name);
  final String id;
  final String name;
  factory CameraDevice.fromJson(Map<dynamic, dynamic> json) =>
      CameraDevice(json['id'] as String, json['name'] as String);
}

abstract class BlinkBackend {
  Stream<Map<String, dynamic>> get events;
  Future<List<CameraDevice>> cameras();
  Future<void> start(String runId, String cameraId, double sensitivity);
  Future<void> stop();
  Future<void> recalibrate(double sensitivity);
  Future<void> dispose();
}

class MacOSBackend implements BlinkBackend {
  static const channel = MethodChannel('com.dorbmon.blinkmonitor/control');
  static const eventChannel = EventChannel('com.dorbmon.blinkmonitor/events');
  late final Stream<Map<String, dynamic>> _events = eventChannel
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map))
      .asBroadcastStream();
  @override
  Stream<Map<String, dynamic>> get events => _events;
  @override
  Future<List<CameraDevice>> cameras() async =>
      (await channel.invokeListMethod<dynamic>('cameras') ?? [])
          .map((item) => CameraDevice.fromJson(item as Map))
          .toList();
  @override
  Future<void> start(String runId, String cameraId, double sensitivity) =>
      channel.invokeMethod('start', {
        'runId': runId,
        'cameraId': cameraId,
        'sensitivity': sensitivity,
      });
  @override
  Future<void> stop() => channel.invokeMethod('stop');
  @override
  Future<void> recalibrate(double sensitivity) =>
      channel.invokeMethod('recalibrate', {'sensitivity': sensitivity});
  @override
  Future<void> dispose() => stop();
}

/// Linux runs an isolated local camera worker. Its stdout is a versioned JSON-lines
/// protocol; no shell interpolation, ports, or network service is used.
class LinuxBackend implements BlinkBackend {
  LinuxBackend(this.runtimeDirectory);
  final Directory runtimeDirectory;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final Map<int, Completer<dynamic>> _pending = {};
  Process? _process;
  Future<void>? _launch;
  int _nextId = 0;
  bool _disposed = false;
  String _stderr = '';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> _ensureStarted() async {
    if (_disposed) throw StateError('Backend is closed');
    if (_process != null) return;
    if (_launch != null) return _launch;
    final launch = _spawn();
    _launch = launch;
    try {
      await launch;
    } finally {
      _launch = null;
    }
  }

  Future<void> _spawn() async {
    await runtimeDirectory.create(recursive: true);
    for (final name in ['blink_backend.py', 'detector.py']) {
      final content = await rootBundle.loadString('backend/linux/$name');
      await File(p.join(runtimeDirectory.path, name)).writeAsString(content);
    }
    final home = Platform.environment['HOME'] ?? '';
    final dataHome =
        Platform.environment['XDG_DATA_HOME'] ??
        p.join(home, '.local', 'share');
    final installedPython = p.join(
      dataHome,
      'blinkmonitor',
      'venv',
      'bin',
      'python',
    );
    final python =
        Platform.environment['BLINKMONITOR_PYTHON'] ??
        (await File(installedPython).exists() ? installedPython : 'python3');
    final model =
        Platform.environment['BLINKMONITOR_MODEL'] ??
        p.join(dataHome, 'blinkmonitor', 'models', 'face_landmarker.task');
    _stderr = '';
    final process = await Process.start(python, [
      '-u',
      p.join(runtimeDirectory.path, 'blink_backend.py'),
      '--model',
      model,
    ]);
    if (_disposed) {
      process.kill();
      return;
    }
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final json = Map<String, dynamic>.from(jsonDecode(line) as Map);
            if (json['id'] is int) {
              final request = _pending.remove(json['id']);
              if (json['error'] != null) {
                request?.completeError(StateError(json['error'] as String));
              } else {
                request?.complete(json['result']);
              }
            } else if (!_events.isClosed) {
              _events.add(json);
            }
          } catch (error) {
            if (!_events.isClosed) {
              _events.add({
                'type': 'error',
                'message': 'Invalid response from camera backend: $error',
              });
            }
          }
        });
    process.stderr.transform(utf8.decoder).listen((chunk) {
      _stderr += chunk;
      if (_stderr.length > 2000) {
        _stderr = _stderr.substring(_stderr.length - 2000);
      }
    });
    unawaited(
      process.exitCode.then((code) {
        if (_process != process) return;
        _process = null;
        final error = StateError(
          'Linux camera backend exited ($code). ${_stderr.trim()}',
        );
        for (final pending in _pending.values) {
          pending.completeError(error);
        }
        _pending.clear();
        if (!_disposed && !_events.isClosed) {
          _events.add({'type': 'error', 'message': error.toString()});
        }
      }),
    );
  }

  Future<dynamic> _request(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    await _ensureStarted();
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _process!.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'args': arguments}),
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // A stuck V4L2 read cannot hold the camera forever after Pause.
      _process?.kill(ProcessSignal.sigkill);
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<List<CameraDevice>> cameras() async =>
      ((await _request('cameras')) as List)
          .map((item) => CameraDevice.fromJson(item as Map))
          .toList();
  @override
  Future<void> start(String runId, String cameraId, double sensitivity) async {
    await _request('start', {
      'runId': runId,
      'cameraId': cameraId,
      'sensitivity': sensitivity,
    });
  }

  @override
  Future<void> stop() async {
    if (_process != null) await _request('stop');
  }

  @override
  Future<void> recalibrate(double sensitivity) async {
    await _request('recalibrate', {'sensitivity': sensitivity});
  }

  @override
  Future<void> dispose() async {
    try {
      await stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Kill below if capture is stuck. */
    }
    _disposed = true;
    _process?.kill();
    final process = _process;
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
      }
    }
    await _events.close();
  }
}
