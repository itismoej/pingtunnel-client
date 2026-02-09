import 'dart:io';
import 'package:flutter/foundation.dart';
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
    final candidates = _assetPathCandidates(assetPath);
    Object? originalError;
    StackTrace? originalStack;

    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      try {
        return await rootBundle.load(candidate);
      } catch (err, stack) {
        if (i == 0) {
          originalError = err;
          originalStack = stack;
        }
      }
    }

    final fallback = await _loadAssetFromDisk(candidates);
    if (fallback != null) {
      return fallback;
    }

    if (originalError != null && originalStack != null) {
      Error.throwWithStackTrace(originalError, originalStack);
    }
    throw FlutterError('Unable to load asset: $assetPath');
  }

  Future<ByteData?> _loadAssetFromDisk(List<String> assetPaths) async {
    for (final assetPath in assetPaths) {
      for (final candidate in _candidatePaths(assetPath)) {
        final file = File(candidate);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          return ByteData.sublistView(Uint8List.fromList(bytes));
        }
      }
    }
    return null;
  }

  List<String> _assetPathCandidates(String assetPath) {
    final candidates = <String>{assetPath};

    final normalized = _normalizeBinaryAssetPath(assetPath);
    if (normalized != null && normalized.isNotEmpty) {
      candidates.add(normalized);
    }

    if (assetPath.contains('/macos-')) {
      candidates.add(assetPath.replaceAll('/macos-', '/darwin-'));
    }
    if (assetPath.contains('/darwin-')) {
      candidates.add(assetPath.replaceAll('/darwin-', '/macos-'));
    }

    return candidates.toList();
  }

  String? _normalizeBinaryAssetPath(String assetPath) {
    final flattened = RegExp(
      r'^(assets/binaries/[^/]+)/(linux|windows|macos|darwin)-(amd64|arm64)-([^/]+)$',
    );
    final flat = flattened.firstMatch(assetPath);
    if (flat != null) {
      return '${flat.group(1)}/${flat.group(2)}-${flat.group(3)}/${flat.group(4)}';
    }

    final split = RegExp(
      r'^(assets/binaries/[^/]+)/(linux|windows|macos|darwin)-(amd64|arm64)/([^/]+)$',
    );
    final grouped = split.firstMatch(assetPath);
    if (grouped != null) {
      return '${grouped.group(1)}/${grouped.group(2)}-${grouped.group(3)}-${grouped.group(4)}';
    }

    return null;
  }

  List<String> _candidatePaths(String assetPath) {
    final candidates = <String>{};

    final override = Platform.environment['PINGTUNNEL_ASSETS_DIR'];
    if (override != null && override.isNotEmpty) {
      candidates.add(_join([override, assetPath]));
    }

    // Installed Linux/macOS bundle layout: <app-dir>/data/flutter_assets
    final executable = Platform.resolvedExecutable;
    if (executable.isNotEmpty) {
      final exeDir = File(executable).parent;
      candidates.add(_join([exeDir.path, 'data', 'flutter_assets', assetPath]));
      candidates.add(_join([exeDir.parent.path, 'data', 'flutter_assets', assetPath]));
      candidates.add(_join([exeDir.path, 'flutter_assets', assetPath]));
    }

    var dir = Directory.current;
    for (var i = 0; i < 4; i++) {
      candidates.add(_join([dir.path, assetPath]));
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }

    return candidates.toList();
  }
}
