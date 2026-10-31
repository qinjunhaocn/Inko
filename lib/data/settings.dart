import 'package:flutter/foundation.dart';

/// 当前的水印选择。
///
/// 前四项与原 App 完全对应（机型 / 样式 / 语言 / 站位 + 比例）。
/// `scale` 与 `opacity` 是 Inko 额外提供的微调，默认 1.0 即与原 App 一致。
@immutable
class WatermarkSettings {
  const WatermarkSettings({
    required this.modelId,
    required this.styleId,
    required this.language,
    required this.position,
    this.ratioOverride,
    this.scale = 1.0,
    this.opacity = 1.0,
    this.codec = ExportCodec.auto,
  });

  final String modelId;
  final String styleId;
  final String language;
  final String position;

  /// 为空表示按画面宽高比自动吸附。
  final String? ratioOverride;
  final double scale;
  final double opacity;

  /// 视频导出的编码器。
  final ExportCodec codec;

  bool get isDefaultLook =>
      (scale - 1.0).abs() < 1e-6 && (opacity - 1.0).abs() < 1e-6;

  WatermarkSettings copyWith({
    String? modelId,
    String? styleId,
    String? language,
    String? position,
    Object? ratioOverride = _unset,
    double? scale,
    double? opacity,
    ExportCodec? codec,
  }) {
    return WatermarkSettings(
      modelId: modelId ?? this.modelId,
      styleId: styleId ?? this.styleId,
      language: language ?? this.language,
      position: position ?? this.position,
      ratioOverride: identical(ratioOverride, _unset)
          ? this.ratioOverride
          : ratioOverride as String?,
      scale: scale ?? this.scale,
      opacity: opacity ?? this.opacity,
      codec: codec ?? this.codec,
    );
  }

  static const Object _unset = Object();

  static const WatermarkSettings initial = WatermarkSettings(
    modelId: 'X4',
    styleId: 'Normal',
    language: 'cn',
    position: 'BottomRight',
  );
}

/// 站位的中文名，顺序与原 App 的设置项一致。
const Map<String, String> positionLabels = <String, String>{
  'BottomRight': '右下',
  'BottomLeft': '左下',
  'TopRight': '右上',
  'TopLeft': '左上',
  'BottomCenter': '底部居中',
};

/// 输入媒体的类型。
enum MediaKind { photo, video }

/// 视频导出编码器。
///
/// * [auto] —— 跟随源视频的编码（HEVC 源出 HEVC，H.264 源出 H.264），
///   设备没有对应编码器时回退 H.264；
/// * [h264] / [hevc] —— 强制指定，设备不支持则直接报错。
enum ExportCodec {
  auto('自动', 'auto'),
  h264('H.264', 'h264'),
  hevc('HEVC', 'hevc');

  const ExportCodec(this.label, this.wire);

  final String label;

  /// 传给原生侧的字符串。
  final String wire;
}
