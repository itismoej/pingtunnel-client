import 'package:flutter/services.dart';

import 'config.dart';

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
}
