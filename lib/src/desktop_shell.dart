import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'backend/blink_backend.dart';
import 'monitor_controller.dart';

class DesktopShell with TrayListener, WindowListener {
  DesktopShell(this.controller, this.directory);
  final MonitorController controller;
  final Directory directory;
  bool _quitting = false;
  bool _trayAvailable = false;
  String _lastStatus = '';
  Future<void> _updates = Future.value();

  Future<void> initialize() async {
    controller.onQuit = quit;
    controller.addListener(_changed);
    if (Platform.isLinux) {
      await windowManager.ensureInitialized();
      await windowManager.setMinimumSize(const Size(840, 650));
      await windowManager.setSize(const Size(1160, 830));
      await windowManager.setTitle('BlinkMonitor');
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      trayManager.addListener(this);
      try {
        final data = await rootBundle.load('assets/tray_icon.png');
        final icon = File(p.join(directory.path, 'tray_icon.png'));
        await icon.parent.create(recursive: true);
        await icon.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        await trayManager.setIcon(icon.path);
        _trayAvailable = true;
      } catch (_) {
        _trayAvailable = false;
      }
    }
    _changed();
  }

  void _changed() {
    final key =
        '${controller.menuTitle}:${controller.running}:${controller.title}';
    if (key == _lastStatus) return;
    _lastStatus = key;
    final title = controller.menuTitle;
    final status = controller.title;
    final running = controller.running;
    _updates = _updates
        .then((_) async {
          if (_quitting) return;
          if (Platform.isMacOS) {
            await MacOSBackend.channel.invokeMethod<void>('updateStatus', {
              'title': title,
              'status': status,
              'running': running,
            });
          } else if (_trayAvailable) {
            await trayManager.setToolTip('BlinkMonitor · $title · $status');
            await trayManager.setTitle(title);
            await trayManager.setContextMenu(
              Menu(
                items: [
                  MenuItem(
                    key: 'rate',
                    label: 'BlinkMonitor · $title',
                    disabled: true,
                  ),
                  MenuItem.separator(),
                  MenuItem(key: 'show', label: 'Open Dashboard'),
                  MenuItem(
                    key: 'toggle',
                    label: running ? 'Pause Monitoring' : 'Start Monitoring',
                  ),
                  MenuItem(key: 'settings', label: 'Settings'),
                  MenuItem.separator(),
                  MenuItem(key: 'quit', label: 'Quit BlinkMonitor'),
                ],
              ),
            );
          }
        })
        .catchError((Object _) {
          /* Dashboard remains usable without a tray host. */
        });
  }

  Future<void> show() async {
    if (Platform.isMacOS) {
      await MacOSBackend.channel.invokeMethod<void>('showDashboard');
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(show());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(show());
      case 'toggle':
        unawaited(controller.running ? controller.stop() : controller.start());
      case 'settings':
        controller.setPage(2);
        unawaited(show());
      case 'quit':
        unawaited(quit());
    }
  }

  @override
  void onWindowClose() {
    // Linux window close quits: some desktops accept a tray icon without actually
    // displaying it, so hiding here could leave an inaccessible camera process.
    unawaited(quit());
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    controller.removeListener(_changed);
    await controller.shutdown();
    if (Platform.isMacOS) {
      await MacOSBackend.channel.invokeMethod<void>('terminate');
    } else {
      if (_trayAvailable) await trayManager.destroy();
      await windowManager.destroy();
      exit(0);
    }
  }
}
