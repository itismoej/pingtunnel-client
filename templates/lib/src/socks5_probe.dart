import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Socks5Probe {
  Socks5Probe({
    this.targetHost = 'ipv4.ident.me',
    this.targetPort = 80,
    this.timeout = const Duration(seconds: 8),
  });

  final String targetHost;
  final int targetPort;
  final Duration timeout;

  Future<String> run({required int socksPort}) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      socksPort,
      timeout: timeout,
    );
    final buffer = _SocketBuffer(socket);

    try {
      socket.add(const [0x05, 0x01, 0x00]);
      await socket.flush();

      final greeting = await buffer.readExact(2, timeout);
      if (greeting[0] != 0x05 || greeting[1] == 0xFF) {
        throw StateError('SOCKS5 auth failed');
      }

      final hostBytes = utf8.encode(targetHost);
      final portBytes = _portBytes(targetPort);
      socket.add([
        0x05,
        0x01,
        0x00,
        0x03,
        hostBytes.length,
        ...hostBytes,
        ...portBytes,
      ]);
      await socket.flush();

      final reply = await buffer.readExact(4, timeout);
      if (reply[0] != 0x05 || reply[1] != 0x00) {
        throw StateError('SOCKS5 connect failed (code ${reply[1]})');
      }
      await _consumeAddress(buffer, reply[3], timeout);

      final request = StringBuffer()
        ..write('GET / HTTP/1.1\r\n')
        ..write('Host: $targetHost\r\n')
        ..write('User-Agent: pingtunnel-client\r\n')
        ..write('Connection: close\r\n')
        ..write('\r\n');

      socket.add(utf8.encode(request.toString()));
      await socket.flush();

      final responseBytes = await buffer.readToEnd(timeout: timeout);
      final response = utf8.decode(responseBytes, allowMalformed: true);
      final body = _extractBody(response);
      if (body.isEmpty) {
        throw StateError('Empty response body');
      }
      return body.trim();
    } finally {
      socket.destroy();
    }
  }

  List<int> _portBytes(int port) => [(port >> 8) & 0xff, port & 0xff];

  Future<void> _consumeAddress(
    _SocketBuffer buffer,
    int addrType,
    Duration timeout,
  ) async {
    switch (addrType) {
      case 0x01:
        await buffer.readExact(4, timeout);
        break;
      case 0x03:
        final len = (await buffer.readExact(1, timeout))[0];
        await buffer.readExact(len, timeout);
        break;
      case 0x04:
        await buffer.readExact(16, timeout);
        break;
      default:
        throw StateError('Unknown SOCKS5 address type: $addrType');
    }
    await buffer.readExact(2, timeout);
  }

  String _extractBody(String response) {
    final idx = response.indexOf('\r\n\r\n');
    if (idx == -1) return '';
    return response.substring(idx + 4);
  }
}

class _SocketBuffer {
  _SocketBuffer(this.socket) {
    socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  final Socket socket;
  final List<int> _buffer = <int>[];
  final List<_ReadRequest> _waiters = <_ReadRequest>[];
  final Completer<void> _done = Completer<void>();
  Object? _error;

  Future<Uint8List> readExact(int length, Duration timeout) {
    if (_error != null) {
      return Future.error(_error!);
    }
    if (_buffer.length >= length) {
      return Future.value(_take(length));
    }
    final completer = Completer<Uint8List>();
    _waiters.add(_ReadRequest(length, completer));
    return completer.future.timeout(timeout);
  }

  Future<Uint8List> readToEnd({required Duration timeout}) async {
    if (_error != null) {
      return Future.error(_error!);
    }
    await _done.future.timeout(timeout);
    return Uint8List.fromList(_buffer);
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    _flush();
  }

  void _onError(Object error) {
    _error = error;
    for (final waiter in _waiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error);
      }
    }
    _waiters.clear();
    if (!_done.isCompleted) {
      _done.completeError(error);
    }
  }

  void _onDone() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  void _flush() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.first;
      if (_buffer.length < waiter.length) {
        break;
      }
      _waiters.removeAt(0);
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(_take(waiter.length));
      }
    }
    if (_done.isCompleted && _waiters.isNotEmpty) {
      final error = StateError('Socket closed before enough data was read');
      for (final waiter in _waiters) {
        if (!waiter.completer.isCompleted) {
          waiter.completer.completeError(error);
        }
      }
      _waiters.clear();
    }
  }

  Uint8List _take(int length) {
    final chunk = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return Uint8List.fromList(chunk);
  }
}

class _ReadRequest {
  _ReadRequest(this.length, this.completer);

  final int length;
  final Completer<Uint8List> completer;
}
