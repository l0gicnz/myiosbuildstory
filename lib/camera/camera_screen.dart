import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../image_processing/crop_service.dart';
import '../history/history_screen.dart';
import '../inspection/inspection_screen.dart';
import '../settings/app_settings.dart';
import '../settings/settings_screen.dart';
import 'camera_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  final _service = CameraService();
  final _picker = ImagePicker();
  CameraController? _controller;
  Future<void> _queue = Future.value();
  bool _active = true, _inspecting = false, _busy = false;
  double _zoom = 1, _zoomAtGestureStart = 1, _minZoom = 1, _maxZoom = 1;
  FlashMode _flashMode = FlashMode.off;
  Offset? _focusPoint;
  Timer? _focusTimer;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncCamera();
  }

  // Serialize opens/closes, including permission-dialog lifecycle events.
  void _syncCamera() {
    _queue = _queue.then((_) async {
      final old = _controller;
      _controller = null;
      if (mounted) setState(() {});
      await old?.dispose();
      if (!mounted || !_active || _inspecting) return;
      try {
        final next = await _service.open();
        if (!mounted || !_active || _inspecting) {
          await next.dispose();
          return;
        }
        final minZoom = await next.getMinZoomLevel();
        final maxZoom = await next.getMaxZoomLevel();
        setState(() {
          _controller = next;
          _minZoom = minZoom;
          _maxZoom = maxZoom;
          _zoom = minZoom;
          _flashMode = FlashMode.off;
          _error = null;
        });
      } catch (e) {
        if (mounted) {
          setState(
            () => _error =
                'Camera unavailable: $e\nCheck camera permission in Settings, then retry.',
          );
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _syncCamera();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? path;
    try {
      path = await _service.capture(controller);
      if (!mounted) return;
      final jobName = await _promptJobName();
      if (!mounted || jobName == null) {
        await _discardCapture(path);
        return;
      }
      final location = await _locationSafely();
      await _openImage(path, jobName: jobName, location: location);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not prepare photo: $e')));
      }
    } finally {
      _inspecting = false;
      if (mounted) {
        setState(() => _busy = false);
        _syncCamera();
      }
    }
  }

  Future<void> _discardCapture(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // A failed cleanup should not hide the user's cancellation.
    }
  }

  Future<void> _pickExisting() async {
    if (_busy) return;
    final jobName = await _promptJobName();
    if (!mounted || jobName == null) return;
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      setState(() {
        _busy = true;
        _error = null;
      });
      final path = await _service.importImage(picked.path);
      final location = await _locationSafely();
      await _openImage(path, jobName: jobName, location: location);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open image: $e')));
      }
    } finally {
      _inspecting = false;
      if (mounted) {
        setState(() => _busy = false);
        _syncCamera();
      }
    }
  }

  Future<String?> _promptJobName() async {
    final controller = TextEditingController();
    final value = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New inspection'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Job or site name (optional)',
            hintText: 'e.g. Main Street pole 12',
          ),
          onSubmitted: (_) => Navigator.of(context).pop(controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value?.trim();
  }

  Future<Map<String, Object?>?> _locationSafely() async {
    try {
      return await _service.currentLocation();
    } catch (_) {
      return null;
    }
  }

  Future<void> _openImage(
    String path, {
    String? jobName,
    Map<String, Object?>? location,
  }) async {
    _inspecting = true;
    _syncCamera();
    final source = await CropService.prepare(path);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InspectionScreen(
          source: source,
          jobName: jobName,
          location: location,
        ),
      ),
    );
  }

  Future<void> _setZoom(double value) async {
    final controller = _controller;
    if (controller == null) return;
    final zoom = value.clamp(_minZoom, _maxZoom).toDouble();
    try {
      await controller.setZoomLevel(zoom);
      if (mounted) setState(() => _zoom = zoom);
    } catch (_) {
      // Some camera backends expose zoom limits but reject a transient update.
    }
  }

  Future<void> _focusAt(Offset position, Size size) async {
    final controller = _controller;
    if (controller == null || size.width <= 0 || size.height <= 0) return;
    _focusTimer?.cancel();
    if (mounted) setState(() => _focusPoint = position);
    _focusTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    try {
      await controller.setFocusPoint(
        Offset(
          (position.dx / size.width).clamp(0, 1),
          (position.dy / size.height).clamp(0, 1),
        ),
      );
    } catch (_) {
      // Fixed-focus or restricted camera backends may not support tap focus.
    }
  }

  Future<void> _cycleFlash() async {
    final controller = _controller;
    if (controller == null) return;
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Flash control is unavailable.')),
        );
      }
    }
  }

  Widget _buildCameraPreview(Size size) {
    final controller = _controller!;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) => _zoomAtGestureStart = _zoom,
          onScaleUpdate: (details) {
            if (details.scale != 1) {
              _setZoom(_zoomAtGestureStart * details.scale);
            }
          },
          onTapUp: (details) => _focusAt(details.localPosition, size),
          child: CameraPreview(controller),
        ),
        if (AppSettings.instance.showCameraGrid)
          const IgnorePointer(child: _CameraGrid()),
        if (_focusPoint case final point?)
          Positioned(
            left: point.dx - 28,
            top: point.dy - 28,
            child: IgnorePointer(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.yellowAccent, width: 2),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        Positioned(
          left: 12,
          top: 12,
          child: Row(
            children: [
              IconButton.filledTonal(
                tooltip: 'Flash: ${_flashMode.name}',
                onPressed: _cycleFlash,
                icon: Icon(switch (_flashMode) {
                  FlashMode.off => Icons.flash_off,
                  FlashMode.auto => Icons.flash_auto,
                  _ => Icons.flash_on,
                }),
              ),
              if (_maxZoom > _minZoom) ...[
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Reset camera zoom',
                  onPressed: () => _setZoom(_minZoom),
                  icon: const Icon(Icons.zoom_out_map),
                ),
              ],
            ],
          ),
        ),
        if (_maxZoom > _minZoom)
          Positioned(
            right: 12,
            top: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Text('${_zoom.toStringAsFixed(1)}x'),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _active = false;
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Powerline Measure'),
      actions: [
        IconButton(
          tooltip: 'Inspection history',
          onPressed: _busy
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const HistoryScreen(),
                  ),
                ),
          icon: const Icon(Icons.history),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: _busy
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: _busy
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Preparing full-resolution photo...'),
                      ],
                    )
                  : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          TextButton(
                            onPressed: _syncCamera,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _controller == null
                  ? const CircularProgressIndicator()
                  : LayoutBuilder(
                      builder: (context, constraints) =>
                          _buildCameraPreview(constraints.biggest),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _controller == null || _busy ? null : _capture,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Take photo'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickExisting,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Open image'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _CameraGrid extends StatelessWidget {
  const _CameraGrid();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GridPainter());
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (final fraction in [1 / 3, 2 / 3]) {
      final x = size.width * fraction;
      final y = size.height * fraction;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
