import 'package:flutter/material.dart';

import 'app_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          children: [
            const ListTile(
              title: Text('Measurement units'),
              subtitle: Text('Used when displaying calibrated widths.'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<MeasurementUnit>(
                segments: const [
                  ButtonSegment(
                    value: MeasurementUnit.millimetres,
                    label: Text('mm'),
                  ),
                  ButtonSegment(
                    value: MeasurementUnit.inches,
                    label: Text('in'),
                  ),
                ],
                selected: {settings.unit},
                onSelectionChanged: (values) => settings.setUnit(values.first),
              ),
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('Camera grid'),
              subtitle: const Text('Show rule-of-thirds guides while framing.'),
              value: settings.showCameraGrid,
              onChanged: settings.setShowCameraGrid,
            ),
            SwitchListTile(
              title: const Text('Retain original photos'),
              subtitle: const Text('Keep full-resolution photos with history.'),
              value: settings.retainOriginalPhotos,
              onChanged: settings.setRetainOriginalPhotos,
            ),
            SwitchListTile(
              title: const Text('Dark theme'),
              subtitle: const Text('Use a dark interface for low-light work.'),
              value: settings.useDarkTheme,
              onChanged: settings.setUseDarkTheme,
            ),
            const Divider(),
            const ListTile(
              title: Text('Detection tuning'),
              subtitle: Text('These values apply to new inspections.'),
            ),
            _ValueSlider(
              label: 'Minimum confidence',
              value: settings.minimumConfidence,
              min: 0,
              max: 1,
              divisions: 20,
              valueLabel: settings.minimumConfidence.toStringAsFixed(2),
              onChanged: settings.setMinimumConfidence,
            ),
            _ValueSlider(
              label: 'Mask threshold',
              value: settings.maskThreshold,
              min: 0.05,
              max: 0.95,
              divisions: 18,
              valueLabel: settings.maskThreshold.toStringAsFixed(2),
              onChanged: settings.setMaskThreshold,
            ),
            _ValueSlider(
              label: 'Maximum tap distance (px)',
              value: settings.maximumPointDistance,
              min: 0,
              max: 128,
              divisions: 32,
              valueLabel: settings.maximumPointDistance.toStringAsFixed(0),
              onChanged: settings.setMaximumPointDistance,
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueSlider extends StatelessWidget {
  const _ValueSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label, valueLabel;
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    subtitle: Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: valueLabel,
      onChanged: onChanged,
    ),
    trailing: Text(valueLabel),
  );
}
