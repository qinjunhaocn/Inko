import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// 水印图层目录：由 `tools/build_catalog.py` 从原 App 的
/// `assets/share_config/Watermark_Config_Table.txt` +
/// `assets/share_config/Image_Watermark_Config_Table.txt` + `assets/watermark/*.png`
/// 生成，运行时只读。
class WatermarkCatalog {
  WatermarkCatalog({
    required this.models,
    required this.positions,
    required this.ratios,
    required this.languages,
    required this.languageNames,
    required this.photoPosition,
  });

  final List<WatermarkModel> models;
  final List<String> positions;
  final List<String> ratios;
  final List<String> languages;
  final Map<String, String> languageNames;

  /// 原 App 的照片水印固定落在底部居中（WatermarkUtilsKt#getWatermarkRectReal）。
  final String photoPosition;

  static WatermarkCatalog? _cache;

  static Future<WatermarkCatalog> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/config/watermark_catalog.json');
    final catalog = WatermarkCatalog.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    _cache = catalog;
    return catalog;
  }

  factory WatermarkCatalog.fromJson(Map<String, dynamic> json) {
    return WatermarkCatalog(
      models: (json['models'] as List<dynamic>)
          .map((e) => WatermarkModel.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      positions: (json['positions'] as List<dynamic>).cast<String>(),
      ratios: (json['ratios'] as List<dynamic>).cast<String>(),
      languages: (json['languages'] as List<dynamic>).cast<String>(),
      languageNames: (json['languageNames'] as Map<String, dynamic>)
          .map((key, value) => MapEntry(key, value as String)),
      photoPosition: json['photoPosition'] as String? ?? 'BottomCenter',
    );
  }

  WatermarkModel model(String id) {
    return models.firstWhere(
      (m) => m.id == id,
      orElse: () => models.first,
    );
  }

  /// 机型分组顺序，用于选择器分组展示。
  List<String> get families {
    final seen = <String>[];
    for (final model in models) {
      if (!seen.contains(model.family)) seen.add(model.family);
    }
    return seen;
  }
}

class WatermarkModel {
  WatermarkModel({
    required this.id,
    required this.name,
    required this.family,
    required this.styles,
    required this.rectsVideo,
    required this.rectsPhoto,
  });

  final String id;
  final String name;
  final String family;
  final List<WatermarkStyle> styles;

  /// 键：`样式##比例##位置`，值：`[宽度, 横坐标, 纵坐标]`（归一化，纵坐标自下向上）
  final Map<String, List<double>> rectsVideo;
  final Map<String, List<double>> rectsPhoto;

  factory WatermarkModel.fromJson(Map<String, dynamic> json) {
    Map<String, List<double>> rects(String key) {
      final raw = json[key] as Map<String, dynamic>? ?? const {};
      return raw.map(
        (k, v) => MapEntry(
          k,
          (v as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
        ),
      );
    }

    return WatermarkModel(
      id: json['id'] as String,
      name: json['name'] as String,
      family: json['family'] as String,
      styles: (json['styles'] as List<dynamic>)
          .map((e) => WatermarkStyle.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      rectsVideo: rects('rectsVideo'),
      rectsPhoto: rects('rectsPhoto'),
    );
  }

  WatermarkStyle style(String id) {
    return styles.firstWhere((s) => s.id == id, orElse: () => styles.first);
  }

  Map<String, List<double>> rectsFor({required bool photo}) =>
      photo ? rectsPhoto : rectsVideo;

  /// 当前机型可用的比例（以配置表里真实出现的条目为准）。
  List<String> availableRatios({required bool photo}) {
    final table = rectsFor(photo: photo);
    final seen = <String>{};
    for (final key in table.keys) {
      final parts = key.split('##');
      if (parts.length >= 3) seen.add(parts[1]);
    }
    return seen.toList(growable: false);
  }

  /// 把画面的真实宽高比吸附到配置表里最接近的比例。
  String nearestRatio(double aspect, {required bool photo}) {
    final ratios = availableRatios(photo: photo);
    if (ratios.isEmpty) return '16:9';
    var best = ratios.first;
    var bestDelta = double.infinity;
    for (final ratio in ratios) {
      final delta = (ratioValue(ratio) - aspect).abs();
      if (delta < bestDelta - 1e-9) {
        best = ratio;
        bestDelta = delta;
      }
    }
    return best;
  }

  /// 查表。样式键优先，找不到时回落到 `Normal`、再回落到任意样式。
  List<double>? findRect({
    required bool photo,
    required String styleKey,
    required String ratio,
    required String position,
  }) {
    final table = rectsFor(photo: photo);
    if (table.isEmpty) return null;

    final styleKeys = <String>[
      styleKey,
      if (styleKey != 'Normal') 'Normal',
    ];
    for (final key in styleKeys) {
      final exact = table['$key##$ratio##$position'];
      if (exact != null) return exact;
    }
    // 精确比例缺失：在同一站位下取最接近的比例
    for (final key in styleKeys) {
      double? bestDelta;
      List<double>? best;
      for (final entry in table.entries) {
        final parts = entry.key.split('##');
        if (parts.length != 3) continue;
        if (parts[0] != key || parts[2] != position) continue;
        final delta = (ratioValue(parts[1]) - ratioValue(ratio)).abs();
        if (bestDelta == null || delta < bestDelta) {
          bestDelta = delta;
          best = entry.value;
        }
      }
      if (best != null) return best;
    }
    // 该站位不存在：回落到底部居中，再兜底为任意一条
    if (position != 'BottomCenter') {
      final fallback = findRect(
        photo: photo,
        styleKey: styleKey,
        ratio: ratio,
        position: 'BottomCenter',
      );
      if (fallback != null) return fallback;
    }
    return table.values.first;
  }
}

class WatermarkStyle {
  WatermarkStyle({
    required this.id,
    required this.label,
    required this.positional,
    required this.videoBase,
    required this.imageBase,
    required this.langs,
  });

  final String id;
  final String label;

  /// 该样式是否按站位切换图层（自适应色调 / GO Ultra 标准水印）。
  final bool positional;
  final String videoBase;
  final String imageBase;

  /// 语言 -> 配置表样式键与照片图层基名
  final Map<String, StyleLang> langs;

  factory WatermarkStyle.fromJson(Map<String, dynamic> json) {
    final rawLangs = json['langs'] as Map<String, dynamic>;
    return WatermarkStyle(
      id: json['id'] as String,
      label: json['label'] as String,
      positional: json['positional'] as bool? ?? false,
      videoBase: json['videoBase'] as String,
      imageBase: json['imageBase'] as String,
      langs: rawLangs.map(
        (key, value) => MapEntry(
          key,
          StyleLang.fromJson(value as Map<String, dynamic>),
        ),
      ),
    );
  }

  bool supports(String language) => langs.containsKey(language);

  List<String> get availableLanguages {
    const order = ['cn', 'hk', 'en'];
    return order.where(langs.containsKey).toList(growable: false);
  }

  /// 站位切分时左右各取 `_left` / `_right`，其余取 `_center`。
  String? _sideFor(String position) {
    if (!positional) return null;
    if (position.startsWith('Bottom') || position.startsWith('Top')) {
      return position.endsWith('Left') ? 'left' : 'right';
    }
    return 'center';
  }

  String? assetFor({
    required bool photo,
    required String language,
    required String position,
  }) {
    final lang = langs[language] ?? langs.values.firstOrNull;
    if (lang == null) return null;
    if (photo) {
      final base = lang.imageBase;
      if (base == null) return null;
      return 'assets/watermark/$base.png';
    }
    final side = _sideFor(position);
    final base = side == null
        ? '$videoBase${_langSuffix(language)}'
        : '${videoBase}_$side${_langSuffix(language)}';
    return 'assets/watermark/$base.png';
  }

  static String _langSuffix(String language) {
    switch (language) {
      case 'cn':
        return '_cn';
      case 'hk':
        return '_hk';
      default:
        return '';
    }
  }
}

class StyleLang {
  StyleLang({required this.rectKey, this.imageBase, this.degraded = false});

  /// 配置表里实际使用的样式键（中文为 `Xxx-CN`）
  final String rectKey;
  final String? imageBase;
  final bool degraded;

  factory StyleLang.fromJson(Map<String, dynamic> json) {
    return StyleLang(
      rectKey: json['rect'] as String,
      imageBase: json['image'] as String?,
      degraded: json['degraded'] as bool? ?? false,
    );
  }
}

double ratioValue(String ratio) {
  final parts = ratio.split(':');
  if (parts.length != 2) return 1;
  final a = double.tryParse(parts[0]);
  final b = double.tryParse(parts[1]);
  if (a == null || b == null || b == 0) return 1;
  return a / b;
}

/// 解析后的水印：图层路径 + 归一化位置 + 实际用的比例。
class ResolvedWatermark {
  const ResolvedWatermark({
    required this.assetPath,
    required this.config,
    required this.ratio,
    required this.styleKey,
  });

  final String assetPath;

  /// `[宽度, 横坐标, 纵坐标]`，归一化，纵坐标自下向上
  final List<double> config;
  final String ratio;
  final String styleKey;
}

ResolvedWatermark? resolveWatermark({
  required WatermarkModel model,
  required WatermarkStyle style,
  required bool photo,
  required String language,
  required String position,
  required double aspect,
  String? ratioOverride,
}) {
  final lang = style.langs[language] ?? style.langs.values.firstOrNull;
  if (lang == null) return null;
  final asset = style.assetFor(
    photo: photo,
    language: language,
    position: position,
  );
  if (asset == null) return null;
  final ratio = ratioOverride ?? model.nearestRatio(aspect, photo: photo);
  final config = model.findRect(
    photo: photo,
    styleKey: lang.rectKey,
    ratio: ratio,
    position: position,
  );
  if (config == null) return null;
  final safeAspect = aspect.isFinite && aspect > 0 ? aspect : 16 / 9;
  return ResolvedWatermark(
    assetPath: asset,
    config: config,
    ratio: ratioOverride ?? model.nearestRatio(safeAspect, photo: photo),
    styleKey: lang.rectKey,
  );
}

/// 极简的浮点近似比较，供比例吸附时避免抖动。
bool nearlyEqual(double a, double b) => (a - b).abs() < 1e-6;

/// 把任意 W/H 保守地映射到 `w:h` 字符串，便于调试输出。
String ratioLabel(double aspect) {
  final nearest = math.max(1, (aspect * 100).round());
  return '$nearest:100';
}
