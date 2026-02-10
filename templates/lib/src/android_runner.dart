import 'package:flutter/services.dart';

import 'config.dart';

class AndroidAppInfo {
  AndroidAppInfo({required this.packageName, required this.label, this.iconPng});

  final String packageName;
  final String label;
  final Uint8List? iconPng;
}

class AndroidRunner {
  static const MethodChannel _channel = MethodChannel('pingtunnel');

  Future<bool> prepareVpn() async {
    final result = await _channel.invokeMethod<bool>('prepareVpn');
    return result ?? false;
  }

  Future<void> startProxy(TunnelConfig config) async {
    await _channel.invokeMethod('startProxy', config.toMap());
  }

  Future<void> startVpn(TunnelConfig config) async {
    await _channel.invokeMethod('startVpn', config.toMap());
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  Future<bool> isRunning() async {
    final result = await _channel.invokeMethod<bool>('isRunning');
    return result ?? false;
  }

  Future<List<AndroidAppInfo>> listLaunchableApps() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listLaunchableApps');
    if (raw == null) {
      return <AndroidAppInfo>[];
    }

    final apps = <AndroidAppInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final packageName = item['packageName']?.toString() ?? '';
      final label = item['label']?.toString() ?? packageName;
      final rawIcon = item['iconPng'];
      Uint8List? iconPng;
      if (rawIcon is Uint8List) {
        iconPng = rawIcon;
      } else if (rawIcon is List<int>) {
        iconPng = Uint8List.fromList(rawIcon);
      }
      if (packageName.isEmpty) continue;
      apps.add(AndroidAppInfo(packageName: packageName, label: label, iconPng: iconPng));
    }
    return apps;
  }
}
