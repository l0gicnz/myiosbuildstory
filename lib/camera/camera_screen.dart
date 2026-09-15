import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../image_processing/crop_service.dart';
import '../inspection/inspection_screen.dart';
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
        setState(() {
          _controller = next;
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
    try {
      final path = await _service.capture(controller);
      await _openImage(path);
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

  Future<void> _pickExisting() async {
    if (_busy) return;
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      setState(() {
        _busy = true;
        _error = null;
      });
      final path = await _service.importImage(picked.path);
      await _openImage(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open image: $e')),
        );
      }
    } finally {
      _inspecting = false;
      if (mounted) {
        setState(() => _busy = false);
        _syncCamera();
      }
    }
  }

  Future<void> _openImage(String path) async {
    _inspecting = true;
    _syncCamera();
    final source = await CropService.prepare(path);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InspectionScreen(source: source),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _active = false;
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Powerline Measure')),
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
                        Text('Preparing full-resolution photo…'),
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
                  : CameraPreview(_controller!),
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
