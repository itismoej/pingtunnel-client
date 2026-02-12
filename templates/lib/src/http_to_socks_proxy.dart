import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'log_buffer.dart';

class HttpToSocksProxy {
  HttpToSocksProxy({required this.logBuffer});

  final LogBuffer logBuffer;

  static const _headerDelimiter = <int>[13, 10, 13, 10];
  static const _maxHeaderSize = 64 * 1024;

  ServerSocket? _server;
  final Set<Socket> _clients = <Socket>{};

  Future<void> start({required int listenPort, required int socksPort}) async {
    await stop();

    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
      shared: false,
    );
    _server = server;
    logBuffer.add(
      '[mixed-proxy] Listening on 127.0.0.1:$listenPort '
      '-> SOCKS5 127.0.0.1:$socksPort',
    );

    server.listen(
      (client) {
        _clients.add(client);
        unawaited(
          _handleClient(client, socksPort).whenComplete(() {
            _clients.remove(client);
            _closeSocket(client);
          }),
        );
      },
      onError: (Object err) {
        logBuffer.add('[mixed-proxy] Accept error: $err');
      },
      cancelOnError: false,
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close();
    }
    for (final client in _clients.toList()) {
      _closeSocket(client);
    }
    _clients.clear();
  }

  Future<void> _handleClient(Socket client, int socksPort) async {
    final clientReader = _BufferedStreamReader(client);
    _SocksConnection? upstreamHttp;
    Socket? upstreamRaw;
    var isHttpRequest = false;

    try {
      final firstByte = await clientReader.readExact(1);
      final looksLikeHttp = _looksLikeHttpMethodStart(firstByte[0]);
      if (!looksLikeHttp) {
        upstreamRaw = await _connectToSocksServer(socksPort);
        await _tunnel(
          clientStream: clientReader.remainingStream(prefix: firstByte),
          upstreamStream: upstreamRaw,
          clientSocket: client,
          upstreamSocket: upstreamRaw,
        );
        return;
      }

      isHttpRequest = true;
      final remainingHeaders = await clientReader.readUntil(
        _headerDelimiter,
        maxBytes: _maxHeaderSize - 1,
      );
      final requestHeaders = BytesBuilder(copy: false)
        ..add(firstByte)
        ..add(remainingHeaders);
      final parsed = _parseRequest(requestHeaders.takeBytes());

      if (parsed.method == 'CONNECT') {
        final authority = _parseAuthority(parsed.target, defaultPort: 443);
        upstreamHttp = await _connectViaSocks(
          socksPort: socksPort,
          host: authority.host,
          port: authority.port,
        );

        client.add(
          latin1.encode('HTTP/1.1 200 Connection Established\r\n\r\n'),
        );
        await client.flush();
        await _tunnel(
          clientStream: clientReader.remainingStream(),
          upstreamStream: upstreamHttp.reader.remainingStream(),
          clientSocket: client,
          upstreamSocket: upstreamHttp.socket,
        );
      } else {
        final target = _resolveHttpTarget(parsed);
        upstreamHttp = await _connectViaSocks(
          socksPort: socksPort,
          host: target.host,
          port: target.port,
        );

        final rewrittenHeader = _buildForwardRequest(parsed, target);
        await _tunnel(
          clientStream: clientReader.remainingStream(prefix: rewrittenHeader),
          upstreamStream: upstreamHttp.reader.remainingStream(),
          clientSocket: client,
          upstreamSocket: upstreamHttp.socket,
        );
      }
    } catch (err) {
      logBuffer.add('[mixed-proxy] Client error: $err');
      if (isHttpRequest) {
        try {
          client.add(
            utf8.encode(
              'HTTP/1.1 502 Bad Gateway\r\n'
              'Connection: close\r\n'
              'Content-Type: text/plain; charset=utf-8\r\n'
              'Content-Length: 16\r\n\r\n'
              '502 Bad Gateway\n',
            ),
          );
          await client.flush();
        } catch (_) {}
      }
    } finally {
      await clientReader.cancel();
      if (upstreamHttp != null) {
        await upstreamHttp.reader.cancel();
        _closeSocket(upstreamHttp.socket);
      }
      _closeSocket(upstreamRaw);
    }
  }

  Future<void> _tunnel({
    required Stream<Uint8List> clientStream,
    required Stream<Uint8List> upstreamStream,
    required Socket clientSocket,
    required Socket upstreamSocket,
  }) async {
    final upload = _pipe(clientStream, upstreamSocket);
    final download = _pipe(upstreamStream, clientSocket);

    await Future.any([upload, download]);
    _closeSocket(upstreamSocket);
    _closeSocket(clientSocket);
    await Future.wait([upload, download], eagerError: false);
  }

  Future<void> _pipe(Stream<Uint8List> src, Socket dest) async {
    try {
      await dest.addStream(src);
      await dest.flush();
    } catch (_) {}
  }

  bool _looksLikeHttpMethodStart(int value) {
    return (value >= 0x41 && value <= 0x5a) || (value >= 0x61 && value <= 0x7a);
  }

  _ParsedRequest _parseRequest(Uint8List headerBytes) {
    final headerText = latin1.decode(headerBytes, allowInvalid: true);
    final lines = headerText.split('\r\n');
    if (lines.isEmpty || lines.first.trim().isEmpty) {
      throw const FormatException('Invalid proxy request line');
    }

    final parts = lines.first.split(' ');
    if (parts.length < 3) {
      throw const FormatException('Malformed request line');
    }

    final headers = <_HeaderLine>[];
    for (final line in lines.skip(1)) {
      if (line.isEmpty) break;
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final name = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      headers.add(_HeaderLine(name: name, value: value));
    }

    return _ParsedRequest(
      method: parts[0].toUpperCase(),
      target: parts[1],
      version: parts[2],
      headers: headers,
    );
  }

  _Target _resolveHttpTarget(_ParsedRequest request) {
    final rawTarget = request.target.trim();
    if (rawTarget.startsWith('http://') || rawTarget.startsWith('https://')) {
      final uri = Uri.parse(rawTarget);
      final host = uri.host;
      if (host.isEmpty) {
        throw const FormatException('Missing target host');
      }
      final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme.toLowerCase();
      final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
      final pathAndQuery =
          '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      return _Target(
        host: host,
        port: port,
        scheme: scheme,
        pathAndQuery: pathAndQuery,
      );
    }

    final hostHeader = request.headers
        .firstWhere(
          (header) => header.name.toLowerCase() == 'host',
          orElse: () => throw const FormatException('Missing Host header'),
        )
        .value;
    final authority = _parseAuthority(hostHeader, defaultPort: 80);
    final path = rawTarget.startsWith('/') ? rawTarget : '/$rawTarget';
    return _Target(
      host: authority.host,
      port: authority.port,
      scheme: 'http',
      pathAndQuery: path,
    );
  }

  Uint8List _buildForwardRequest(_ParsedRequest request, _Target target) {
    final hostHeader = _formatHostHeader(target);
    final sb = StringBuffer()
      ..write(
        '${request.method} ${target.pathAndQuery} ${request.version}\r\n',
      );

    var hasHost = false;
    for (final header in request.headers) {
      final name = header.name.toLowerCase();
      if (name == 'proxy-connection' ||
          name == 'proxy-authorization' ||
          name == 'connection') {
        continue;
      }
      if (name == 'host') {
        hasHost = true;
        sb.write('Host: $hostHeader\r\n');
        continue;
      }
      sb.write('${header.name}: ${header.value}\r\n');
    }

    if (!hasHost) {
      sb.write('Host: $hostHeader\r\n');
    }
    sb.write('Connection: close\r\n\r\n');
    return Uint8List.fromList(latin1.encode(sb.toString()));
  }

  String _formatHostHeader(_Target target) {
    final defaultPort = target.scheme == 'https' ? 443 : 80;
    final host =
        target.host.contains(':') &&
            !target.host.startsWith('[') &&
            !target.host.endsWith(']')
        ? '[${target.host}]'
        : target.host;
    if (target.port == defaultPort) {
      return host;
    }
    return '$host:${target.port}';
  }

  _Authority _parseAuthority(String authority, {required int defaultPort}) {
    final value = authority.trim();
    if (value.isEmpty) {
      throw const FormatException('Empty authority');
    }

    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end <= 0) {
        throw const FormatException('Invalid IPv6 authority');
      }
      final host = value.substring(1, end);
      if (end + 1 < value.length && value[end + 1] == ':') {
        final portText = value.substring(end + 2);
        final port = int.tryParse(portText);
        if (port == null || port < 1 || port > 65535) {
          throw const FormatException('Invalid authority port');
        }
        return _Authority(host: host, port: port);
      }
      return _Authority(host: host, port: defaultPort);
    }

    final lastColon = value.lastIndexOf(':');
    final hasSingleColon = lastColon > 0 && value.indexOf(':') == lastColon;
    if (hasSingleColon) {
      final host = value.substring(0, lastColon);
      final port = int.tryParse(value.substring(lastColon + 1));
      if (port != null && port >= 1 && port <= 65535) {
        return _Authority(host: host, port: port);
      }
    }

    return _Authority(host: value, port: defaultPort);
  }

  Future<_SocksConnection> _connectViaSocks({
    required int socksPort,
    required String host,
    required int port,
  }) async {
    final socket = await _connectToSocksServer(socksPort);
    final reader = _BufferedStreamReader(socket);

    socket.add(const <int>[0x05, 0x01, 0x00]);
    await socket.flush();
    final greeting = await reader.readExact(2);
    if (greeting.length != 2 || greeting[0] != 0x05 || greeting[1] != 0x00) {
      throw const SocketException('SOCKS5 auth negotiation failed');
    }

    final addressBytes = _buildSocksAddress(host);
    final requestBytes = BytesBuilder(copy: false)
      ..add(const <int>[0x05, 0x01, 0x00])
      ..add(addressBytes)
      ..add(<int>[(port >> 8) & 0xff, port & 0xff]);
    socket.add(requestBytes.takeBytes());
    await socket.flush();

    final head = await reader.readExact(4);
    if (head.length != 4 || head[0] != 0x05 || head[1] != 0x00) {
      throw SocketException(
        'SOCKS5 connect failed (code=${head.length > 1 ? head[1] : -1})',
      );
    }

    final atyp = head[3];
    if (atyp == 0x01) {
      await reader.readExact(6); // IPv4 + port
    } else if (atyp == 0x04) {
      await reader.readExact(18); // IPv6 + port
    } else if (atyp == 0x03) {
      final domainLen = await reader.readExact(1);
      await reader.readExact(domainLen[0] + 2);
    } else {
      throw const SocketException('Unsupported SOCKS5 ATYP');
    }

    return _SocksConnection(socket: socket, reader: reader);
  }

  Future<Socket> _connectToSocksServer(int socksPort) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      socksPort,
      timeout: const Duration(seconds: 8),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    return socket;
  }

  Uint8List _buildSocksAddress(String inputHost) {
    final host = inputHost.trim().replaceAll('[', '').replaceAll(']', '');
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      if (parsed.type == InternetAddressType.IPv4) {
        return Uint8List.fromList(<int>[0x01, ...parsed.rawAddress]);
      }
      if (parsed.type == InternetAddressType.IPv6) {
        return Uint8List.fromList(<int>[0x04, ...parsed.rawAddress]);
      }
    }

    final domainBytes = utf8.encode(host);
    if (domainBytes.isEmpty || domainBytes.length > 255) {
      throw const FormatException('Invalid target host');
    }
    return Uint8List.fromList(<int>[0x03, domainBytes.length, ...domainBytes]);
  }

  void _closeSocket(Socket? socket) {
    try {
      socket?.destroy();
    } catch (_) {}
  }
}

class _BufferedStreamReader {
  _BufferedStreamReader(Stream<Uint8List> stream)
    : _iterator = StreamIterator<Uint8List>(stream);

  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = <int>[];

  Future<Uint8List> readUntil(
    List<int> delimiter, {
    required int maxBytes,
  }) async {
    while (true) {
      final matchIndex = _indexOf(_buffer, delimiter);
      if (matchIndex >= 0) {
        final end = matchIndex + delimiter.length;
        final out = Uint8List.fromList(_buffer.sublist(0, end));
        _buffer.removeRange(0, end);
        return out;
      }
      if (_buffer.length > maxBytes) {
        throw const FormatException('Headers too large');
      }
      if (!await _iterator.moveNext()) {
        throw const SocketException('Unexpected EOF');
      }
      _buffer.addAll(_iterator.current);
    }
  }

  Future<Uint8List> readExact(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) {
        throw const SocketException('Unexpected EOF');
      }
      _buffer.addAll(_iterator.current);
    }
    final out = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    return out;
  }

  Stream<Uint8List> remainingStream({Uint8List? prefix}) async* {
    if (prefix != null && prefix.isNotEmpty) {
      yield prefix;
    }
    if (_buffer.isNotEmpty) {
      yield Uint8List.fromList(_buffer);
      _buffer.clear();
    }
    while (await _iterator.moveNext()) {
      yield _iterator.current;
    }
  }

  Future<void> cancel() => _iterator.cancel();

  int _indexOf(List<int> data, List<int> needle) {
    if (needle.isEmpty || data.length < needle.length) return -1;
    for (var i = 0; i <= data.length - needle.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }
}

class _HeaderLine {
  _HeaderLine({required this.name, required this.value});

  final String name;
  final String value;
}

class _ParsedRequest {
  _ParsedRequest({
    required this.method,
    required this.target,
    required this.version,
    required this.headers,
  });

  final String method;
  final String target;
  final String version;
  final List<_HeaderLine> headers;
}

class _Target {
  _Target({
    required this.host,
    required this.port,
    required this.scheme,
    required this.pathAndQuery,
  });

  final String host;
  final int port;
  final String scheme;
  final String pathAndQuery;
}

class _Authority {
  _Authority({required this.host, required this.port});

  final String host;
  final int port;
}

class _SocksConnection {
  _SocksConnection({required this.socket, required this.reader});

  final Socket socket;
  final _BufferedStreamReader reader;
}
