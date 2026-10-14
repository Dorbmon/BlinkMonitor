import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:blink_monitor/src/data/history.dart';

void main() {
  final start = DateTime.utc(2026, 10, 13, 10);
  test(
    'exposure splits at minute boundary and blink belongs to reopening minute',
    () {
      final session = MonitoringSession('session', start);
      session.record(start.add(const Duration(milliseconds: 60100)), .2, true);
      expect(session.minutes.length, 2);
      expect(session.minutes[0].trackedSeconds, closeTo(.1, .00001));
      expect(session.minutes[1].trackedSeconds, closeTo(.1, .00001));
      expect(session.minutes[0].blinks, 0);
      expect(session.minutes[1].blinks, 1);
    },
  );
  test('rate divides by tracked time, never wall-clock session length', () {
    final session = MonitoringSession('session', start);
    for (var i = 1; i <= 120; i++) {
      session.record(
        start.add(Duration(milliseconds: i * 250)),
        .25,
        i % 20 == 0,
      );
    }
    session.record(start.add(const Duration(minutes: 10)), 0, false);
    expect(session.trackedSeconds, 30);
    expect(session.rate, 12);
  });
  test('rolling rate warms up, clips partial exposure and expires', () {
    final rolling = RollingRate();
    expect(rolling.at(start), isNull);
    for (var i = 1; i <= 240; i++) {
      rolling.record(start.add(Duration(milliseconds: i * 250)), .25, i == 240);
    }
    expect(
      rolling.at(start.add(const Duration(milliseconds: 60125))),
      closeTo(60 / 59.875, .00001),
    );
    expect(rolling.at(start.add(const Duration(seconds: 121))), isNull);
  });
  test('zero blinks is a valid observed rate, missing time is not', () {
    final session = MonitoringSession('session', start);
    expect(session.rate, isNull);
    for (var i = 1; i <= 24; i++) {
      session.record(start.add(Duration(milliseconds: i * 250)), .25, false);
    }
    expect(session.rate, 0);
  });
  test('invalid frame exposure is discarded', () {
    final session = MonitoringSession('session', start);
    for (final value in [-1.0, double.nan, double.infinity, 10.0]) {
      session.record(start, value, true);
    }
    expect(session.blinks, 0);
    expect(session.trackedSeconds, 0);
  });
  test('overlapping callback intervals are counted only once', () {
    final session = MonitoringSession('jitter', start);
    final rolling = RollingRate();
    rolling.record(start, 0, false);
    for (var i = 1; i <= 1800; i++) {
      final at = start.add(Duration(microseconds: (i * 1000000 / 30).round()));
      session.record(at, .04, i % 60 == 0);
      rolling.record(at, .04, i % 60 == 0);
    }
    expect(session.trackedSeconds, closeTo(60, .001));
    expect(session.minutes.every((row) => row.trackedSeconds <= 60), true);
    expect(
      rolling.at(start.add(const Duration(minutes: 1))),
      closeTo(30, .001),
    );
    final copy = HistoryDocument.decode(
      HistoryDocument(sessions: [session]).encode(),
    );
    expect(copy.sessions.single.blinks, 30);
  });
  test(
    'legacy single-frame minute overflow is recovered without losing blinks',
    () {
      final row = MinuteRecord.fromJson({
        'start': start.toIso8601String(),
        'trackedSeconds': 60.052639,
        'blinks': 11,
      });
      expect(row.trackedSeconds, 60);
      expect(row.blinks, 11);
      expect(
        () => MinuteRecord.fromJson({
          'start': start.toIso8601String(),
          'trackedSeconds': 90,
          'blinks': 11,
        }),
        throwsFormatException,
      );
    },
  );
  test('archive round trip retains precise times and preferences', () {
    final session = MonitoringSession('session', start);
    for (var i = 1; i <= 40; i++) {
      session.record(
        start.add(Duration(milliseconds: i * 250)),
        .25,
        i % 20 == 0,
      );
    }
    final document = HistoryDocument(
      sessions: [session],
      cameraId: 'camera',
      sensitivity: .65,
    );
    final decoded = HistoryDocument.decode(document.encode());
    expect(decoded.cameraId, 'camera');
    expect(decoded.sensitivity, .65);
    expect(decoded.sessions.single.blinks, 2);
    expect(decoded.sessions.single.rate, 12);
    expect(exportCsv(decoded.sessions), contains(',2,10.000,12.00'));
  });
  test(
    'unreadable archive is preserved before replacing and writes serialize',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'blink-history-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = HistoryStore(directory);
      await store.file.writeAsString('broken');
      await expectLater(store.load(), throwsFormatException);
      final backups = await directory
          .list()
          .where((item) => item.path.contains('unreadable'))
          .toList();
      expect(backups.length, 1);
      expect(await File(backups.single.path).readAsString(), 'broken');
      final first = store.save(HistoryDocument(cameraId: 'first'));
      final second = store.save(HistoryDocument(cameraId: 'second'));
      await Future.wait([first, second]);
      expect((await store.load()).cameraId, 'second');
    },
  );
  test('unsupported version is rejected', () {
    expect(
      () => HistoryDocument.decode('{"version":2,"sessions":[]}'),
      throwsFormatException,
    );
  });
}
