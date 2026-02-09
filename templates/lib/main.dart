import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'src/config.dart';
import 'src/tunnel_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) {
    await windowManager.ensureInitialized();
  }
  runApp(const PingtunnelApp());
}

class PingtunnelApp extends StatefulWidget {
  const PingtunnelApp({super.key});

  @override
  State<PingtunnelApp> createState() => _PingtunnelAppState();
}

class _PingtunnelAppState extends State<PingtunnelApp> {
  static const _prefsKeyThemeMode = 'theme_mode';

  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    unawaited(_loadThemeMode());
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKeyThemeMode);
    final mode = _themeModeFromStorage(saved);
    if (!mounted || mode == _themeMode) return;
    setState(() {
      _themeMode = mode;
    });
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    setState(() {
      _themeMode = mode;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyThemeMode, _themeModeToStorage(mode));
  }

  String _themeModeToStorage(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  ThemeMode _themeModeFromStorage(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF0E7A6A);
    final lightScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Pingtunnel Client',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: lightScheme,
        scaffoldBackgroundColor: lightScheme.surface,
        cardTheme: CardThemeData(
          color: lightScheme.surfaceContainerLow,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: lightScheme.outlineVariant),
          ),
          margin: EdgeInsets.zero,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: darkScheme,
        scaffoldBackgroundColor: darkScheme.surface,
        cardTheme: CardThemeData(
          color: darkScheme.surfaceContainerLow,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: darkScheme.outlineVariant),
          ),
          margin: EdgeInsets.zero,
        ),
      ),
      themeMode: _themeMode,
      home: ConnectionListPage(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
      ),
    );
  }
}

class ConnectionEntry {
  ConnectionEntry({required this.uri, required this.config});

  final String uri;
  final TunnelConfig config;

  String get id => uri;
  String get title => config.serverHost;
}

typedef SaveConnection = void Function(ConnectionEntry entry, {bool showMessage});

String buildConnectionUri(TunnelConfig config) {
  final params = <String, String>{
    'lport': config.localSocksPort.toString(),
    'mode': config.mode == TunnelMode.vpn ? 'vpn' : 'proxy',
  };
  if (config.encryptMode == null && config.key != null) {
    params['key'] = config.key.toString();
  }
  if (config.serverPort != null) {
    params['port'] = config.serverPort.toString();
  }
  if (config.encryptMode != null && config.encryptMode!.isNotEmpty) {
    params['encrypt'] = config.encryptMode!;
    if (config.encryptKey != null && config.encryptKey!.isNotEmpty) {
      params['encrypt_key'] = config.encryptKey!;
    }
  }
  return Uri(
    scheme: 'pingtunnel',
    host: config.serverHost,
    queryParameters: params,
  ).toString();
}

class ConnectionListPage extends StatefulWidget {
  const ConnectionListPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<ConnectionListPage> createState() => _ConnectionListPageState();
}

class _ConnectionListPageState extends State<ConnectionListPage>
    with WindowListener {
  static const _prefsKeyConnections = 'connections';
  static const _prefsKeySelected = 'selected_connection';
  static const MethodChannel _linuxTrayChannel = MethodChannel(
    'pingtunnel_tray_linux',
  );

  final TunnelController _controller = TunnelController();
  final List<ConnectionEntry> _entries = <ConnectionEntry>[];
  String? _activeId;
  String? _selectedId;
  bool _testing = false;
  String? _lastProbeError;
  DateTime? _lastProbeAt;
  Timer? _uiTimer;
  bool _loading = true;
  bool _linuxTrayReady = false;
  bool _linuxExitRequested = false;
  bool _syncingAndroidStatus = false;
  int _androidSyncTick = 0;
  int _androidNotRunningSamples = 0;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {});
      }
      if (_isAndroidDevice) {
        _androidSyncTick = (_androidSyncTick + 1) % 2;
        if (_androidSyncTick == 0) {
          unawaited(_syncAndroidRuntimeState());
        }
      }
    });
    _initLinuxTray();
    _loadConnections();
    if (_isAndroidDevice) {
      unawaited(_syncAndroidRuntimeState());
    }
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    if (_isLinuxDesktop) {
      _linuxTrayChannel.setMethodCallHandler(null);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  bool get _isLinuxDesktop => Platform.isLinux;
  bool get _isAndroidDevice => Platform.isAndroid;

  Future<void> _initLinuxTray() async {
    if (!_isLinuxDesktop) return;
    windowManager.addListener(this);
    try {
      _linuxTrayChannel.setMethodCallHandler(_onLinuxTrayMethodCall);
      await windowManager.setPreventClose(true);
      _linuxTrayReady = true;
      await _refreshLinuxTrayState();
    } catch (_) {
      _linuxTrayReady = false;
    }
  }

  void _scheduleLinuxTrayRefresh() {
    if (!_linuxTrayReady) return;
    unawaited(_refreshLinuxTrayState());
  }

  Future<void> _refreshLinuxTrayState() async {
    if (!_linuxTrayReady) return;

    final active = _activeEntry();
    final selected = _selectedEntry();
    final target = active ?? selected;
    final mode = target?.config.mode == TunnelMode.vpn
        ? 'vpn'
        : target?.config.mode == TunnelMode.proxy
            ? 'proxy'
            : 'none';

    try {
      await _linuxTrayChannel.invokeMethod<void>('updateState', <String, dynamic>{
        'connected': _activeId != null,
        'mode': mode,
        'hasTarget': target != null,
      });
    } catch (_) {}
  }

  ConnectionEntry? _trayTargetEntry() {
    return _activeEntry() ?? _selectedEntry() ?? (_entries.isNotEmpty ? _entries.first : null);
  }

  Future<void> _showWindowFromTray() async {
    if (!_isLinuxDesktop) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _syncAndroidRuntimeState() async {
    if (!_isAndroidDevice || _syncingAndroidStatus) return;
    _syncingAndroidStatus = true;
    try {
      final running = await _controller.isAndroidRunning();
      if (!mounted) return;
      if (running) {
        _androidNotRunningSamples = 0;
        return;
      }
      _androidNotRunningSamples += 1;
      if (_androidNotRunningSamples < 2) {
        return;
      }
      if (
          (_activeId != null ||
              _controller.status == TunnelStatus.connected ||
              _controller.status == TunnelStatus.connecting)) {
        _controller.markDisconnectedExternally();
        setState(() {
          _activeId = null;
        });
      }
    } catch (_) {
    } finally {
      _syncingAndroidStatus = false;
    }
  }

  Future<void> _onLinuxTrayMethodCall(MethodCall call) async {
    if (call.method != 'onTrayEvent') return;
    final args = call.arguments;
    var event = '';
    if (args is Map) {
      event = args['event']?.toString() ?? '';
    }

    switch (event) {
      case 'connect':
        await _connectSelected();
        break;
      case 'show':
        await _showWindowFromTray();
        break;
      case 'disconnect':
        await _disconnectActive(showMessage: false);
        break;
      case 'switch_proxy':
        await _switchModeFromTray(TunnelMode.proxy);
        break;
      case 'switch_vpn':
        await _switchModeFromTray(TunnelMode.vpn);
        break;
      case 'exit':
        await _exitFromTray();
        break;
      default:
        break;
    }
  }

  Future<void> _switchModeFromTray(TunnelMode mode) async {
    final target = _trayTargetEntry();
    if (target == null) {
      await _showWindowFromTray();
      _showMessage('Add a connection first');
      return;
    }

    final wasActive = _activeId == target.id;
    final updatedConfig = target.config.copyWith(mode: mode);
    final updated = ConnectionEntry(
      uri: buildConnectionUri(updatedConfig),
      config: updatedConfig,
    );
    _updateEntry(target, updated, showMessage: false);
    _selectEntry(updated);

    if (wasActive) {
      try {
        await _controller.stop();
        await _controller.start(updated.config);
        setState(() {
          _activeId = updated.id;
        });
      } catch (err) {
        setState(() {
          _activeId = null;
        });
        _showMessage('Failed to switch mode: $err');
        _scheduleLinuxTrayRefresh();
        return;
      }
    }

    _showMessage('Mode set to ${mode == TunnelMode.vpn ? "VPN" : "Proxy"}');
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _exitFromTray() async {
    _linuxExitRequested = true;
    try {
      if (_activeId != null) {
        await _controller.stop();
      }
    } catch (_) {}

    if (_isLinuxDesktop) {
      await windowManager.setPreventClose(false);
      try {
        await _linuxTrayChannel.invokeMethod<void>('exitNow');
        return;
      } catch (_) {}
      await windowManager.close();
    }
  }

  @override
  void onWindowClose() async {
    if (!_isLinuxDesktop || _linuxExitRequested) return;
    final preventClose = await windowManager.isPreventClose();
    if (preventClose) {
      await windowManager.hide();
    }
  }

  Future<void> _loadConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final uris = prefs.getStringList(_prefsKeyConnections) ?? <String>[];
    final selected = prefs.getString(_prefsKeySelected);
    final loaded = <ConnectionEntry>[];
    for (final uri in uris) {
      try {
        final config = TunnelConfig.parse(uri);
        loaded.add(ConnectionEntry(uri: uri, config: config));
      } catch (_) {
        continue;
      }
    }
    setState(() {
      _entries
        ..clear()
        ..addAll(loaded);
      _selectedId = selected;
      if (_selectedId == null || !_entries.any((entry) => entry.id == _selectedId)) {
        _selectedId = _entries.isNotEmpty ? _entries.first.id : null;
      }
      _loading = false;
    });
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _persistConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final uris = _entries.map((entry) => entry.uri).toList();
    await prefs.setStringList(_prefsKeyConnections, uris);
    if (_selectedId != null) {
      await prefs.setString(_prefsKeySelected, _selectedId!);
    } else {
      await prefs.remove(_prefsKeySelected);
    }
  }

  ConnectionEntry? _selectedEntry() {
    for (final entry in _entries) {
      if (entry.id == _selectedId) {
        return entry;
      }
    }
    return null;
  }

  ConnectionEntry? _activeEntry() {
    for (final entry in _entries) {
      if (entry.id == _activeId) {
        return entry;
      }
    }
    return null;
  }

  void _selectEntry(ConnectionEntry entry) {
    setState(() {
      _selectedId = entry.id;
    });
    _persistConnections();
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      final result = await _showAddDialog();
      if (result != null && result.isNotEmpty) {
        _addEntryFromUri(result);
      }
      return;
    }
    _addEntryFromUri(text);
  }

  Future<String?> _showAddDialog({
    String? initial,
    String title = 'Add connection',
    String actionLabel = 'Add',
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'pingtunnel://host?key=123&lport=1080&mode=vpn',
            ),
            minLines: 1,
            maxLines: 3,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );

    return result;
  }

  void _addEntryFromUri(String uriText) {
    try {
      final config = TunnelConfig.parse(uriText);
      final existingIndex = _entries.indexWhere((entry) => entry.uri == uriText);
      setState(() {
        if (existingIndex >= 0) {
          final entry = _entries.removeAt(existingIndex);
          _entries.insert(0, entry);
          _selectedId = entry.id;
        } else {
          final entry = ConnectionEntry(
            uri: uriText,
            config: config,
          );
          _entries.insert(0, entry);
          _selectedId = entry.id;
        }
      });
      _persistConnections();
      _scheduleLinuxTrayRefresh();
      _showMessage('Connection added');
    } catch (err) {
      _showMessage('Invalid URI: $err');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openDetails(ConnectionEntry entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConnectionDetailPage(
          entry: entry,
          controller: _controller,
          activeId: _activeId,
          onActiveChanged: (id) {
            setState(() {
              _activeId = id;
            });
            _scheduleLinuxTrayRefresh();
          },
          onSave: (updated, {showMessage = true}) =>
              _updateEntry(entry, updated, showMessage: showMessage),
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _updateEntry(
    ConnectionEntry original,
    ConnectionEntry updated, {
    bool showMessage = true,
  }) {
    final existingIndex = _entries.indexWhere((item) => item.uri == updated.uri);
    setState(() {
      final index = _entries.indexWhere((item) => item.id == original.id);
      final duplicateId =
          (existingIndex >= 0 && existingIndex != index) ? _entries[existingIndex].id : null;
      if (index >= 0) {
        _entries[index] = updated;
      }
      if (duplicateId != null) {
        _entries.removeWhere((item) => item.id == duplicateId);
        if (_selectedId == duplicateId) {
          _selectedId = updated.id;
        }
        if (_activeId == duplicateId) {
          _activeId = updated.id;
        }
      }
      if (_selectedId == original.id) {
        _selectedId = updated.id;
      }
      if (_activeId == original.id) {
        _activeId = updated.id;
      }
    });
    _persistConnections();
    _scheduleLinuxTrayRefresh();
    if (showMessage) {
      _showMessage('Connection updated');
    }
  }

  Future<void> _connectSelected() async {
    final entry = _selectedEntry();
    if (entry == null) {
      _showMessage('Select a connection first');
      return;
    }
    try {
      if (_activeId != null && _activeId != entry.id) {
        await _controller.stop();
      }
      await _controller.start(entry.config);
      setState(() {
        _activeId = entry.id;
      });
      _scheduleLinuxTrayRefresh();
    } catch (err) {
      _showMessage(err.toString());
    }
  }

  Future<void> _disconnectActive({bool showMessage = true}) async {
    if (_activeId == null) {
      if (showMessage) {
        _showMessage('Nothing is connected');
      }
      return;
    }
    await _controller.stop();
    setState(() {
      _activeId = null;
    });
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _testSelected() async {
    final entry = _selectedEntry();
    if (entry == null) {
      _showMessage('Select a connection first');
      return;
    }
    if (_activeId != entry.id || _controller.status != TunnelStatus.connected) {
      _showMessage('Connect first');
      return;
    }
    setState(() {
      _testing = true;
    });
    try {
      final result = await _controller.testConnection(entry.config);
      setState(() {
        _lastProbeError = null;
        _lastProbeAt = DateTime.now();
      });
      _showMessage('Test OK: $result');
    } catch (err) {
      setState(() {
        _lastProbeError = err.toString();
        _lastProbeAt = DateTime.now();
      });
      _showMessage('Test failed: $err');
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  Future<bool> _confirmDelete(ConnectionEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete connection?'),
        content: Text(entry.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteEntry(ConnectionEntry entry) async {
    if (_activeId == entry.id) {
      _showMessage('Disconnect to delete');
      return;
    }
    final confirmed = await _confirmDelete(entry);
    if (confirmed) {
      _removeEntry(entry);
      _persistConnections();
    }
  }

  void _removeEntry(ConnectionEntry entry) {
    setState(() {
      _entries.removeWhere((item) => item.id == entry.id);
      if (_activeId == entry.id) {
        _activeId = null;
      }
      if (_selectedId == entry.id) {
        _selectedId = _entries.isNotEmpty ? _entries.first.id : null;
      }
    });
    _scheduleLinuxTrayRefresh();
  }

  IconData _themeModeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return Icons.light_mode;
      case ThemeMode.dark:
        return Icons.dark_mode;
      case ThemeMode.system:
        return Icons.brightness_auto;
    }
  }

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'System';
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final selected = _selectedEntry();
    final active = _activeEntry();
    final isSelectedActive = selected != null && selected.id == _activeId;
    final status = isSelectedActive ? _controller.status : TunnelStatus.disconnected;
    final canTest = isSelectedActive && status == TunnelStatus.connected && !_testing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [
          PopupMenuButton<ThemeMode>(
            initialValue: widget.themeMode,
            tooltip: 'Theme',
            onSelected: widget.onThemeModeChanged,
            itemBuilder: (context) => <PopupMenuEntry<ThemeMode>>[
              for (final mode in ThemeMode.values)
                PopupMenuItem<ThemeMode>(
                  value: mode,
                  child: Row(
                    children: [
                      Icon(_themeModeIcon(mode), size: 18),
                      const SizedBox(width: 8),
                      Text(_themeModeLabel(mode)),
                    ],
                  ),
                ),
            ],
            icon: Icon(_themeModeIcon(widget.themeMode)),
          ),
          IconButton(
            onPressed: _addFromClipboard,
            icon: const Icon(Icons.content_paste),
            tooltip: 'Paste URI',
          ),
          IconButton(
            onPressed: () async {
              final result = await _showAddDialog();
              if (result != null && result.isNotEmpty) {
                _addEntryFromUri(result);
              }
            },
            icon: const Icon(Icons.add),
            tooltip: 'Add URI',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? _EmptyState(onPaste: _addFromClipboard)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
                  itemCount: entries.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final isActive = _activeId == entry.id;
                    final statusForTile = isActive ? _controller.status : TunnelStatus.disconnected;
                    return _ConnectionTile(
                      entry: entry,
                      isActive: isActive,
                      isSelected: _selectedId == entry.id,
                      status: statusForTile,
                      onSelect: () => _selectEntry(entry),
                      onDetails: () => _openDetails(entry),
                      onDelete: () => _deleteEntry(entry),
                    );
                  },
                ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected == null ? 'Select a connection' : 'Selected: ${selected.title}',
                      style: Theme.of(context).textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (active != null && active.id != selected?.id) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Active: ${active.title}',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.6)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: FilledButton.tonalIcon(
                            onPressed: canTest ? _testSelected : null,
                            icon: const Icon(Icons.network_check),
                            label: Text(_testing ? 'Testing...' : 'Test'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 5,
                          child: SizedBox(
                            height: 52,
                            child: FilledButton.icon(
                              onPressed: status == TunnelStatus.connecting
                                  ? null
                                  : (isSelectedActive ? _disconnectActive : _connectSelected),
                              icon: Icon(isSelectedActive ? Icons.stop : Icons.play_arrow),
                              label: Text(status == TunnelStatus.connecting
                                  ? 'Connecting...'
                                  : (isSelectedActive ? 'Disconnect' : 'Connect')),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_lastProbeAt != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _lastProbeError != null ? 'Last test failed' : 'Last test OK',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.6)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPaste});

  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.link, size: 48, color: colors.outline),
            const SizedBox(height: 16),
            Text(
              'No connections yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Paste a pingtunnel URI to get started.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste URI'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.entry,
    required this.isActive,
    required this.isSelected,
    required this.status,
    required this.onSelect,
    required this.onDetails,
    required this.onDelete,
  });

  final ConnectionEntry entry;
  final bool isActive;
  final bool isSelected;
  final TunnelStatus status;
  final VoidCallback onSelect;
  final VoidCallback onDetails;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitle = StringBuffer()
      ..write(entry.config.mode == TunnelMode.vpn ? 'VPN' : 'Proxy')
      ..write('  •  ')
      ..write('Local ${entry.config.localSocksPort}');

    if (entry.config.serverPort != null) {
      subtitle.write('  •  Server ${entry.config.serverPort}');
    }

    final borderColor = isSelected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outlineVariant;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderColor, width: isSelected ? 1.4 : 1),
      ),
      child: ListTile(
        onTap: onSelect,
        selected: isSelected,
        title: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle.toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: _StatusChip(isActive: isActive, status: status),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: isActive ? null : onDelete,
              icon: const Icon(Icons.delete_outline),
              tooltip: isActive ? 'Disconnect to delete' : 'Delete',
            ),
            IconButton(
              onPressed: onDetails,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isActive, required this.status});

  final bool isActive;
  final TunnelStatus status;

  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    final colors = Theme.of(context).colorScheme;

    if (!isActive) {
      label = 'Idle';
      color = colors.outline;
    } else {
      switch (status) {
        case TunnelStatus.connected:
          label = 'Connected';
          color = colors.primary;
          break;
        case TunnelStatus.connecting:
          label = 'Connecting';
          color = colors.secondary;
          break;
        case TunnelStatus.error:
          label = 'Error';
          color = colors.error;
          break;
        case TunnelStatus.disconnected:
          label = 'Disconnected';
          color = colors.outline;
          break;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class ConnectionDetailPage extends StatefulWidget {
  const ConnectionDetailPage({
    super.key,
    required this.entry,
    required this.controller,
    required this.activeId,
    required this.onActiveChanged,
    required this.onSave,
  });

  final ConnectionEntry entry;
  final TunnelController controller;
  final String? activeId;
  final ValueChanged<String?> onActiveChanged;
  final SaveConnection onSave;

  @override
  State<ConnectionDetailPage> createState() => _ConnectionDetailPageState();
}

class _ConnectionDetailPageState extends State<ConnectionDetailPage> {
  Timer? _uiTimer;
  bool _testing = false;
  String? _lastProbeResult;
  String? _lastProbeError;
  DateTime? _lastProbeAt;
  bool _isActive = false;
  bool _dirty = false;
  String? _error;
  final Uri _ipCheckUri = Uri.parse('https://ifconfig.me');
  final _formKey = GlobalKey<FormState>();
  late ConnectionEntry _entry;
  late final TextEditingController _hostController;
  late final TextEditingController _keyController;
  late final TextEditingController _localPortController;
  late final TextEditingController _serverPortController;
  late final TextEditingController _encryptKeyController;
  late TunnelMode _mode;
  late String _encryptMode;

  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
    _isActive = widget.activeId == _entry.id;
    _mode = _entry.config.mode;
    _hostController = TextEditingController(text: _entry.config.serverHost);
    _keyController = TextEditingController(text: _entry.config.key?.toString() ?? '');
    _localPortController =
        TextEditingController(text: _entry.config.localSocksPort.toString());
    _serverPortController =
        TextEditingController(text: _entry.config.serverPort?.toString() ?? '');
    _encryptKeyController = TextEditingController(text: _entry.config.encryptKey ?? '');
    _encryptMode = _entry.config.encryptMode ?? 'none';
    _hostController.addListener(_markDirty);
    _keyController.addListener(_markDirty);
    _localPortController.addListener(_markDirty);
    _serverPortController.addListener(_markDirty);
    _encryptKeyController.addListener(_markDirty);
    _startUiTimer();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _hostController.dispose();
    _keyController.dispose();
    _localPortController.dispose();
    _serverPortController.dispose();
    _encryptKeyController.dispose();
    super.dispose();
  }

  void _startUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _markDirty() {
    if (_isActive || _dirty) return;
    setState(() {
      _dirty = true;
    });
  }

  Future<bool> _applyEditsIfNeeded({bool showMessage = false}) async {
    if (!_dirty) return true;
    if (_isActive) return false;
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) {
      _showMessage('Fix the fields before continuing');
      return false;
    }
    final config = _buildConfigFromFields();
    if (config == null) {
      _showMessage('Fix the fields before continuing');
      return false;
    }
    final uri = _buildUri(config);
    final updated = ConnectionEntry(uri: uri, config: config);
    widget.onSave(updated, showMessage: showMessage);
    setState(() {
      _entry = updated;
      _dirty = false;
    });
    return true;
  }

  Future<void> _handlePop() async {
    if (!_dirty) return;
    final ok = await _applyEditsIfNeeded(showMessage: true);
    if (ok && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _connect() async {
    final applied = await _applyEditsIfNeeded();
    if (!applied) return;
    setState(() {
      _error = null;
    });
    try {
      if (!_isActive && widget.controller.status == TunnelStatus.connected) {
        await widget.controller.stop();
      }
      await widget.controller.start(_entry.config);
      setState(() {
        _isActive = true;
      });
      widget.onActiveChanged(_entry.id);
    } catch (err) {
      setState(() {
        _error = err.toString();
      });
    }
  }

  Future<void> _disconnect() async {
    await widget.controller.stop();
    widget.onActiveChanged(null);
    setState(() {
      _isActive = false;
    });
  }

  Future<void> _testConnection() async {
    final applied = await _applyEditsIfNeeded();
    if (!applied) return;
    if (!_isActive) {
      _showMessage('Connect first');
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final result = await widget.controller.testConnection(_entry.config);
      setState(() {
        _lastProbeResult = result;
        _lastProbeError = null;
        _lastProbeAt = DateTime.now();
      });
    } catch (err) {
      setState(() {
        _lastProbeError = err.toString();
        _lastProbeResult = null;
        _lastProbeAt = DateTime.now();
      });
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  Future<void> _copyUri() async {
    await Clipboard.setData(ClipboardData(text: _entry.uri));
    _showMessage('URI copied');
  }

  int? _parsePort(String input, {bool optional = false}) {
    if (input.isEmpty) return optional ? null : 1080;
    final value = int.tryParse(input);
    if (value == null || value < 1 || value > 65535) return null;
    return value;
  }

  TunnelConfig? _buildConfigFromFields() {
    final host = _hostController.text.trim();
    final keyText = _keyController.text.trim();
    final key = keyText.isEmpty ? null : int.tryParse(keyText);
    final localPort = _parsePort(_localPortController.text.trim());
    final serverPort = _parsePort(_serverPortController.text.trim(), optional: true);
    final encryptMode = _encryptMode == 'none' ? null : _encryptMode;
    final encryptKey = _encryptKeyController.text.trim().isEmpty
        ? null
        : _encryptKeyController.text.trim();

    if (host.isEmpty || localPort == null) {
      return null;
    }
    if (_encryptMode == 'none' && key == null) {
      return null;
    }
    if (_encryptMode != 'none' && encryptKey == null) {
      return null;
    }

    final effectiveKey = _encryptMode == 'none' ? key : null;

    return TunnelConfig(
      serverHost: host,
      serverPort: serverPort,
      localSocksPort: localPort,
      key: effectiveKey,
      mode: _mode,
      encryptMode: encryptMode,
      encryptKey: encryptKey,
    );
  }

  String _buildUri(TunnelConfig config) {
    return buildConnectionUri(config);
  }

  Future<void> _saveEdits() async {
    await _applyEditsIfNeeded(showMessage: true);
  }

  Future<void> _openIpCheck() async {
    final ok = await launchUrl(_ipCheckUri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      _showMessage('Could not open browser');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final status = _isActive ? widget.controller.status : TunnelStatus.disconnected;
    final errorText = _error ?? widget.controller.lastError;
    final logLines = _isActive ? widget.controller.logBuffer.lines : <String>[];

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handlePop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_entry.title),
          actions: [
            IconButton(
              onPressed: _copyUri,
              icon: const Icon(Icons.copy),
              tooltip: 'Copy URI',
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            _StatusCard(status: status, error: errorText),
            const SizedBox(height: 12),
          _DetailsFormCard(
            formKey: _formKey,
            hostController: _hostController,
            keyController: _keyController,
            localPortController: _localPortController,
            serverPortController: _serverPortController,
            encryptKeyController: _encryptKeyController,
            mode: _mode,
            onModeChanged: (value) {
              if (_isActive) return;
              setState(() {
                _mode = value;
                _dirty = true;
              });
            },
            encryptMode: _encryptMode,
            onEncryptModeChanged: (value) {
              if (_isActive) return;
              setState(() {
                _encryptMode = value;
                _dirty = true;
              });
            },
            readOnly: _isActive,
            onSave: _saveEdits,
          ),
            const SizedBox(height: 12),
            _DiagnosticsCard(
              lastProbeResult: _lastProbeResult,
              lastProbeError: _lastProbeError,
              lastProbeAt: _lastProbeAt,
              onOpenIpCheck: _openIpCheck,
            ),
            const SizedBox(height: 12),
            _LogsCard(lines: logLines),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: FilledButton.tonalIcon(
                    onPressed: _testing ? null : _testConnection,
                    icon: const Icon(Icons.network_check),
                    label: Text(_testing ? 'Testing...' : 'Test'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: status == TunnelStatus.connecting
                          ? null
                          : (_isActive ? _disconnect : _connect),
                      icon: Icon(_isActive ? Icons.stop : Icons.play_arrow),
                      label: Text(_isActive ? 'Disconnect' : 'Connect'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.error});

  final TunnelStatus status;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final config = _statusConfig(status, colorScheme);

    return SizedBox(
      height: 72,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(config.icon, color: config.color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      config.title,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      error?.isNotEmpty == true ? error! : config.subtitle,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.7)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _StatusChip(isActive: true, status: status),
            ],
          ),
        ),
      ),
    );
  }

  _StatusVisual _statusConfig(TunnelStatus status, ColorScheme colors) {
    switch (status) {
      case TunnelStatus.connected:
        return _StatusVisual(
          title: 'Connected',
          subtitle: 'Tunnel is active',
          icon: Icons.check_circle,
          color: colors.primary,
        );
      case TunnelStatus.connecting:
        return _StatusVisual(
          title: 'Connecting',
          subtitle: 'Working...',
          icon: Icons.hourglass_top,
          color: colors.secondary,
        );
      case TunnelStatus.error:
        return _StatusVisual(
          title: 'Error',
          subtitle: 'Check logs',
          icon: Icons.error,
          color: colors.error,
        );
      case TunnelStatus.disconnected:
        return _StatusVisual(
          title: 'Disconnected',
          subtitle: 'Not connected',
          icon: Icons.radio_button_unchecked,
          color: colors.outline,
        );
    }
  }
}

class _StatusVisual {
  _StatusVisual({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
}

class _DetailsFormCard extends StatelessWidget {
  const _DetailsFormCard({
    required this.formKey,
    required this.hostController,
    required this.keyController,
    required this.localPortController,
    required this.serverPortController,
    required this.encryptKeyController,
    required this.mode,
    required this.onModeChanged,
    required this.encryptMode,
    required this.onEncryptModeChanged,
    required this.readOnly,
    required this.onSave,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController hostController;
  final TextEditingController keyController;
  final TextEditingController localPortController;
  final TextEditingController serverPortController;
  final TextEditingController encryptKeyController;
  final TunnelMode mode;
  final ValueChanged<TunnelMode> onModeChanged;
  final String encryptMode;
  final ValueChanged<String> onEncryptModeChanged;
  final bool readOnly;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Details', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  FilledButton(
                    onPressed: readOnly ? null : onSave,
                    child: const Text('Save'),
                  ),
                ],
              ),
              if (readOnly) ...[
                const SizedBox(height: 6),
                Text(
                  'Disconnect to edit',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: hostController,
                enabled: !readOnly,
                decoration: const InputDecoration(labelText: 'Host'),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Host is required';
                  if (text.contains('://')) return 'Host only, no scheme';
                  if (text.contains('/') || text.contains(' ')) return 'Invalid host';
                  if (text.contains(':')) return 'Use Server port';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TunnelMode>(
                key: ValueKey(mode),
                initialValue: mode,
                decoration: const InputDecoration(labelText: 'Mode'),
                items: const [
                  DropdownMenuItem(value: TunnelMode.proxy, child: Text('Proxy')),
                  DropdownMenuItem(value: TunnelMode.vpn, child: Text('VPN')),
                ],
                onChanged: readOnly ? null : (value) => onModeChanged(value ?? mode),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: keyController,
                enabled: !readOnly && encryptMode == 'none',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Key'),
                validator: (value) {
                  if (encryptMode != 'none') return null;
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Key is required';
                  if (int.tryParse(text) == null) return 'Key must be a number';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(encryptMode),
                initialValue: encryptMode,
                decoration: const InputDecoration(labelText: 'Encryption'),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('None')),
                  DropdownMenuItem(value: 'aes128', child: Text('AES-128')),
                  DropdownMenuItem(value: 'aes256', child: Text('AES-256')),
                  DropdownMenuItem(value: 'chacha20', child: Text('ChaCha20')),
                ],
                onChanged: readOnly ? null : (value) => onEncryptModeChanged(value ?? 'none'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: encryptKeyController,
                enabled: !readOnly && encryptMode != 'none',
                decoration: const InputDecoration(labelText: 'Encryption key'),
                validator: (value) {
                  if (encryptMode == 'none') return null;
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Encryption key is required';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: localPortController,
                enabled: !readOnly,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Local port'),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Local port is required';
                  final parsed = int.tryParse(text);
                  if (parsed == null || parsed < 1 || parsed > 65535) {
                    return 'Port must be 1-65535';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: serverPortController,
                enabled: !readOnly,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Server port (optional)'),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return null;
                  final parsed = int.tryParse(text);
                  if (parsed == null || parsed < 1 || parsed > 65535) {
                    return 'Port must be 1-65535';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({
    required this.lastProbeResult,
    required this.lastProbeError,
    required this.lastProbeAt,
    required this.onOpenIpCheck,
  });

  final String? lastProbeResult;
  final String? lastProbeError;
  final DateTime? lastProbeAt;
  final VoidCallback onOpenIpCheck;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final probeStatus = lastProbeError != null
        ? 'Failed'
        : lastProbeResult != null
            ? 'OK'
            : 'Not tested';
    final probeDetail = lastProbeError ?? lastProbeResult ?? 'Run test to verify.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _InfoRow(
              label: 'Test status',
              value: probeStatus,
              valueColor: lastProbeError != null
                  ? colorScheme.error
                  : lastProbeResult != null
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 6),
            Text(
              probeDetail,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 10),
            _InfoRow(
              label: 'Last test',
              value: lastProbeAt == null
                  ? '—'
                  : '${lastProbeAt!.hour.toString().padLeft(2, '0')}:${lastProbeAt!.minute.toString().padLeft(2, '0')}:${lastProbeAt!.second.toString().padLeft(2, '0')}',
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: onOpenIpCheck,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open IP check in browser'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogsCard extends StatelessWidget {
  const _LogsCard({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final text = lines.isEmpty ? 'No logs yet.' : lines.join('\n');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Logs', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(minHeight: 120),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6));

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 360;
        final valueStyle = Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: valueColor ?? Theme.of(context).colorScheme.onSurface);
        if (isNarrow) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: labelStyle),
                const SizedBox(height: 2),
                Text(value, style: valueStyle),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(width: 110, child: Text(label, style: labelStyle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: valueStyle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
