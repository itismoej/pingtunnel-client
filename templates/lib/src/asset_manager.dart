import 'dart:io';
import 'package:flutter/services.dart';

class AssetManager {
  AssetManager({this.appFolderName = '.pingtunnel-client'});

  final String appFolderName;

  Future<Directory> _appDir() async {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final base = home ?? Directory.systemTemp.path;
    final dir = Directory(_join([base, appFolderName]));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> installAsset(String assetPath, String relativePath,
      {bool executable = false}) async {
    final dir = await _appDir();
    final filePath = _join([dir.path, relativePath]);
    final file = File(filePath);
    if (await file.exists()) {
      return file.path;
    }
    await file.parent.create(recursive: true);
    final data = await _loadAsset(assetPath);
    await file.writeAsBytes(data.buffer.asUint8List());
    if (executable && !Platform.isWindows) {
      await Process.run('chmod', ['+x', file.path]);
    }
    return file.path;
  }

  static String _join(List<String> parts) {
    final sep = Platform.pathSeparator;
    return parts
        .where((part) => part.isNotEmpty)
        .map((part) => part.endsWith(sep) ? part.substring(0, part.length - 1) : part)
        .join(sep);
  }

  Future<ByteData> _loadAsset(String assetPath) async {
    try {
      return await rootBundle.load(assetPath);
    } catch (_) {
      final fallback = await _loadAssetFromDisk(assetPath);
      if (fallback != null) {
        return fallback;
      }
      rethrow;
    }
  }

  Future<ByteData?> _loadAssetFromDisk(String assetPath) async {
    for (final candidate in _candidatePaths(assetPath)) {
      final file = File(candidate);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        return ByteData.sublistView(Uint8List.fromList(bytes));
      }
    }
    return null;
  }

  List<String> _candidatePaths(String assetPath) {
    final candidates = <String>[];
    final override = Platform.environment['PINGTUNNEL_ASSETS_DIR'];
    if (override != null && override.isNotEmpty) {
      candidates.add(_join([override, assetPath]));
    }

    var dir = Directory.current;
    for (var i = 0; i < 4; i++) {
      candidates.add(_join([dir.path, assetPath]));
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    return candidates;
  }
}
