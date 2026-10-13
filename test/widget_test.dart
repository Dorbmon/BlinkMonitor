import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blink_monitor/src/data/history.dart';
import 'package:blink_monitor/src/monitor_controller.dart';
import 'package:blink_monitor/src/ui/dashboard.dart';
import 'fake_backend.dart';

class MemoryStore extends HistoryStore {
  MemoryStore() : super(Directory('/unused'));
  HistoryDocument document = HistoryDocument();
  @override
  Future<HistoryDocument> load() async => document;
  @override
  Future<void> save(HistoryDocument value) async {
    document = HistoryDocument.decode(value.encode());
  }
}

void main() {
  testWidgets('dashboard navigation, start, pause and responsive layout', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = MonitorController(backend, MemoryStore());
    await controller.initialize();
    tester.view.physicalSize = const Size(1160, 830);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await controller.shutdown();
    });
    await tester.pumpWidget(BlinkMonitorApp(controller: controller));
    expect(find.text('A closer look at your blinks.'), findsOneWidget);
    expect(find.text('Your rhythm starts here'), findsOneWidget);
    await tester.tap(find.text('Start monitoring'));
    await tester.pumpAndSettle();
    expect(backend.starts, 1);
    expect(find.text('Calibrating your eyes'), findsOneWidget);
    await tester.tap(find.text('Pause monitoring'));
    await tester.pumpAndSettle();
    expect(controller.running, false);
    await tester.tap(find.text('History').first);
    await tester.pumpAndSettle();
    expect(find.text('The bigger picture.'), findsOneWidget);
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Make yourself comfortable.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(840, 650);
    controller.setPage(0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(controller.shutdown);
  });

  testWidgets('populated dashboard and history render actual widgets', (
    tester,
  ) async {
    final backend = FakeBackend();
    var now = DateTime.now();
    final store = MemoryStore();
    final start = DateTime(now.year, now.month, now.day, 8);
    for (var block = 0; block < 6; block++) {
      final session = MonitoringSession(
        'fixture-$block',
        start.add(Duration(hours: block)),
      );
      for (var minute = 0; minute < 45; minute++) {
        final date = session.startedAt.add(Duration(minutes: minute));
        if (date.isAfter(now)) break;
        session.minutes.add(
          MinuteRecord(
            date,
            blinks: 12 + (minute + block) % 10,
            trackedSeconds: 60,
          ),
        );
        session.endedAt = date.add(const Duration(minutes: 1));
      }
      store.document.sessions.add(session);
    }
    final controller = MonitorController(backend, store, now: () => now);
    await controller.initialize();
    await controller.start();
    for (var i = 0; i < 240; i++) {
      now = now.add(const Duration(milliseconds: 250));
      backend.frame(now, blink: i % 15 == 0);
    }
    tester.view.physicalSize = const Size(1160, 830);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await controller.shutdown();
    });
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: BlinkMonitorApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('16'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('GENERATE_PREVIEW')) {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/previews/dashboard.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    controller.setPage(1);
    await tester.pumpAndSettle();
    expect(find.text('Monitoring sessions'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(controller.shutdown);
  });
}
