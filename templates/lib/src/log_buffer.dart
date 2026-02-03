class LogBuffer {
  LogBuffer({this.maxLines = 200});

  final int maxLines;
  final List<String> _lines = <String>[];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String line) {
    if (line.isEmpty) return;
    _lines.add(line);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
  }

  void clear() {
    _lines.clear();
  }
}
