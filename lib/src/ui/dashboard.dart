import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../backend/blink_backend.dart';
import '../data/history.dart';
import '../monitor_controller.dart';

const ink = Color(0xFF20342C);
const green = Color(0xFF31795D);
const muted = Color(0xFF78847D);
const canvas = Color(0xFFF6F8F5);
const line = Color(0xFFE6EBE5);

class BlinkMonitorApp extends StatelessWidget {
  const BlinkMonitorApp({super.key, required this.controller});
  final MonitorController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BlinkMonitor',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        primary: green,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: canvas,
      fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink, fontSize: 13),
        bodySmall: TextStyle(color: muted, fontSize: 11),
      ),
      dividerColor: line,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      sliderTheme: const SliderThemeData(trackHeight: 4),
    ),
    home: Dashboard(controller: controller),
  );
}

class Dashboard extends StatelessWidget {
  const Dashboard({super.key, required this.controller});
  final MonitorController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 1000;
          return Row(
            children: [
              _Sidebar(controller: controller, compact: compact),
              const VerticalDivider(width: 1, color: line),
              Expanded(
                child: Column(
                  children: [
                    _Header(controller: controller),
                    if (controller.notice != null) _notice(context),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(compact ? 22 : 30),
                        child: switch (controller.page) {
                          1 => _history(context),
                          2 => _settings(context),
                          _ => _overview(context),
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _notice(BuildContext context) => Container(
    color: const Color(0xFFFFF2DD),
    padding: const EdgeInsets.only(left: 24, right: 8, top: 4, bottom: 4),
    child: Row(
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: SelectableText(
            controller.notice!,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        IconButton(
          tooltip: 'Dismiss message',
          onPressed: controller.dismissNotice,
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    ),
  );

  Widget _heading(String title, String subtitle, Widget trailing) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 20,
    runSpacing: 16,
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 27,
              height: 1.25,
              fontWeight: FontWeight.w600,
              letterSpacing: -.8,
              color: ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: const TextStyle(color: muted, fontSize: 12)),
        ],
      ),
      trailing,
    ],
  );

  Widget _monitorButton() => FilledButton.icon(
    onPressed: controller.ready
        ? () => controller.running ? controller.stop() : controller.start()
        : null,
    icon: Icon(
      controller.running ? Icons.pause_rounded : Icons.play_arrow_rounded,
      size: 17,
    ),
    label: Text(
      controller.running ? 'Pause monitoring' : 'Start monitoring',
      style: const TextStyle(fontSize: 12),
    ),
  );

  Widget _overview(BuildContext context) {
    final now = DateTime.now();
    final today = controller.sessions
        .expand((s) => s.minutes)
        .where((m) => sameDay(m.start, now))
        .toList();
    final total = today.fold<int>(0, (sum, m) => sum + m.blinks);
    final tracked = today.fold<double>(0, (sum, m) => sum + m.trackedSeconds);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          'A closer look at your blinks.',
          'Small moments. A clearer picture of your screen time.',
          _monitorButton(),
        ),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, c) {
            final live = _LiveCard(controller: controller);
            final tracking = _TrackingCard(controller: controller);
            return c.maxWidth >= 670
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: live),
                      const SizedBox(width: 16),
                      SizedBox(width: 252, child: tracking),
                    ],
                  )
                : Column(
                    children: [live, const SizedBox(height: 16), tracking],
                  );
          },
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, c) {
            final cards = [
              _Metric(
                title: 'BLINKS TODAY',
                value: '$total',
                unit: 'blinks',
                icon: Icons.visibility_outlined,
                caption: 'Every detected blink',
              ),
              _Metric(
                title: 'TODAY’S AVERAGE',
                value: tracked >= 5
                    ? (total * 60 / tracked).toStringAsFixed(1)
                    : '—',
                unit: '/ min',
                icon: Icons.show_chart,
                caption: 'Per minute of tracked time',
              ),
              _Metric(
                title: 'TRACKED TODAY',
                value: duration(tracked),
                unit: '',
                icon: Icons.timer_outlined,
                caption: 'Only while your face is visible',
              ),
            ];
            return Wrap(
              spacing: 14,
              runSpacing: 14,
              children: cards
                  .map(
                    (card) => SizedBox(
                      width: c.maxWidth >= 570
                          ? (c.maxWidth - 28) / 3
                          : c.maxWidth,
                      child: card,
                    ),
                  )
                  .toList(),
            );
          },
        ),
        const SizedBox(height: 22),
        TrendCard(sessions: controller.sessions),
        const SizedBox(height: 19),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 15, color: green),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Blink rates vary with focus, lighting, and camera position. Use your own trends as a reference.',
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _history(BuildContext context) {
    final sessions = controller.sessions.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          'The bigger picture.',
          'Your last 90 days, saved only on this device.',
          OutlinedButton.icon(
            onPressed: sessions.isEmpty ? null : () => _export(context),
            icon: const Icon(Icons.file_upload_outlined, size: 17),
            label: const Text('Export CSV'),
          ),
        ),
        const SizedBox(height: 28),
        TrendCard(sessions: controller.sessions, initialPeriod: 7),
        const SizedBox(height: 22),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text(
                    'Monitoring sessions',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Text(
                    '${sessions.length} sessions',
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 38),
                  child: Center(
                    child: Text(
                      'No sessions yet. Start monitoring from Overview.',
                      style: TextStyle(color: muted),
                    ),
                  ),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingTextStyle: const TextStyle(
                      fontSize: 10,
                      color: muted,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                    ),
                    dataTextStyle: const TextStyle(fontSize: 12, color: ink),
                    horizontalMargin: 0,
                    columnSpacing: 35,
                    columns: const [
                      DataColumn(label: Text('STARTED')),
                      DataColumn(label: Text('TRACKED'), numeric: true),
                      DataColumn(label: Text('BLINKS'), numeric: true),
                      DataColumn(label: Text('AVG / MIN'), numeric: true),
                    ],
                    rows: sessions
                        .map(
                          (session) => DataRow(
                            cells: [
                              DataCell(
                                Row(
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      size: 6,
                                      color:
                                          session.id == controller.current?.id
                                          ? green
                                          : line,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${dateLabel(session.startedAt)} · ${timeLabel(session.startedAt)}',
                                    ),
                                    if (session.id == controller.current?.id)
                                      const Padding(
                                        padding: EdgeInsets.only(left: 10),
                                        child: Text(
                                          'LIVE',
                                          style: TextStyle(
                                            color: green,
                                            fontSize: 9,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              DataCell(Text(duration(session.trackedSeconds))),
                              DataCell(Text('${session.blinks}')),
                              DataCell(
                                Text(session.rate?.toStringAsFixed(1) ?? '—'),
                              ),
                            ],
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settings(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading(
        'Make yourself comfortable.',
        'A few simple controls for more consistent tracking.',
        const SizedBox.shrink(),
      ),
      const SizedBox(height: 28),
      _settingsCard('Camera', Icons.videocam_outlined, [
        DropdownButtonFormField<String>(
          initialValue: controller.history.cameraId,
          decoration: const InputDecoration(
            labelText: 'Camera',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('System default')),
            ...controller.cameras.map(
              (camera) => DropdownMenuItem(
                value: camera.id,
                child: Text(camera.name, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (controller.history.cameraId.isNotEmpty &&
                !controller.cameras.any(
                  (camera) => camera.id == controller.history.cameraId,
                ))
              DropdownMenuItem(
                value: controller.history.cameraId,
                child: const Text('Selected camera (disconnected)'),
              ),
          ],
          isExpanded: true,
          onChanged: (value) {
            if (value != null) controller.selectCamera(value);
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
              child: Text(
                'The camera runs only while monitoring is active.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: controller.refreshCameras,
              child: const Text('Refresh'),
            ),
          ],
        ),
        if (Platform.isLinux)
          const Text(
            'Linux camera setup: run scripts/setup-linux-backend.sh once. This installs the local model and runtime; tracking then works offline.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.6),
          ),
      ]),
      const SizedBox(height: 18),
      _settingsCard('Blink detection', Icons.visibility_outlined, [
        Row(
          children: [
            const Text('Sensitivity'),
            const Spacer(),
            Text(
              '${(controller.history.sensitivity * 100).round()}%',
              style: const TextStyle(color: muted),
            ),
          ],
        ),
        Slider(
          value: controller.history.sensitivity,
          min: .4,
          max: .8,
          divisions: 40,
          label: '${(controller.history.sensitivity * 100).round()}%',
          onChanged: controller.setSensitivity,
          onChangeEnd: (_) => controller.applySensitivity(),
        ),
        const Row(
          children: [
            Text(
              'Deeper closures',
              style: TextStyle(color: muted, fontSize: 11),
            ),
            Spacer(),
            Text(
              'Lighter closures',
              style: TextStyle(color: muted, fontSize: 11),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Divider(),
        ),
        const Text(
          'Keep your eyes naturally open during calibration. If blinks are missed, increase sensitivity slightly. If extra blinks are counted, lower it. Recalibrate after changing your position or lighting.',
          style: TextStyle(color: muted, fontSize: 12, height: 1.65),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: controller.running ? controller.recalibrate : null,
              child: const Text('Recalibrate'),
            ),
            TextButton(
              onPressed: () {
                controller.setSensitivity(.58);
                controller.applySensitivity();
              },
              child: const Text('Reset sensitivity'),
            ),
          ],
        ),
      ]),
      const SizedBox(height: 18),
      _settingsCard('Your data', Icons.shield_outlined, [
        const Text(
          'Only blink counts, timestamps, and tracked durations are stored locally for 90 days. Camera frames are processed in memory and discarded. No accounts, analytics, or uploads.',
          style: TextStyle(color: muted, fontSize: 12, height: 1.65),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(
              onPressed: controller.sessions.isEmpty
                  ? null
                  : () => _export(context),
              child: const Text('Export CSV'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => _clear(context),
              child: const Text(
                'Clear history…',
                style: TextStyle(color: Color(0xFFAC5B4C)),
              ),
            ),
          ],
        ),
      ]),
      const SizedBox(height: 18),
      const Text(
        'BlinkMonitor provides approximate personal tracking, not a medical measurement. Glasses, glare, head movement, and low light can affect detection.',
        style: TextStyle(color: muted, fontSize: 11, height: 1.6),
      ),
    ],
  );

  Widget _settingsCard(String title, IconData icon, List<Widget> content) =>
      _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 19, color: green),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            ...content,
          ],
        ),
      );

  Future<void> _export(BuildContext context) async {
    try {
      final location = await getSaveLocation(
        suggestedName:
            'BlinkMonitor-${DateTime.now().toIso8601String().substring(0, 10)}.csv',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'CSV', extensions: ['csv']),
        ],
      );
      if (location == null) return;
      await File(
        location.path,
      ).writeAsString(exportCsv(controller.sessions), flush: true);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('History exported.')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $error')));
      }
    }
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all blink history?'),
        content: const Text(
          'This deletes saved history and resets the current session. Export a CSV first to keep a copy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.clearHistory();
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller, required this.compact});
  final MonitorController controller;
  final bool compact;
  @override
  Widget build(BuildContext context) => Container(
    width: compact ? 78 : 214,
    color: Colors.white,
    padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF3EC),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.visibility_outlined,
                color: green,
                size: 26,
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 9),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BlinkMonitor',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        letterSpacing: -.4,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'A mindful little metric.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 9),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 42),
        if (!compact)
          const Padding(
            padding: EdgeInsets.only(left: 12, bottom: 14),
            child: Text(
              'YOUR WORKSPACE',
              style: TextStyle(
                color: muted,
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ),
        for (final (index, title, icon) in [
          (0, 'Overview', Icons.grid_view_rounded),
          (1, 'History', Icons.history_rounded),
          (2, 'Settings', Icons.tune_rounded),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Tooltip(
              message: compact ? title : '',
              child: Material(
                color: index == controller.page
                    ? const Color(0xFFEAF3EC)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => controller.setPage(index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          icon,
                          size: 18,
                          color: index == controller.page ? green : muted,
                        ),
                        if (!compact) ...[
                          const SizedBox(width: 12),
                          Text(
                            title,
                            style: TextStyle(
                              color: index == controller.page ? green : muted,
                              fontSize: 13,
                              fontWeight: index == controller.page
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          const Spacer(),
                          if (index == controller.page)
                            const Icon(Icons.circle, size: 5, color: green),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        if (!compact) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F7F1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified_user_outlined, color: green, size: 23),
                SizedBox(height: 13),
                Text(
                  'Just between you\nand your computer.',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'On-device processing.\nNo video saved. No uploads.',
                  style: TextStyle(fontSize: 10, color: muted, height: 1.7),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            'BLINKMONITOR  /  1.0',
            style: TextStyle(fontSize: 8, letterSpacing: 1.5, color: muted),
          ),
        ],
        const SizedBox(height: 20),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});
  final MonitorController controller;
  @override
  Widget build(BuildContext context) => Container(
    height: 58,
    padding: const EdgeInsets.symmetric(horizontal: 28),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        const Text('Workspace', style: TextStyle(fontSize: 11, color: muted)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('/', style: TextStyle(color: line)),
        ),
        Text(
          ['Overview', 'History', 'Settings'][controller.page],
          style: const TextStyle(fontSize: 11, color: ink),
        ),
        const Spacer(),
        Icon(
          Icons.circle,
          size: 6,
          color: controller.state == MonitorState.tracking ? green : muted,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            controller.title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ),
      ],
    ),
  );
}

class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.controller});
  final MonitorController controller;
  @override
  Widget build(BuildContext context) => _Card(
    color: const Color(0xFFEEF5EE),
    border: const Color(0xFFD8E6D8),
    child: SizedBox(
      height: 202,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'LIVE BLINK RATE',
                style: TextStyle(
                  color: green,
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFDDEBDF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.circle, size: 5, color: green),
                    const SizedBox(width: 6),
                    Text(
                      controller.state == MonitorState.tracking
                          ? 'LIVE'
                          : 'STANDBY',
                      style: const TextStyle(
                        fontSize: 8,
                        letterSpacing: 1.1,
                        color: green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  controller.liveRate?.round().toString() ?? '—',
                  style: const TextStyle(
                    fontSize: 82,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -4,
                    height: 1.15,
                    color: ink,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 14),
                const Flexible(
                  child: Text(
                    'blinks / min',
                    style: TextStyle(fontSize: 14, color: muted),
                  ),
                ),
              ],
            ),
          ),
          Text(
            controller.statusDetail,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, height: 1.55, color: muted),
          ),
          if (controller.state == MonitorState.denied && Platform.isMacOS)
            TextButton(
              onPressed: () =>
                  MacOSBackend.channel.invokeMethod<void>('openCameraSettings'),
              child: const Text(
                'Open camera settings',
                style: TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    ),
  );
}

class _TrackingCard extends StatelessWidget {
  const _TrackingCard({required this.controller});
  final MonitorController controller;
  @override
  Widget build(BuildContext context) => _Card(
    child: SizedBox(
      height: 202,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'TRACKING STATUS',
                style: TextStyle(
                  color: muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Icon(
                controller.running
                    ? Icons.videocam_outlined
                    : Icons.videocam_off_outlined,
                size: 16,
                color: muted,
              ),
            ],
          ),
          const SizedBox(height: 23),
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  color: Color(0xFFF0F5ED),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  controller.state == MonitorState.tracking
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: green,
                  size: 27,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.state == MonitorState.tracking
                          ? 'Eyes in view'
                          : controller.running
                          ? 'Finding your eyes'
                          : 'Camera is off',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      controller.running
                          ? controller.processedFPS == null
                                ? 'Processed on this device'
                                : '${controller.processedFPS!.round()} fps · on-device'
                          : 'Start to begin tracking',
                      style: const TextStyle(color: muted, fontSize: 9),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Text(
                controller.state == MonitorState.calibrating
                    ? 'Calibration'
                    : 'Eye openness',
                style: const TextStyle(color: muted, fontSize: 10),
              ),
              const Spacer(),
              Text(
                controller.running
                    ? '${((controller.state == MonitorState.calibrating ? controller.calibration : controller.openness) * 100).round()}%'
                    : '—',
                style: const TextStyle(color: muted, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 9),
          LinearProgressIndicator(
            value: controller.running
                ? controller.state == MonitorState.calibrating
                      ? controller.calibration
                      : controller.openness
                : 0,
            minHeight: 4,
            backgroundColor: canvas,
            borderRadius: BorderRadius.circular(3),
          ),
          const Spacer(),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'This session',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${controller.current?.blinks ?? 0} blinks',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.title,
    required this.value,
    required this.unit,
    required this.icon,
    required this.caption,
  });
  final String title, value, unit, caption;
  final IconData icon;
  @override
  Widget build(BuildContext context) => _Card(
    padding: 19,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .8,
                ),
              ),
            ),
            Icon(icon, size: 16, color: green),
          ],
        ),
        const SizedBox(height: 15),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 6,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 29,
                height: 1.2,
                letterSpacing: -.7,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                unit,
                style: const TextStyle(fontSize: 10, color: muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 11),
        Text(
          caption,
          style: const TextStyle(fontSize: 10, color: muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({
    required this.child,
    this.color = Colors.white,
    this.border = line,
    this.padding = 23,
  });
  final Widget child;
  final Color color, border;
  final double padding;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: color,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );
}

class TrendCard extends StatefulWidget {
  const TrendCard({super.key, required this.sessions, this.initialPeriod = 1});
  final List<MonitoringSession> sessions;
  final int initialPeriod;
  @override
  State<TrendCard> createState() => _TrendCardState();
}

class _TrendCardState extends State<TrendCard> {
  late int days = widget.initialPeriod;
  int? hover;

  List<MinuteRecord> _bins() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day - days + 1);
    final end = DateTime(now.year, now.month, now.day + 1);
    final bins = days == 1
        ? List.generate(
            end.difference(start).inMinutes ~/ 30,
            (i) => MinuteRecord(start.add(Duration(minutes: i * 30))),
          )
        : List.generate(
            days,
            (i) =>
                MinuteRecord(DateTime(start.year, start.month, start.day + i)),
          );
    for (final row in widget.sessions.expand((session) => session.minutes)) {
      if (row.start.isBefore(start) || !row.start.isBefore(end)) continue;
      final i = days == 1
          ? row.start.difference(start).inMinutes ~/ 30
          : bins.indexWhere((bin) => sameDay(bin.start, row.start));
      if (i >= 0 && i < bins.length) {
        bins[i].blinks += row.blinks;
        bins[i].trackedSeconds += row.trackedSeconds;
      }
    }
    return bins;
  }

  @override
  Widget build(BuildContext context) {
    final bins = _bins();
    final hasData = bins.any((bin) => bin.rate != null);
    final maxRate = max(
      25.0,
      bins.fold<double>(0, (v, row) => max(v, row.rate ?? 0)) * 1.2,
    );
    final selected = hover != null && hover! < bins.length
        ? bins[hover!]
        : null;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Your blink rhythm',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Average blinks per tracked minute · ${days == 1 ? '30-minute' : 'daily'} intervals',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [
                  ButtonSegment(value: 1, label: Text('Today')),
                  ButtonSegment(value: 7, label: Text('7 days')),
                  ButtonSegment(value: 30, label: Text('30 days')),
                ],
                selected: {days},
                onSelectionChanged: (value) => setState(() {
                  days = value.first;
                  hover = null;
                }),
              ),
            ],
          ),
          const SizedBox(height: 22),
          if (!hasData)
            Container(
              height: 168,
              decoration: BoxDecoration(
                color: canvas,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bar_chart_rounded, color: green, size: 31),
                  SizedBox(height: 12),
                  Text(
                    'Your rhythm starts here',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  SizedBox(height: 7),
                  Text(
                    'Monitor for a few seconds to see your first data points.',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ],
              ),
            )
          else
            Column(
              children: [
                SizedBox(
                  height: 16,
                  child: Text(
                    selected == null
                        ? 'Hover over a bar for details'
                        : '${days == 1 ? timeLabel(selected.start) : dateLabel(selected.start)}  ·  ${selected.rate?.toStringAsFixed(1) ?? '—'} blinks / min  ·  ${duration(selected.trackedSeconds)} tracked',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 148,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children:
                              [
                                    Text('${maxRate.round()}'),
                                    Text('${(maxRate / 2).round()}'),
                                    const Text('0'),
                                  ]
                                  .map(
                                    (w) => DefaultTextStyle(
                                      style: const TextStyle(
                                        fontSize: 9,
                                        color: muted,
                                      ),
                                      child: w,
                                    ),
                                  )
                                  .toList(),
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) => MouseRegion(
                            onExit: (_) => setState(() => hover = null),
                            onHover: (event) => setState(
                              () => hover =
                                  (event.localPosition.dx /
                                          constraints.maxWidth *
                                          bins.length)
                                      .floor()
                                      .clamp(0, bins.length - 1),
                            ),
                            child: CustomPaint(
                              size: Size(constraints.maxWidth, 148),
                              painter: _BarsPainter(bins, maxRate, hover),
                              child: Semantics(
                                label:
                                    'Blink frequency chart. ${bins.where((b) => b.rate != null).map((b) => '${dateLabel(b.start)} ${timeLabel(b.start)}: ${b.rate!.toStringAsFixed(1)} blinks per minute').join('; ')}',
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 30),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (final i in [
                        0,
                        bins.length ~/ 4,
                        bins.length ~/ 2,
                        bins.length * 3 ~/ 4,
                        bins.length - 1,
                      ])
                        Text(
                          days == 1
                              ? timeLabel(bins[i].start)
                              : dateLabel(bins[i].start),
                          style: const TextStyle(fontSize: 9, color: muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.bins, this.maxRate, this.hover);
  final List<MinuteRecord> bins;
  final double maxRate;
  final int? hover;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (final y in [0.0, size.height / 2, size.height]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final step = size.width / bins.length;
    for (var i = 0; i < bins.length; i++) {
      final rate = bins[i].rate;
      if (rate == null) continue;
      final height = max(2.0, rate / maxRate * size.height);
      final rect = Rect.fromLTWH(
        i * step + step * .18,
        size.height - height,
        step * .64,
        height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..color = i == hover ? ink : green.withValues(alpha: .8),
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) => true;
}

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
String duration(double seconds) {
  final n = seconds.floor();
  if (n < 60) return '${n}s';
  if (n < 3600) return '${n ~/ 60}m ${n % 60}s';
  return '${n ~/ 3600}h ${n % 3600 ~/ 60}m';
}

String timeLabel(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
String dateLabel(DateTime date) =>
    '${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]} ${date.day}';
