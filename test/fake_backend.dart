import 'dart:async';
import 'package:blink_monitor/src/backend/blink_backend.dart';

class FakeBackend implements BlinkBackend {
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  String? runId;
  int starts = 0;
  int stops = 0;
  Completer<void>? startGate;
  String? startError;
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<List<CameraDevice>> cameras() async => [
    const CameraDevice('test', 'Test camera'),
  ];
  @override
  Future<void> start(String runId, String cameraId, double sensitivity) async {
    this.runId = runId;
    starts++;
    if (startGate != null) await startGate!.future;
    if (startError != null) throw StateError(startError!);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> recalibrate(double sensitivity) async {}
  @override
  Future<void> dispose() => stream.close();
  void frame(
    DateTime at, {
    bool blink = false,
    String state = 'tracking',
    String? id,
  }) => stream.add({
    'type': 'frame',
    'runId': id ?? runId,
    'timestamp': at.microsecondsSinceEpoch / 1000000,
    'trackedDuration': state == 'tracking' ? .25 : 0.0,
    'didBlink': blink,
    'state': state,
    'openness': .9,
    'calibrationProgress': 1.0,
  });
}
