import 'dart:convert';
import 'dart:io';
import 'dart:math';

class MinuteRecord {
  MinuteRecord(this.start, {this.blinks = 0, this.trackedSeconds = 0});
  final DateTime start;
  int blinks;
  double trackedSeconds;
  double? get rate => trackedSeconds >= 5 ? blinks * 60 / trackedSeconds : null;

  Map<String, dynamic> toJson() => {
    'start': start.toUtc().toIso8601String(),
    'blinks': blinks,
    'trackedSeconds': trackedSeconds,
  };

  factory MinuteRecord.fromJson(Map<String, dynamic> json) {
    final seconds = (json['trackedSeconds'] as num).toDouble();
    final blinks = json['blinks'] as int;
    // Older builds used capture durations with callback timestamps, allowing up
    // to one frame of overlap at a minute boundary. Recover those archives.
    if (!seconds.isFinite || seconds < 0 || seconds > 60.250001 || blinks < 0) {
      throw const FormatException('Invalid history counters');
    }
    return MinuteRecord(
      DateTime.parse(json['start'] as String).toLocal(),
      blinks: blinks,
      trackedSeconds: min(60, seconds),
    );
  }
}

class MonitoringSession {
  MonitoringSession(
    this.id,
    this.startedAt, {
    DateTime? endedAt,
    List<MinuteRecord>? minutes,
  }) : endedAt = endedAt ?? startedAt,
       minutes = minutes ?? [];
  final String id;
  final DateTime startedAt;
  DateTime endedAt;
  final List<MinuteRecord> minutes;
  int get blinks => minutes.fold(0, (sum, row) => sum + row.blinks);
  double get trackedSeconds =>
      minutes.fold(0, (sum, row) => sum + row.trackedSeconds);
  double? get rate => trackedSeconds >= 5 ? blinks * 60 / trackedSeconds : null;

  void record(DateTime at, double seconds, bool blink) {
    if (!seconds.isFinite || seconds < 0 || seconds > .25) return;
    if (!at.isAfter(endedAt)) return;
    var cursor = at.subtract(
      Duration(microseconds: (seconds * 1000000).round()),
    );
    // Capture intervals can overlap in wall time when callbacks are delayed.
    // Never count an already observed interval twice.
    if (cursor.isBefore(endedAt)) cursor = endedAt;
    endedAt = at;
    while (cursor.isBefore(at)) {
      final start = minuteStart(cursor);
      final boundary = start.add(const Duration(minutes: 1));
      final end = boundary.isBefore(at) ? boundary : at;
      final minute = _minute(start);
      minute.trackedSeconds = min(
        60,
        minute.trackedSeconds + end.difference(cursor).inMicroseconds / 1000000,
      );
      cursor = end;
    }
    if (blink) _minute(minuteStart(at)).blinks++;
  }

  MinuteRecord _minute(DateTime start) {
    if (minutes.isNotEmpty && minutes.last.start == start) return minutes.last;
    for (final minute in minutes) {
      if (minute.start == start) return minute;
    }
    final row = MinuteRecord(start);
    minutes.add(row);
    return row;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'minutes': minutes.map((row) => row.toJson()).toList(),
  };

  factory MonitoringSession.fromJson(Map<String, dynamic> json) {
    final session = MonitoringSession(
      json['id'] as String,
      DateTime.parse(json['startedAt'] as String).toLocal(),
      endedAt: DateTime.parse(json['endedAt'] as String).toLocal(),
      minutes: (json['minutes'] as List)
          .map(
            (row) =>
                MinuteRecord.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList(),
    );
    if (session.endedAt.isBefore(session.startedAt)) {
      throw const FormatException('Invalid session dates');
    }
    return session;
  }
}

DateTime minuteStart(DateTime date) => DateTime.fromMillisecondsSinceEpoch(
  date.millisecondsSinceEpoch ~/ 60000 * 60000,
  isUtc: date.isUtc,
);

class RollingRate {
  final List<({DateTime end, double seconds})> _exposures = [];
  final List<DateTime> _blinks = [];
  DateTime? _lastEnd;

  void record(DateTime at, double seconds, bool blink) {
    if (_lastEnd != null && !at.isAfter(_lastEnd!)) return;
    if (seconds > 0 && seconds <= .25 && seconds.isFinite) {
      if (_lastEnd != null) {
        seconds = min(
          seconds,
          at.difference(_lastEnd!).inMicroseconds / 1000000,
        );
      }
      _exposures.add((end: at, seconds: seconds));
    }
    _lastEnd = at;
    if (blink) _blinks.add(at);
    _prune(at);
  }

  double? at(DateTime now) {
    _prune(now);
    final cutoff = now.subtract(const Duration(seconds: 60));
    final seconds = _exposures.fold<double>(
      0,
      (sum, row) =>
          sum +
          max(
            0,
            min(
              row.seconds,
              row.end.difference(cutoff).inMicroseconds / 1000000,
            ),
          ),
    );
    return seconds >= 5 ? _blinks.length * 60 / seconds : null;
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(const Duration(seconds: 60));
    _exposures.removeWhere((row) => !row.end.isAfter(cutoff));
    _blinks.removeWhere((date) => !date.isAfter(cutoff));
  }
}

class HistoryDocument {
  HistoryDocument({
    List<MonitoringSession>? sessions,
    this.cameraId = '',
    this.sensitivity = .58,
  }) : sessions = sessions ?? [];
  final List<MonitoringSession> sessions;
  String cameraId;
  double sensitivity;

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'cameraId': cameraId,
    'sensitivity': sensitivity,
    'sessions': sessions.map((session) => session.toJson()).toList(),
  });

  factory HistoryDocument.decode(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json['version'] != 1) {
      throw const FormatException('Unsupported history version');
    }
    final sensitivity = (json['sensitivity'] as num? ?? .58).toDouble();
    if (!sensitivity.isFinite || sensitivity < .4 || sensitivity > .8) {
      throw const FormatException('Invalid sensitivity');
    }
    return HistoryDocument(
      cameraId: json['cameraId'] as String? ?? '',
      sensitivity: sensitivity,
      sessions: (json['sessions'] as List)
          .map(
            (item) => MonitoringSession.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
    );
  }
}

/// Writes are serialized and replaced atomically. A failed read is preserved before
/// a new archive is allowed to overwrite it.
class HistoryStore {
  HistoryStore(this.directory);
  final Directory directory;
  Future<void> _tail = Future.value();
  bool _writable = true;
  File get file => File('${directory.path}/history.json');

  Future<HistoryDocument> load() async {
    if (!await file.exists()) return HistoryDocument();
    try {
      return HistoryDocument.decode(await file.readAsString());
    } catch (error) {
      try {
        await file.copy(
          '${directory.path}/history-unreadable-${DateTime.now().microsecondsSinceEpoch}.json',
        );
      } catch (_) {
        _writable = false;
        throw FileSystemException(
          'Cannot read or back up history; saving is disabled to preserve the original.',
          file.path,
        );
      }
      throw FormatException(
        'History could not be read. A backup was preserved in ${directory.path}. $error',
      );
    }
  }

  Future<void> save(HistoryDocument document) {
    // Capture values before enqueueing; live sessions continue to mutate.
    final text = document.encode();
    final next = _tail.then((_) async {
      if (!_writable) {
        throw const FileSystemException(
          'History is read-only after a backup failure.',
        );
      }
      await directory.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
}

String exportCsv(Iterable<MonitoringSession> sessions) {
  final lines = [
    'session_id,session_start,minute_start,blinks,tracked_seconds,blinks_per_minute',
  ];
  String quote(String value) => '"${value.replaceAll('"', '""')}"';
  for (final session in sessions) {
    for (final row in session.minutes) {
      lines.add(
        [
          quote(session.id),
          session.startedAt.toUtc().toIso8601String(),
          row.start.toUtc().toIso8601String(),
          row.blinks,
          row.trackedSeconds.toStringAsFixed(3),
          row.rate?.toStringAsFixed(2) ?? '',
        ].join(','),
      );
    }
  }
  return '${lines.join('\n')}\n';
}
