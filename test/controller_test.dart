import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:blink_monitor/src/data/history.dart';
import 'package:blink_monitor/src/monitor_controller.dart';
import 'fake_backend.dart';

void main() {
  late Directory directory;
  late FakeBackend backend;
  late MonitorController controller;
  late DateTime now;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('blink-controller-test');
    backend = FakeBackend();
    now = DateTime(2026, 10, 13, 10);
    controller = MonitorController(
      backend,
      HistoryStore(directory),
      now: () => now,
    );
    await controller.initialize();
  });
  tearDown(() async {
    await controller.shutdown();
    await directory.delete(recursive: true);
  });
  test(
    'start, receive, stop, relaunch retains actual session measurements',
    () async {
      await controller.start();
      for (var i = 1; i <= 40; i++) {
        now = now.add(const Duration(milliseconds: 250));
        backend.frame(now, blink: i % 20 == 0);
      }
      expect(controller.liveRate, 12);
      expect(controller.current!.blinks, 2);
      await controller.stop();
      expect(controller.running, false);
      final document = await HistoryStore(directory).load();
      expect(document.sessions.single.blinks, 2);
      expect(document.sessions.single.trackedSeconds, 10);
    },
  );
  test(
    'pause during permission request ignores late results and frames',
    () async {
      backend.startGate = Completer<void>();
      final starting = controller.start();
      final id = backend.runId;
      await controller.stop();
      backend.startGate!.complete();
      await starting;
      backend.frame(now, blink: true, id: id);
      expect(controller.running, false);
      expect(controller.state, MonitorState.paused);
      expect(controller.sessions, isEmpty);
    },
  );
  test('old run cannot contaminate a new session', () async {
    await controller.start();
    final oldId = backend.runId;
    await controller.stop();
    await controller.start();
    now = now.add(const Duration(seconds: 1));
    backend.frame(now, blink: true, id: oldId);
    expect(controller.current!.blinks, 0);
  });
  test('face loss makes live rate unavailable', () async {
    await controller.start();
    for (var i = 0; i < 24; i++) {
      now = now.add(const Duration(milliseconds: 250));
      backend.frame(now);
    }
    expect(controller.liveRate, 0);
    now = now.add(const Duration(milliseconds: 250));
    backend.frame(now, state: 'noFace');
    expect(controller.liveRate, isNull);
    expect(controller.current!.trackedSeconds, 6);
  });
  test(
    'processing rate uses delivered frames and resets after a gap',
    () async {
      await controller.start();
      for (var i = 0; i < 31; i++) {
        now = now.add(const Duration(milliseconds: 20));
        backend.frame(now);
      }
      expect(controller.processedFPS, closeTo(50, .1));
      now = now.add(const Duration(seconds: 1));
      backend.frame(now);
      expect(controller.processedFPS, isNull);
      await controller.stop();
      expect(controller.processedFPS, isNull);
    },
  );
  test(
    'permission errors leave camera stopped and show actionable state',
    () async {
      backend.startError = 'Camera permission denied';
      await controller.start();
      expect(controller.state, MonitorState.denied);
      expect(controller.running, false);
      expect(controller.detail, contains('permission denied'));
    },
  );
  test('clear history resets active and persisted counters', () async {
    await controller.start();
    now = now.add(const Duration(milliseconds: 250));
    backend.frame(now, blink: true);
    await controller.clearHistory();
    expect(controller.current!.blinks, 0);
    expect((await HistoryStore(directory).load()).sessions.single.blinks, 0);
  });
}
