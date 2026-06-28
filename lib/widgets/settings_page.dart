import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_settings.dart';
import '../theme.dart';

/// Full settings screen. Edits a working copy and hands it back on save so the
/// caller can persist and apply it.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.initial});
  final AppSettings initial;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late AppSettings s = widget.initial.copy();

  /// App version shown in the 정보 section (e.g. `1.0.4 (5)`); loaded from the
  /// platform package info so it always matches the installed build.
  String _version = '…';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version = '${info.version} (${info.buildNumber})');
      }
    } catch (_) {
      if (mounted) setState(() => _version = '알 수 없음');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.panel,
        surfaceTintColor: Colors.transparent,
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, null),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, s),
            child: const Text('Save',
                style: TextStyle(
                    color: AppColors.brass, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          _section('New media defaults'),
          _sliderTile(
            'Default volume',
            '${s.defaultVolume.round()}%',
            s.defaultVolume,
            0,
            100,
            (v) => setState(() => s.defaultVolume = v),
          ),
          _switchTile('Start muted', 'New videos begin silenced',
              s.defaultMuted, (v) => setState(() => s.defaultMuted = v)),
          _switchTile('Loop by default', 'Replay videos when they finish',
              s.defaultLoop, (v) => setState(() => s.defaultLoop = v)),
          _choiceTile<DefaultPlayback>(
            'On add',
            s.defaultPlayback,
            const {
              DefaultPlayback.play: 'Play',
              DefaultPlayback.pause: 'Pause',
            },
            (v) => setState(() => s.defaultPlayback = v),
          ),

          _section('Canvas'),
          _choiceTile<CanvasBackground>(
            'Background',
            s.canvasBackground,
            const {
              CanvasBackground.dots: 'Dots',
              CanvasBackground.grid: 'Grid',
              CanvasBackground.solid: 'Solid',
            },
            (v) => setState(() => s.canvasBackground = v),
          ),
          _switchTile('Snap to grid', 'Align items while dragging',
              s.snapToGrid, (v) => setState(() => s.snapToGrid = v)),
          if (s.snapToGrid)
            _sliderTile(
              'Grid size',
              '${s.gridSize.round()} px',
              s.gridSize,
              8,
              80,
              (v) => setState(() => s.gridSize = v),
            ),

          _section('Behavior'),
          _switchTile(
              'Show title bars',
              'Display the name strip on selected items',
              s.showTitleBars,
              (v) => setState(() => s.showTitleBars = v)),
          _switchTile('Confirm before removing', 'Ask before deleting an item',
              s.confirmRemove, (v) => setState(() => s.confirmRemove = v)),
          _switchTile('Keep screen awake', 'Prevent sleep while board is open',
              s.keepAwake, (v) => setState(() => s.keepAwake = v)),

          _section('정보'),
          _infoTile('Media Canvas', '버전 $_version'),
        ],
      ),
    );
  }

  /// A read-only info row (e.g. the app version).
  Widget _infoTile(String title, String value) {
    return ListTile(
      leading: const Icon(Icons.info_outline, color: AppColors.brass),
      title: Text(title, style: const TextStyle(color: AppColors.text)),
      subtitle: Text(value,
          style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
    );
  }

  // ---- Tiles -------------------------------------------------------------

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
        child: MicroLabel(title, color: AppColors.brass),
      );

  Widget _switchTile(
      String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeColor: AppColors.brass,
      title: Text(title, style: const TextStyle(color: AppColors.text)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
    );
  }

  Widget _sliderTile(String title, String valueLabel, double value, double min,
      double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: const TextStyle(color: AppColors.text)),
                Text(valueLabel,
                    style: const TextStyle(
                        color: AppColors.brass,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _choiceTile<T>(
    String title,
    T value,
    Map<T, String> options,
    ValueChanged<T> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
              child:
                  Text(title, style: const TextStyle(color: AppColors.text))),
          const SizedBox(width: 12),
          SegmentedButton<T>(
            segments: options.entries
                .map((e) =>
                    ButtonSegment<T>(value: e.key, label: Text(e.value)))
                .toList(),
            selected: {value},
            showSelectedIcon: false,
            onSelectionChanged: (set) => onChanged(set.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(
                  const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}
