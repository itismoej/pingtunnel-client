import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'asset_manager.dart';
import 'config.dart';
import 'log_buffer.dart';

class PlatformInfo {
  PlatformInfo({required this.os, required this.arch});

  final String os;
  final String arch;

  bool get isWindows => os == 'windows';
  bool get isMacos => os == 'macos';
  bool get isLinux => os == 'linux';
}

class DesktopRunner {
  DesktopRunner({required this.assets, required this.logBuffer});

  final AssetManager assets;
  final LogBuffer logBuffer;

  static const int _capNetAdmin = 12;
  static const int _capNetRaw = 13;

  Process? _pingtunnel;
  Process? _tun2socks;
  PlatformInfo? _platform;
  TunnelMode? _activeMode;

  Future<void> startProxy(TunnelConfig config) async {
    _platform ??= await _detectPlatform();
    final pingtunnel = await _startPingtunnel(config);
    _pingtunnel = pingtunnel;
    try {
      await _waitForSocksReady(
        pingtunnel,
        config.localSocksPort,
        platform: _platform!,
      );
    } catch (_) {
      await _stopProcess(_pingtunnel);
      _pingtunnel = null;
      rethrow;
    }
    _activeMode = TunnelMode.proxy;
  }

  Future<void> startVpn(TunnelConfig config) async {
    _platform ??= await _detectPlatform();
    final platform = _platform!;
    bool vpnUpApplied = false;

    try {
      final pingtunnel = await _startPingtunnel(config);
      _pingtunnel = pingtunnel;
      await _waitForSocksReady(
        pingtunnel,
        config.localSocksPort,
        platform: platform,
      );

      final iface = config.interfaceName ?? await _detectInterface(platform);
      if (iface == null) {
        throw StateError('Failed to detect outbound interface. Provide ?iface=...');
      }

      final tunDevice = config.tunDevice ?? _defaultTunDevice(platform);

      if (platform.isLinux) {
        await _warnIfMissingNetAdmin();
        await _runScript(platform, 'vpn_up', [tunDevice, iface], config);
        vpnUpApplied = true;
        _tun2socks = await _startTun2Socks(config, platform, tunDevice, iface);
      } else if (platform.isMacos) {
        _tun2socks = await _startTun2Socks(config, platform, tunDevice, iface);
        await _runScript(platform, 'vpn_up', [tunDevice], config);
        vpnUpApplied = true;
      } else if (platform.isWindows) {
        _tun2socks = await _startTun2Socks(config, platform, tunDevice, iface);
        await _runScript(platform, 'vpn_up', [tunDevice], config);
        vpnUpApplied = true;
      } else {
        throw UnsupportedError('Unsupported platform for VPN mode');
      }

      _activeMode = TunnelMode.vpn;
    } catch (_) {
      if (vpnUpApplied) {
        try {
          await _runScript(platform, 'vpn_down', [], null);
        } catch (err) {
          logBuffer.add('[vpn_down] $err');
        }
      }
      await _stopProcess(_tun2socks);
      await _stopProcess(_pingtunnel);
      _tun2socks = null;
      _pingtunnel = null;
      _activeMode = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    final platform = _platform;
    if (platform != null) {
      if (_activeMode == TunnelMode.vpn) {
        try {
          if (platform.isLinux) {
            await _stopProcess(_tun2socks);
            await _runScript(platform, 'vpn_down', [], null);
          } else if (platform.isMacos || platform.isWindows) {
            await _runScript(platform, 'vpn_down', [], null);
            await _stopProcess(_tun2socks);
          }
        } catch (err) {
          logBuffer.add('[vpn_down] $err');
        }
      } else {
        await _stopProcess(_tun2socks);
      }
    }

    await _stopProcess(_pingtunnel);
    _tun2socks = null;
    _pingtunnel = null;
    _activeMode = null;
  }

  Future<Process> _startPingtunnel(TunnelConfig config) async {
    final platform = _platform!;
    final bin = await _resolveBinary(
      'pingtunnel',
      platform,
      config,
    );
    if (platform.isLinux) {
      await _warnIfMissingNetRaw(bin);
    }

    final args = <String>[
      '-type',
      'client',
      '-l',
      ':${config.localSocksPort}',
      '-s',
      config.serverAddress(),
      '-sock5',
      '1',
    ];

    if (config.encryptMode != null && config.encryptMode!.isNotEmpty) {
      args.addAll(['-encrypt', config.encryptMode!]);
      if (config.encryptKey == null || config.encryptKey!.isEmpty) {
        throw StateError('encrypt key missing');
      }
      args.addAll(['-encrypt-key', config.encryptKey!]);
    } else if (config.key != null) {
      args.addAll(['-key', config.key.toString()]);
    }

    return _startProcess(bin, args, label: 'pingtunnel');
  }

  Future<Process> _startTun2Socks(
    TunnelConfig config,
    PlatformInfo platform,
    String tunDevice,
    String iface,
  ) async {
    final bin = await _resolveBinary('tun2socks', platform, config);
    final proxy = 'socks5://127.0.0.1:${config.localSocksPort}';

    final args = <String>[];
    if (platform.isMacos) {
      args.addAll(['-device', 'tun://$tunDevice']);
    } else if (platform.isWindows) {
      args.addAll(['-device', 'wintun']);
    } else {
      args.addAll(['-device', tunDevice]);
    }

    args.addAll(['-proxy', proxy, '-interface', iface]);

    return _startProcess(bin, args, label: 'tun2socks');
  }

  Future<String> _resolveBinary(
    String name,
    PlatformInfo platform,
    TunnelConfig config,
  ) async {
    final ext = platform.isWindows ? '.exe' : '';
    final systemBinary = _systemBinaryPath(name, platform, ext);
    if (systemBinary != null) {
      final file = File(systemBinary);
      if (await file.exists()) {
        return file.path;
      }
    }

    final assetPath = 'assets/binaries/$name/${platform.os}-${platform.arch}/$name$ext';
    final outputPath = 'bin/$name/${platform.os}-${platform.arch}/$name$ext';
    return assets.installAsset(assetPath, outputPath, executable: true);
  }

  String? _systemBinaryPath(String name, PlatformInfo platform, String ext) {
    if (!platform.isLinux) {
      return null;
    }
    final archDir = '${platform.os}-${platform.arch}';
    return '/usr/libexec/pingtunnel-client/binaries/$name/$archDir/$name$ext';
  }

  Future<void> _runScript(
    PlatformInfo platform,
    String scriptName,
    List<String> args,
    TunnelConfig? config,
  ) async {
    if (platform.isWindows) {
      final scriptPath = await assets.installAsset(
        'assets/scripts/windows/$scriptName.ps1',
        'scripts/windows/$scriptName.ps1',
      );
      final psArgs = <String>[
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
      ];
      if (args.isNotEmpty) {
        psArgs.addAll(['-AdapterName', args.first]);
      }
      if (config?.dns != null && config!.dns!.isNotEmpty) {
        psArgs.addAll(['-Dns', config.dns!]);
      }
      await _runCommand('powershell', psArgs, label: scriptName);
    } else if (platform.isMacos) {
      final scriptPath = await assets.installAsset(
        'assets/scripts/macos/$scriptName.sh',
        'scripts/macos/$scriptName.sh',
        executable: true,
      );
      await _runCommand(scriptPath, args, label: scriptName);
    } else if (platform.isLinux) {
      final scriptPath = await assets.installAsset(
        'assets/scripts/linux/$scriptName.sh',
        'scripts/linux/$scriptName.sh',
        executable: true,
      );
      final scriptArgs = List<String>.from(args);
      if (scriptName == 'vpn_up') {
        scriptArgs.add(config?.serverHost ?? '');
        if (config?.dns != null && config!.dns!.isNotEmpty) {
          scriptArgs.add(config.dns!);
        }
      }
      await _runLinuxVpnScript(scriptName, scriptPath, scriptArgs);
    }
  }

  Future<void> _runCommand(String command, List<String> args,
      {required String label}) async {
    final result = await Process.run(command, args);
    if (result.stdout != null && result.stdout.toString().trim().isNotEmpty) {
      logBuffer.add('[$label] ${result.stdout.toString().trim()}');
    }
    if (result.stderr != null && result.stderr.toString().trim().isNotEmpty) {
      logBuffer.add('[$label] ${result.stderr.toString().trim()}');
    }
    if (result.exitCode != 0) {
      throw StateError('$label failed with exit code ${result.exitCode}');
    }
  }

  Future<void> _runLinuxVpnScript(
    String scriptName,
    String scriptPath,
    List<String> args,
  ) async {
    if (scriptName != 'vpn_up' && scriptName != 'vpn_down') {
      await _runCommand(scriptPath, args, label: scriptName);
      return;
    }

    if (await _hasProcessCapability(_capNetAdmin)) {
      await _runCommand(scriptPath, args, label: scriptName);
      return;
    }

    if (await _commandExists('pkexec')) {
      final helper = await _findPolkitHelper();
      if (helper != null) {
        final action = scriptName == 'vpn_up' ? 'up' : 'down';
        logBuffer.add('[vpn] Using polkit helper for $scriptName');
        await _runCommand('pkexec', [helper, action, ...args], label: scriptName);
        return;
      }
    }

    if (!await _hasProcessCapability(_capNetAdmin)) {
      throw StateError(
        'VPN needs CAP_NET_ADMIN or an installed polkit helper. '
        'Install the helper (sudo ./scripts/install_polkit_helper.sh) '
        'or run with NET_ADMIN.',
      );
    }

    await _runCommand(scriptPath, args, label: scriptName);
  }

  Future<String?> _findPolkitHelper() async {
    const candidates = [
      '/usr/local/libexec/pingtunnel-client/vpn-helper',
      '/usr/libexec/pingtunnel-client/vpn-helper',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) {
        return path;
      }
    }
    return null;
  }

  Future<bool> _commandExists(String command) async {
    final result = await Process.run('which', [command]);
    return result.exitCode == 0;
  }

  Future<void> _warnIfMissingNetRaw(String binaryPath) async {
    if (await _hasProcessCapability(_capNetRaw)) {
      return;
    }

    if (await _binaryHasCapability(binaryPath, 'cap_net_raw')) {
      return;
    }

    logBuffer.add(
      '[warn] Linux needs CAP_NET_RAW for pingtunnel. '
      'If you see "operation not permitted", run with NET_RAW '
      '(docker --cap-add NET_RAW) or setcap cap_net_raw+ep on the binary.',
    );
  }

  Future<void> _warnIfMissingNetAdmin() async {
    final hasNetAdmin = await _hasProcessCapability(_capNetAdmin);
    if (!hasNetAdmin) {
      logBuffer.add(
        '[warn] Linux VPN needs CAP_NET_ADMIN (routes/TUN). '
        'If vpn_up fails, run with NET_ADMIN or as root.',
      );
    }
  }

  Future<bool> _hasProcessCapability(int cap) async {
    try {
      final status = await File('/proc/self/status').readAsLines();
      final line = status.firstWhere(
        (value) => value.startsWith('CapEff:'),
        orElse: () => '',
      );
      if (line.isEmpty) return false;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) return false;
      final value = BigInt.parse(parts[1], radix: 16);
      return (value & (BigInt.one << cap)) != BigInt.zero;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _binaryHasCapability(String path, String capability) async {
    try {
      final result = await Process.run('getcap', [path]);
      if (result.exitCode != 0) {
        return false;
      }
      final output = result.stdout.toString();
      return output.contains(capability);
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForSocksReady(
    Process process,
    int port, {
    required PlatformInfo platform,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));

    while (DateTime.now().isBefore(deadline)) {
      final exitCode = await process.exitCode
          .timeout(Duration.zero, onTimeout: () => -1);
      if (exitCode >= 0) {
        throw StateError(_pingtunnelStartFailureMessage(platform));
      }

      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 180),
        );
        socket.destroy();
        return;
      } catch (_) {}

      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    throw StateError(
      'pingtunnel did not start its local SOCKS listener on 127.0.0.1:$port.',
    );
  }

  String _pingtunnelStartFailureMessage(PlatformInfo platform) {
    if (platform.isLinux) {
      return 'pingtunnel exited before startup. '
          'Linux requires CAP_NET_RAW for ICMP '
          '(setcap cap_net_raw+ep <pingtunnel-binary> or run with NET_RAW).';
    }
    return 'pingtunnel exited before startup. Check configuration and logs.';
  }

  Future<Process> _startProcess(String bin, List<String> args,
      {required String label}) async {
    logBuffer.add('Starting $label: $bin ${args.join(' ')}');
    final process = await Process.start(bin, args);
    process.stdout.transform(utf8.decoder).listen((data) {
      for (final line in LineSplitter.split(data)) {
        logBuffer.add('[$label] $line');
      }
    });
    process.stderr.transform(utf8.decoder).listen((data) {
      for (final line in LineSplitter.split(data)) {
        logBuffer.add('[$label] $line');
      }
    });
    return process;
  }

  Future<void> _stopProcess(Process? process) async {
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return process.exitCode;
    });
  }

  Future<PlatformInfo> _detectPlatform() async {
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : Platform.isLinux
                ? 'linux'
                : 'unknown';

    final arch = await _detectArch();
    return PlatformInfo(os: os, arch: arch);
  }

  Future<String> _detectArch() async {
    if (Platform.isWindows) {
      final arch = (Platform.environment['PROCESSOR_ARCHITECTURE'] ??
              Platform.environment['PROCESSOR_ARCHITEW6432'] ??
              '')
          .toLowerCase();
      if (arch.contains('arm64')) return 'arm64';
      return 'amd64';
    }

    final result = await Process.run('uname', ['-m']);
    final arch = result.stdout.toString().trim().toLowerCase();
    if (arch.contains('arm64') || arch.contains('aarch64')) {
      return 'arm64';
    }
    return 'amd64';
  }

  Future<String?> _detectInterface(PlatformInfo platform) async {
    if (platform.isLinux) {
      final result = await Process.run('sh', [
        '-c',
        "ip route show default 0.0.0.0/0 | awk '{print \$5; exit}'"
      ]);
      final iface = result.stdout.toString().trim();
      return iface.isEmpty ? null : iface;
    }

    if (platform.isMacos) {
      final result = await Process.run('sh', [
        '-c',
        "route get default | awk '/interface:/{print \$2; exit}'"
      ]);
      final iface = result.stdout.toString().trim();
      return iface.isEmpty ? null : iface;
    }

    if (platform.isWindows) {
      final result = await Process.run('powershell', [
        '-Command',
        "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias"
      ]);
      final iface = result.stdout.toString().trim();
      return iface.isEmpty ? null : iface;
    }

    return null;
  }

  String _defaultTunDevice(PlatformInfo platform) {
    if (platform.isMacos) return 'utun2';
    if (platform.isWindows) return 'wintun';
    return 'ptun0';
  }
}
