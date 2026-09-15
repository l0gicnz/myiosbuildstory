import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../image_processing/crop_service.dart';
import '../inspection/crop_preview_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryItem {
  const _HistoryItem({
    required this.cropPath,
    required this.selection,
    required this.createdAt,
    required this.accepted,
    required this.notes,
    required this.jobName,
    required this.measurement,
    required this.location,
  });

  final String cropPath;
  final CropSelection selection;
  final DateTime createdAt;
  final bool accepted;
  final String notes;
  final String jobName;
  final String? measurement;
  final Map<String, Object?>? location;
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<_HistoryItem> _items = const [];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final documents = await getApplicationDocumentsDirectory();
      final directory = Directory('${documents.path}/captures');
      if (!await directory.exists()) {
        if (mounted) setState(() => _items = const []);
        return;
      }
      final items = <_HistoryItem>[];
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.png.json')) continue;
        try {
          final raw = jsonDecode(await entity.readAsString());
          if (raw is! Map<String, dynamic>) continue;
          final cropPath = raw['cropPath'] as String?;
          if (cropPath == null || !await File(cropPath).exists()) continue;
          final selection = CropSelection(
            sourceWidth: _int(raw, 'sourceWidth'),
            sourceHeight: _int(raw, 'sourceHeight'),
            selectedX: _int(raw, 'selectedX'),
            selectedY: _int(raw, 'selectedY'),
            cropX: _int(raw, 'cropX'),
            cropY: _int(raw, 'cropY'),
            cropWidth: _int(raw, 'cropWidth'),
            cropHeight: _int(raw, 'cropHeight'),
          );
          var notes = raw['notes'] as String? ?? '';
          var jobName = raw['jobName'] as String? ?? '';
          var location = _locationMap(raw['location']);
          final acceptedFile = File('$cropPath.accepted.json');
          String? measurement;
          final accepted = await acceptedFile.exists();
          if (accepted) {
            try {
              final acceptedRaw = jsonDecode(await acceptedFile.readAsString());
              final width = acceptedRaw is Map<String, dynamic>
                  ? acceptedRaw['displayedWidth']
                  : null;
              final unit = acceptedRaw is Map<String, dynamic>
                  ? acceptedRaw['measurementUnit']
                  : null;
              if (acceptedRaw is Map<String, dynamic>) {
                notes = acceptedRaw['notes'] as String? ?? notes;
                jobName = acceptedRaw['jobName'] as String? ?? jobName;
                location ??= _locationMap(acceptedRaw['location']);
              }
              if (width is num) {
                measurement =
                    '${width.toStringAsFixed(unit == 'inches' ? 2 : 1)} '
                    '${unit == 'inches' ? 'in' : 'mm'}';
              }
            } catch (_) {}
          }
          items.add(
            _HistoryItem(
              cropPath: cropPath,
              selection: selection,
              createdAt: entity.statSync().modified,
              accepted: accepted,
              notes: notes,
              jobName: jobName,
              measurement: measurement,
              location: location,
            ),
          );
        } catch (_) {
          // Ignore incomplete records and keep the rest of the history usable.
        }
      }
      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load history: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static int _int(Map<String, dynamic> raw, String key) {
    final value = raw[key];
    if (value is! num) throw FormatException('Invalid history field: $key');
    return value.toInt();
  }

  static Map<String, Object?>? _locationMap(Object? value) {
    if (value is! Map) return null;
    final latitude = value['latitude'];
    final longitude = value['longitude'];
    if (latitude is! num || longitude is! num) return null;
    return Map<String, Object?>.from(value);
  }

  static String _locationLabel(Map<String, Object?> value) {
    final latitude = value['latitude'] as num;
    final longitude = value['longitude'] as num;
    final accuracy = value['accuracyMetres'];
    final suffix = accuracy is num
        ? ' (+/-${accuracy.toStringAsFixed(0)} m)'
        : '';
    return '${latitude.toStringAsFixed(6)}, '
        '${longitude.toStringAsFixed(6)}$suffix';
  }

  Future<void> _open(_HistoryItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CropPreviewScreen(
          path: item.cropPath,
          selection: item.selection,
          jobName: item.jobName,
          location: item.location,
          initialNotes: item.notes,
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _delete(_HistoryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete inspection?'),
        content: const Text(
          'The crop, metadata, and accepted mask will be removed.',
        ),
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
    if (confirmed != true) return;
    for (final path in [
      item.cropPath,
      '${item.cropPath}.json',
      '${item.cropPath}.accepted-mask.png',
      '${item.cropPath}.accepted.json',
      '${item.cropPath}.report.txt',
      '${item.cropPath}.report.json',
      '${item.cropPath}.report.csv',
    ]) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // A missing optional sidecar should not prevent the other files from
        // being removed.
      }
    }
    if (mounted) {
      setState(() => _items = _items.where((x) => x != item).toList());
    }
  }

  Future<void> _deleteAll() async {
    if (_items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all inspections?'),
        content: Text('${_items.length} saved inspections will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final item in _items) {
      for (final path in [
        item.cropPath,
        '${item.cropPath}.json',
        '${item.cropPath}.accepted-mask.png',
        '${item.cropPath}.accepted.json',
        '${item.cropPath}.report.txt',
        '${item.cropPath}.report.json',
        '${item.cropPath}.report.csv',
      ]) {
        try {
          await File(path).delete();
        } on FileSystemException {
          // Continue cleaning the remaining records.
        }
      }
    }
    if (mounted) setState(() => _items = const []);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Inspection history'),
      actions: [
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'delete') _deleteAll();
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'delete',
              child: Text('Delete all inspections'),
            ),
          ],
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(child: Text(_error!))
        : Column(
            children: [
              if (_items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search job names or notes',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              Expanded(
                child: _filtered.isEmpty
                    ? Center(
                        child: Text(
                          _items.isEmpty
                              ? 'No saved inspections yet.'
                              : 'No inspections match the search.',
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _filtered.length,
                          itemBuilder: (context, index) {
                            final item = _filtered[index];
                            return Card(
                              clipBehavior: Clip.antiAlias,
                              child: ListTile(
                                contentPadding: const EdgeInsets.all(8),
                                leading: SizedBox.square(
                                  dimension: 72,
                                  child: Image.file(
                                    File(item.cropPath),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                title: Text(
                                  item.jobName.isEmpty
                                      ? '${item.createdAt.toLocal()}'
                                            .split('.')
                                            .first
                                      : item.jobName,
                                ),
                                subtitle: Text(
                                  [
                                    if (item.jobName.isNotEmpty)
                                      item.createdAt
                                          .toLocal()
                                          .toString()
                                          .split('.')
                                          .first,
                                    'Pixel (${item.selection.selectedX}, ${item.selection.selectedY})',
                                    item.accepted
                                        ? 'Detection accepted'
                                        : 'Not yet accepted',
                                    if (item.measurement case final value?)
                                      'Measured width: $value',
                                    if (item.location case final value?)
                                      'Location: ${_locationLabel(value)}',
                                    if (item.notes.isNotEmpty) item.notes,
                                  ].join('\n'),
                                ),
                                isThreeLine:
                                    item.notes.isNotEmpty ||
                                    item.jobName.isNotEmpty,
                                onTap: () => _open(item),
                                trailing: IconButton(
                                  tooltip: 'Delete inspection',
                                  onPressed: () => _delete(item),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
  );

  List<_HistoryItem> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _items;
    return _items
        .where(
          (item) =>
              item.jobName.toLowerCase().contains(query) ||
              item.notes.toLowerCase().contains(query),
        )
        .toList();
  }
}
