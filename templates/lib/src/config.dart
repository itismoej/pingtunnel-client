enum TunnelMode { proxy, vpn, proxyPerApp }

class TunnelConfig {
  TunnelConfig({
    required this.serverHost,
    this.serverPort,
    required this.localSocksPort,
    this.key,
    required this.mode,
    this.encryptMode,
    this.encryptKey,
    this.interfaceName,
    this.tunDevice,
    this.dns,
    this.proxyPerAppPackages = const <String>[],
  });

  final String serverHost;
  final int? serverPort;
  final int localSocksPort;
  final int? key;
  final TunnelMode mode;
  final String? encryptMode;
  final String? encryptKey;
  final String? interfaceName;
  final String? tunDevice;
  final String? dns;
  final List<String> proxyPerAppPackages;

  TunnelConfig copyWith({
    String? serverHost,
    int? serverPort,
    int? localSocksPort,
    int? key,
    TunnelMode? mode,
    String? encryptMode,
    String? encryptKey,
    String? interfaceName,
    String? tunDevice,
    String? dns,
    List<String>? proxyPerAppPackages,
  }) {
    return TunnelConfig(
      serverHost: serverHost ?? this.serverHost,
      serverPort: serverPort ?? this.serverPort,
      localSocksPort: localSocksPort ?? this.localSocksPort,
      key: key ?? this.key,
      mode: mode ?? this.mode,
      encryptMode: encryptMode ?? this.encryptMode,
      encryptKey: encryptKey ?? this.encryptKey,
      interfaceName: interfaceName ?? this.interfaceName,
      tunDevice: tunDevice ?? this.tunDevice,
      dns: dns ?? this.dns,
      proxyPerAppPackages: proxyPerAppPackages != null
          ? List<String>.from(proxyPerAppPackages)
          : this.proxyPerAppPackages,
    );
  }

  String serverAddress() {
    if (serverPort == null) {
      return serverHost;
    }
    return "$serverHost:$serverPort";
  }

  int localProxyBackendSocksPort() {
    if (localSocksPort < 1 || localSocksPort > 65535) {
      return 1081;
    }
    if (localSocksPort == 65535) {
      return 65534;
    }
    return localSocksPort + 1;
  }

  Map<String, Object?> toMap() {
    return {
      'serverHost': serverHost,
      'serverPort': serverPort,
      'localSocksPort': localSocksPort,
      'key': key,
      'mode': switch (mode) {
        TunnelMode.proxy => 'proxy',
        TunnelMode.vpn => 'vpn',
        TunnelMode.proxyPerApp => 'proxy_per_app',
      },
      'encryptMode': encryptMode,
      'encryptKey': encryptKey,
      'interfaceName': interfaceName,
      'tunDevice': tunDevice,
      'dns': dns,
      'proxyPerAppPackages': proxyPerAppPackages,
    };
  }

  static TunnelConfig parse(String uriText) {
    final uri = Uri.parse(uriText.trim());
    if (uri.scheme != 'pingtunnel') {
      throw const FormatException('URI scheme must be pingtunnel://');
    }

    String host = uri.host;
    if (host.isEmpty) {
      host = uri.path;
    }
    if (host.isEmpty) {
      throw const FormatException('Missing server host');
    }

    final params = uri.queryParameters;
    final keyText = params['key'] ?? '';
    final key = keyText.isEmpty ? null : int.tryParse(keyText);

    final localPort =
        int.tryParse(params['lport'] ?? params['local_port'] ?? '') ?? 1080;
    final serverPort = int.tryParse(
      params['port'] ?? params['server_port'] ?? '',
    );

    final modeValue = (params['mode'] ?? params['vpn'] ?? 'proxy')
        .toLowerCase();
    final mode = switch (modeValue) {
      'vpn' || '1' => TunnelMode.vpn,
      'proxy_per_app' ||
      'proxy-per-app' ||
      'per_app' ||
      'app' ||
      'app_proxy' => TunnelMode.proxyPerApp,
      _ => TunnelMode.proxy,
    };
    final proxyPerAppPackages =
        (params['apps'] ?? '')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    final encryptValue =
        (params['encrypt'] ??
                params['encrypt_mode'] ??
                params['encryptMode'] ??
                params['enc'] ??
                '')
            .toLowerCase();
    final validEncryptModes = {'aes128', 'aes256', 'chacha20'};
    final encryptMode =
        encryptValue.isEmpty ||
            encryptValue == '0' ||
            encryptValue == 'none' ||
            !validEncryptModes.contains(encryptValue)
        ? null
        : encryptValue;
    final encryptKey =
        params['encrypt-key'] ?? params['encrypt_key'] ?? params['encryptKey'];

    if (encryptMode == null && key == null) {
      throw const FormatException('Missing key');
    }
    if (encryptMode != null && (encryptKey == null || encryptKey.isEmpty)) {
      throw const FormatException('Missing encrypt_key');
    }
    if (keyText.isNotEmpty && key == null) {
      throw const FormatException('Key must be an integer');
    }

    return TunnelConfig(
      serverHost: host,
      serverPort: serverPort,
      localSocksPort: localPort,
      key: key,
      mode: mode,
      encryptMode: encryptMode,
      encryptKey: encryptKey,
      interfaceName: params['iface'] ?? params['interface'],
      tunDevice: params['tun'] ?? params['tun_device'],
      dns: params['dns'],
      proxyPerAppPackages: proxyPerAppPackages,
    );
  }
}
