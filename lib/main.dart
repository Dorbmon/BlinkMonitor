import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'src/backend/blink_backend.dart';
import 'src/data/history.dart';
import 'src/desktop_shell.dart';
import 'src/monitor_controller.dart';
import 'src/ui/dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS && !Platform.isLinux) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('BlinkMonitor supports macOS and Linux.')),
        ),
      ),
    );
    return;
  }
  final String support;
  if (Platform.isMacOS) {
    support = (await MacOSBackend.channel.invokeMethod<String>(
      'storageDirectory',
    ))!;
  } else {
    final dataHome =
        Platform.environment['XDG_DATA_HOME'] ??
        p.join(Platform.environment['HOME']!, '.local', 'share');
    support = p.join(dataHome, 'com.dorbmon.BlinkMonitor');
  }
  final directory = Directory(p.join(support, 'BlinkMonitor'));
  final backend = Platform.isMacOS
      ? MacOSBackend()
      : LinuxBackend(Directory(p.join(directory.path, 'runtime')));
  final controller = MonitorController(backend, HistoryStore(directory));
  await controller.initialize();
  final desktop = DesktopShell(controller, directory);
  await desktop.initialize();
  runApp(BlinkMonitorApp(controller: controller));
}
