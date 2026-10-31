import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../data/catalog.dart';
import '../data/settings.dart';
import '../platform/media_bridge.dart';
import '../render/compositor.dart';
import '../render/geometry.dart';
import '../render/water_kernel.dart';
import 'model_picker.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.file, required this.kind});

  final File file;
  final MediaKind kind;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final WatermarkCompositor _compositor = const WatermarkCompositor();

  WatermarkCatalog? _catalog;
  WatermarkSettings _settings = WatermarkSettings.initial;

  ui.Image? _photo;
  VideoPlayerController? _video;

  ui.Image? _watermark;
  String? _watermarkAsset;

  Size? _frameSize;
  WatermarkRect? _rect;
  ResolvedWatermark? _resolved;

  String? _error;
  bool _exporting = false;
  double _progress = 0;
  StreamSubscription<double>? _progressSub;

  bool get _isPhoto => widget.kind == MediaKind.photo;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _progressSub = MediaBridge.exportProgress.listen((value) {
      if (mounted) setState(() => _progress = value.clamp(0.0, 1.0));
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _video?.dispose();
    _photo?.dispose();
    _watermark?.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final catalog = await WatermarkCatalog.load();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _settings = _settings.copyWith(
          modelId: catalog.models.first.id,
          styleId: catalog.models.first.styles.first.id,
        );
      });

      if (_isPhoto) {
        final image = await _compositor.decodeFile(widget.file);
        if (!mounted) return;
        setState(() {
          _photo = image;
          _frameSize = Size(image.width.toDouble(), image.height.toDouble());
          _settings = _settings.copyWith(position: catalog.photoPosition);
        });
        await _refresh();
      } else {
        final controller = VideoPlayerController.file(widget.file);
        await controller.initialize();
        await controller.setLooping(true);
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {
          _video = controller;
          _frameSize = controller.value.size;
        });
        await _refresh();
        await controller.play();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '读取媒体失败：$error');
    }
  }

  /// 每次选择变化都重新解析：图层 → 比例 → 位置 → 像素矩形。
  Future<void> _refresh() async {
    final catalog = _catalog;
    final frameSize = _frameSize;
    if (catalog == null || frameSize == null) return;
    if (frameSize.width <= 0 || frameSize.height <= 0) return;

    final model = catalog.model(_settings.modelId);
    var style = model.style(_settings.styleId);
    var language = _settings.language;
    if (!style.supports(language)) {
      language = style.availableLanguages.isEmpty
          ? 'en'
          : style.availableLanguages.first;
    }

    final position = _isPhoto ? catalog.photoPosition : _settings.position;
    final aspect = frameSize.width / frameSize.height;
    final resolved = resolveWatermark(
      model: model,
      style: style,
      photo: _isPhoto,
      language: language,
      position: position,
      aspect: aspect,
      ratioOverride: _settings.ratioOverride,
    );
    if (resolved == null) {
      setState(() => _error = '这个机型没有可用的水印图层');
      return;
    }

    if (resolved.assetPath != _watermarkAsset) {
      final image = await _compositor.loadWatermark(resolved.assetPath);
      if (!mounted) return;
      setState(() {
        _watermark?.dispose();
        _watermark = image;
        _watermarkAsset = resolved.assetPath;
      });
    }

    final watermark = _watermark;
    if (watermark == null) return;

    final rect = computeWatermarkRect(
      frame: frameSize,
      config: resolved.config,
      pngSize: Size(
        watermark.width.toDouble(),
        watermark.height.toDouble(),
      ),
      position: position,
      scale: _settings.scale,
    );

    if (!mounted) return;
    setState(() {
      _settings = _settings.copyWith(
        styleId: style.id,
        language: language,
        position: position,
      );
      _resolved = resolved;
      _rect = rect;
      _error = null;
    });
  }

  void _update(WatermarkSettings next) {
    setState(() => _settings = next);
    _refresh();
  }

  String _fileName(String extension) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'Inko_$stamp.$extension';
  }

  Future<void> _export() async {
    final resolved = _resolved;
    final rect = _rect;
    final frameSize = _frameSize;
    if (resolved == null || rect == null || frameSize == null) return;

    setState(() {
      _exporting = true;
      _progress = 0;
      _error = null;
    });

    try {
      if (_isPhoto) {
        final photo = _photo;
        final watermark = _watermark;
        if (photo == null || watermark == null) return;
        final merged = await _compositor.compositePhoto(
          frame: photo,
          watermark: watermark,
          rect: rect,
          opacity: _settings.opacity,
        );
        final png = await _compositor.encodePng(merged);
        merged.dispose();
        final saved = await MediaBridge.saveImage(
          png: png,
          fileName: _fileName('jpg'),
          albumName: 'Inko',
        );
        _toast('已保存到相册${saved == null ? '' : '：$saved'}');
      } else {
        final video = _video;
        if (video == null) return;
        await video.pause();
        final watermarkPath = await MediaBridge.materializeAsset(
          resolved.assetPath,
          'inko_watermark.png',
        );
        final saved = await MediaBridge.exportVideo(
          inputPath: widget.file.path,
          watermarkPath: watermarkPath,
          rect: rect.toNormalized(frameSize),
          opacity: _settings.opacity,
          shader: waterKernelFragmentShader,
          vertexShader: waterKernelVertexShader,
          fileName: _fileName('mp4'),
          albumName: 'Inko',
        );
        _toast('视频已导出${saved == null ? '' : '：$saved'}');
        await video.play();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final frameSize = _frameSize;
    final rect = _rect;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isPhoto ? '照片水印' : '视频水印'),
        actions: <Widget>[
          if (catalog != null)
            TextButton.icon(
              onPressed: () => _openModelPicker(catalog),
              icon: const Icon(Icons.videocam_outlined, size: 18),
              label: Text(catalog.model(_settings.modelId).name),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _error != null && frameSize == null
          ? _ErrorView(message: _error!, onRetry: () => Navigator.pop(context))
          : Column(
              children: <Widget>[
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: _PreviewArea(
                      kind: widget.kind,
                      photo: _photo,
                      video: _video,
                      watermark: _watermark,
                      frameSize: frameSize,
                      rect: rect,
                      opacity: _settings.opacity,
                      busy: _exporting,
                      progress: _progress,
                    ),
                  ),
                ),
                if (catalog != null && frameSize != null)
                  _ControlPanel(
                    catalog: catalog,
                    settings: _settings,
                    isPhoto: _isPhoto,
                    resolved: _resolved,
                    rect: rect,
                    frameSize: frameSize,
                    busy: _exporting,
                    onChanged: _update,
                    onPickModel: () => _openModelPicker(catalog),
                    onExport: _export,
                  ),
              ],
            ),
    );
  }

  Future<void> _openModelPicker(WatermarkCatalog catalog) async {
    final picked = await showModelPicker(
      context: context,
      catalog: catalog,
      selectedId: _settings.modelId,
    );
    if (picked == null) return;
    final model = catalog.model(picked);
    _update(
      _settings.copyWith(modelId: model.id, styleId: model.styles.first.id),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('返回')),
          ],
        ),
      ),
    );
  }
}

/// 预览：媒体按 contain 铺进可用区域，水印按同一套像素矩形等比缩放。
class _PreviewArea extends StatelessWidget {
  const _PreviewArea({
    required this.kind,
    required this.photo,
    required this.video,
    required this.watermark,
    required this.frameSize,
    required this.rect,
    required this.opacity,
    required this.busy,
    required this.progress,
  });

  final MediaKind kind;
  final ui.Image? photo;
  final VideoPlayerController? video;
  final ui.Image? watermark;
  final Size? frameSize;
  final WatermarkRect? rect;
  final double opacity;
  final bool busy;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = frameSize;
    if (size == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final scale = (constraints.maxWidth / size.width)
            .clamp(0.0, constraints.maxHeight / size.height);
        final display = Size(size.width * scale, size.height * scale);

        return Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: display.width,
              height: display.height,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ColoredBox(color: scheme.surfaceContainerHighest),
                  if (kind == MediaKind.photo && photo != null)
                    RawImage(image: photo, fit: BoxFit.fill)
                  else if (kind == MediaKind.video && video != null)
                    FittedBox(
                      fit: BoxFit.fill,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: video!.value.size.width,
                        height: video!.value.size.height,
                        child: VideoPlayer(video!),
                      ),
                    ),
                  if (watermark != null && rect != null)
                    CustomPaint(
                      painter: _WatermarkPainter(
                        watermark: watermark!,
                        rect: rect!.rect,
                        scale: scale,
                        opacity: opacity,
                      ),
                    ),
                  if (busy)
                    _ExportOverlay(progress: progress, isPhoto: kind == MediaKind.photo),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  _WatermarkPainter({
    required this.watermark,
    required this.rect,
    required this.scale,
    required this.opacity,
  });

  final ui.Image watermark;
  final Rect rect;
  final double scale;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
    canvas.drawImageRect(
      watermark,
      Rect.fromLTWH(
        0,
        0,
        watermark.width.toDouble(),
        watermark.height.toDouble(),
      ),
      Rect.fromLTWH(
        rect.left * scale,
        rect.top * scale,
        rect.width * scale,
        rect.height * scale,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_WatermarkPainter oldDelegate) {
    return oldDelegate.watermark != watermark ||
        oldDelegate.rect != rect ||
        oldDelegate.scale != scale ||
        oldDelegate.opacity != opacity;
  }
}

class _ExportOverlay extends StatelessWidget {
  const _ExportOverlay({required this.progress, required this.isPhoto});

  final double progress;
  final bool isPhoto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (isPhoto)
              const CircularProgressIndicator(color: Colors.white)
            else
              SizedBox(
                width: 132,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 6,
                    color: scheme.primary,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Text(
              isPhoto
                  ? '正在合成…'
                  : progress > 0
                  ? '正在导出 ${(progress * 100).toStringAsFixed(0)}%'
                  : '正在准备…',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.catalog,
    required this.settings,
    required this.isPhoto,
    required this.resolved,
    required this.rect,
    required this.frameSize,
    required this.busy,
    required this.onChanged,
    required this.onPickModel,
    required this.onExport,
  });

  final WatermarkCatalog catalog;
  final WatermarkSettings settings;
  final bool isPhoto;
  final ResolvedWatermark? resolved;
  final WatermarkRect? rect;
  final Size frameSize;
  final bool busy;
  final ValueChanged<WatermarkSettings> onChanged;
  final VoidCallback onPickModel;
  final Future<void> Function() onExport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = catalog.model(settings.modelId);
    final style = model.style(settings.styleId);
    final languages = style.availableLanguages;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.52,
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: <Widget>[
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          _ModelRow(model: model, onTap: onPickModel),
          if (model.styles.length > 1) ...<Widget>[
            const SizedBox(height: 14),
            _SectionLabel('样式'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: model.styles.map((WatermarkStyle s) {
                return ChoiceChip(
                  label: Text(s.label),
                  selected: s.id == style.id,
                  onSelected: (_) => onChanged(
                    settings.copyWith(styleId: s.id),
                  ),
                );
              }).toList(),
            ),
          ],
          if (languages.length > 1) ...<Widget>[
            const SizedBox(height: 14),
            _SectionLabel('图层语言'),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: languages
                  .map(
                    (String code) => ButtonSegment<String>(
                      value: code,
                      label: Text(catalog.languageNames[code] ?? code),
                    ),
                  )
                  .toList(),
              selected: <String>{settings.language},
              onSelectionChanged: (Set<String> value) =>
                  onChanged(settings.copyWith(language: value.first)),
            ),
          ],
          const SizedBox(height: 14),
          _SectionLabel(isPhoto ? '位置（原 App 照片固定底部居中）' : '位置'),
          const SizedBox(height: 8),
          _PositionPicker(
            enabled: !isPhoto,
            value: settings.position,
            onChanged: (String value) =>
                onChanged(settings.copyWith(position: value)),
          ),
          const SizedBox(height: 14),
          _RatioRow(
            catalog: catalog,
            model: model,
            isPhoto: isPhoto,
            settings: settings,
            frameSize: frameSize,
            resolved: resolved,
            onChanged: onChanged,
          ),
          const SizedBox(height: 8),
          _SliderRow(
            label: '缩放',
            value: settings.scale,
            min: 0.4,
            max: 2.0,
            display: '${(settings.scale * 100).toStringAsFixed(0)}%',
            onChanged: (double v) => onChanged(settings.copyWith(scale: v)),
          ),
          _SliderRow(
            label: '不透明度',
            value: settings.opacity,
            min: 0.1,
            max: 1.0,
            display: '${(settings.opacity * 100).toStringAsFixed(0)}%',
            onChanged: (double v) => onChanged(settings.copyWith(opacity: v)),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _summary(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (!settings.isDefaultLook)
                TextButton(
                  onPressed: () => onChanged(
                    settings.copyWith(scale: 1.0, opacity: 1.0),
                  ),
                  child: const Text('还原默认'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: busy ? null : () => onExport(),
            icon: const Icon(Icons.download_rounded),
            label: Text(isPhoto ? '保存到相册' : '导出视频'),
          ),
        ],
      ),
    );
  }

  String _summary() {
    final r = rect;
    if (r == null) return '${frameSize.width.round()} × ${frameSize.height.round()}';
    final ratio = resolved?.ratio ?? '';
    return '${frameSize.width.round()} × ${frameSize.height.round()}'
        '${ratio.isEmpty ? '' : ' · $ratio'}'
        ' · 水印 ${r.width.round()}×${r.height.round()} @ '
        '${r.left.round()},${r.top.round()}';
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.onTap});

  final WatermarkModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Icon(Icons.videocam_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('机型', style: Theme.of(context).textTheme.labelSmall),
                    Text(
                      model.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '更换',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 五个站位，按九宫格排布，缺的格子留空。
class _PositionPicker extends StatelessWidget {
  const _PositionPicker({
    required this.enabled,
    required this.value,
    required this.onChanged,
  });

  final bool enabled;
  final String value;
  final ValueChanged<String> onChanged;

  static const List<List<String?>> _grid = <List<String?>>[
    <String?>['TopLeft', null, 'TopRight'],
    <String?>[null, null, null],
    <String?>['BottomLeft', 'BottomCenter', 'BottomRight'],
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Column(
        children: _grid.map((List<String?> row) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: row.map((String? cell) {
                if (cell == null) {
                  return const Expanded(child: SizedBox(height: 44));
                }
                final selected = cell == value;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Material(
                      color: selected
                          ? scheme.primary
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: enabled ? () => onChanged(cell) : null,
                        child: SizedBox(
                          height: 44,
                          child: Center(
                            child: Text(
                              positionLabels[cell] ?? cell,
                              style: TextStyle(
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: selected
                                    ? scheme.onPrimary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _RatioRow extends StatelessWidget {
  const _RatioRow({
    required this.catalog,
    required this.model,
    required this.isPhoto,
    required this.settings,
    required this.frameSize,
    required this.resolved,
    required this.onChanged,
  });

  final WatermarkCatalog catalog;
  final WatermarkModel model;
  final bool isPhoto;
  final WatermarkSettings settings;
  final Size frameSize;
  final ResolvedWatermark? resolved;
  final ValueChanged<WatermarkSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final ratios = model.availableRatios(photo: isPhoto);
    final auto = frameSize.height == 0
        ? '16:9'
        : model.nearestRatio(frameSize.width / frameSize.height, photo: isPhoto);
    final current = settings.ratioOverride ?? auto;

    return Row(
      children: <Widget>[
        const _SectionLabel('比例'),
        const Spacer(),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: ratios.contains(current) ? current : ratios.first,
            borderRadius: BorderRadius.circular(14),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: ratios.contains(current) ? current : ratios.first,
                child: Text('自动 · $auto'),
              ),
              ...ratios.map(
                (String r) => DropdownMenuItem<String>(
                  value: r,
                  child: Text(r),
                ),
              ),
            ],
            onChanged: (String? value) {
              if (value == null) return;
              if (value == auto) {
                onChanged(settings.copyWith(ratioOverride: null));
              } else {
                onChanged(settings.copyWith(ratioOverride: value));
              }
            },
          ),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(width: 64, child: _SectionLabel(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ],
    );
  }
}
