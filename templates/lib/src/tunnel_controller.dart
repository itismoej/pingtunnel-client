import 'dart:io';

import 'asset_manager.dart';
import 'android_runner.dart';
import 'config.dart';
import 'desktop_runner.dart';
import 'log_buffer.dart';
import 'socks5_probe.dart';

enum TunnelStatus { disconnected, connecting, connected, error }

class TunnelController {
  TunnelController()
      : logBuffer = LogBuffer(),
        assets = AssetManager() {
    _desktopRunner = DesktopRunner(assets: assets, logBuffer: logBuffer);
    _androidRunner = AndroidRunner();
  }

  final LogBuffer logBuffer;
  final AssetManager assets;
  late final DesktopRunner _desktopRunner;
  late final AndroidRunner _androidRunner;

  TunnelStatus status = TunnelStatus.disconnected;
  String? lastError;

  Future<String> testConnection(TunnelConfig config) async {
    if (config.mode == TunnelMode.vpn) {
      final socksProbe = Socks5Probe();
      logBuffer.add('[test] VPN mode: checking tunnel core via SOCKS5...');
      try {
        final ip = await socksProbe.run(socksPort: config.localSocksPort);
        logBuffer.add('[test] OK (socks): $ip');
        return ip;
      } catch (err) {
        final message = err.toString();
        logBuffer.add('[test] FAILED: $message');
        rethrow;
      }
    }
    final probe = Socks5Probe();
    logBuffer.add('[test] Starting SOCKS5 probe...');
    try {
      final ip = await probe.run(socksPort: config.localSocksPort);
      logBuffer.add('[test] OK: $ip');
      return ip;
    } catch (err) {
      final message = err.toString();
      logBuffer.add('[test] FAILED: $message');
      rethrow;
    }
  }

  Future<void> start(TunnelConfig config) async {
    status = TunnelStatus.connecting;
    lastError = null;
    logBuffer.clear();

    try {
      if (Platform.isAndroid) {
        if (config.mode == TunnelMode.vpn) {
          final ok = await _androidRunner.prepareVpn();
          if (!ok) {
            throw StateError('VPN permission not granted');
          }
          await _androidRunner.startVpn(config);
        } else {
          await _androidRunner.startProxy(config);
        }
      } else {
        if (config.mode == TunnelMode.proxy) {
          await _desktopRunner.startProxy(config);
        } else {
          await _desktopRunner.startVpn(config);
        }
      }

      status = TunnelStatus.connected;
    } catch (err) {
      lastError = err.toString();
      status = TunnelStatus.error;
      rethrow;
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _androidRunner.stop();
    } else {
      await _desktopRunner.stop();
    }
    status = TunnelStatus.disconnected;
  }
}
