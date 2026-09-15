import 'dart:io';

import 'package:flutter/material.dart';

import '../image_processing/crop_service.dart';
import 'interactive_image.dart';
import 'crop_preview_screen.dart';
import '../settings/app_settings.dart';

class InspectionScreen extends StatefulWidget {
  const InspectionScreen({
    super.key,
    required this.source,
    this.jobName,
    this.location,
  });
  final InspectionImage source;
  final String? jobName;
  final Map<String, Object?>? location;
  @override
  State<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends State<InspectionScreen> {
  CropSelection? _selection;
  bool _busy = false;
  Future<void> _openCrop() async {
    final selection = _selection;
    if (selection == null || _busy) return;
    setState(() => _busy = true);
    try {
      final path = await CropService.extract(
        widget.source,
        selection,
        jobName: widget.jobName,
        location: widget.location,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CropPreviewScreen(
            path: path,
            selection: selection,
            jobName: widget.jobName,
          ),
        ),
      );
      if (!AppSettings.instance.retainOriginalPhotos) {
        for (final path in [widget.source.originalPath, widget.source.path]) {
          try {
            await File(path).delete();
          } on FileSystemException {
            // The crop remains available even if an optional source file is
            // already gone.
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create crop: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.jobName?.isNotEmpty == true ? widget.jobName! : 'Inspect photo',
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Retake'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '${widget.source.width} x ${widget.source.height} source pixels\nPinch to zoom - Drag to pan - Tap a conductor',
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: InteractiveImage(
              source: widget.source,
              selection: _selection,
              onSelect: (point) {
                if (_busy) return;
                setState(
                  () => _selection = CropService.calculate(
                    width: widget.source.width,
                    height: widget.source.height,
                    x: point.dx,
                    y: point.dy,
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (_selection case final s?)
                  Text(selectionDescription(s), textAlign: TextAlign.center),
                if (widget.source.width < 512 || widget.source.height < 512)
                  const Text(
                    'Source is smaller than 512 pixels; crop uses available pixels.',
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _selection == null || _busy ? null : _openCrop,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.crop),
                  label: Text(_busy ? 'Extracting...' : 'Open crop'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String selectionDescription(CropSelection s) =>
    'Selected pixel: (${s.selectedX}, ${s.selectedY})\n'
    'Crop origin: (${s.cropX}, ${s.cropY}) - ${s.cropWidth} x ${s.cropHeight} px';
