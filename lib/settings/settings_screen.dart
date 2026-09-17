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
        appBar: AppBar(
          leading: const BackButton(),
          title: const Text('Settings'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          children: [
            _sectionLabel('GENERAL'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Measurement units'),
                    trailing: Text(
                      settings.unit == MeasurementUnit.millimetres
                          ? 'Metric'
                          : 'Imperial',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 17,
                      ),
                    ),
                    onTap: () => settings.setUnit(
                      settings.unit == MeasurementUnit.millimetres
                          ? MeasurementUnit.inches
                          : MeasurementUnit.millimetres,
                    ),
                  ),
                  const Divider(indent: 20, endIndent: 20, height: 1),
                  SwitchListTile(
                    title: const Text('Dark theme'),
                    value: settings.useDarkTheme,
                    onChanged: settings.setUseDarkTheme,
                  ),
                ],
              ),
            ),
            _sectionLabel('CAPTURE'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Camera grid'),
                    subtitle: const Text('Rule-of-thirds overlay'),
                    value: settings.showCameraGrid,
                    onChanged: settings.setShowCameraGrid,
                  ),
                  const Divider(indent: 20, endIndent: 20, height: 1),
                  SwitchListTile(
                    title: const Text('Retain original photos'),
                    subtitle: const Text('Keep full-resolution source images'),
                    value: settings.retainOriginalPhotos,
                    onChanged: settings.setRetainOriginalPhotos,
                  ),
                ],
              ),
            ),
            _sectionLabel('DETECTION TUNING'),
            Card(
              child: Column(
                children: [
                  _ValueSlider(
                    label: 'Min confidence',
                    value: settings.minimumConfidence,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    valueLabel: '${(settings.minimumConfidence * 100).round()}%',
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
                    label: 'Max tap distance',
                    value: settings.maximumPointDistance,
                    min: 0,
                    max: 128,
                    divisions: 32,
                    valueLabel: '${settings.maximumPointDistance.round()} px',
                    onChanged: settings.setMaximumPointDistance,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 28, 8, 12),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
        color: Colors.grey,
      ),
    ),
  );
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
