/// 水印合成的不变量。
///
/// 这些数值和公式全部来自原 App 的原生滤镜链，改动会导致效果与原 App 不一致：
///
/// * `round2`  —— `WatermarkUtilsKt#getWatermarkRectReal` 的取偶逻辑
///   `(Math.round(v) / 2) * 2`，Java 里是整数除法，因此是“四舍五入后向下取偶”。
/// * 纵向坐标 —— 配置表里的 y 是相对**画面底部**的距离，指向水印矩形的**下边缘**；
///   原生侧 `FSParams[1]` 用 `left/bottom/right/top`（左下原点）。
/// * 高度 —— 不查表，由 `w * pngH / pngW` 推出，保证任何分辨率下都不变形。
library;

import 'dart:ui';

/// `(Math.round(v) / 2) * 2`，整数除法取偶。
int round2(double value) => (value.round() ~/ 2) * 2;

/// 水印矩形（左上原点像素坐标）。
class WatermarkRect {
  const WatermarkRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  Rect get rect => Rect.fromLTWH(left, top, width, height);

  /// 归一化矩形 `[left, top, width, height]`（左上原点，0..1），
  /// 与原 App 传给原生滤镜的 `watermark_rect` 等价。
  List<double> toNormalized(Size frame) {
    if (frame.width <= 0 || frame.height <= 0) {
      return const [0, 0, 0, 0];
    }
    return <double>[
      left / frame.width,
      top / frame.height,
      width / frame.width,
      height / frame.height,
    ];
  }

  @override
  String toString() =>
      'WatermarkRect(l=${left.toStringAsFixed(1)}, '
      't=${top.toStringAsFixed(1)}, '
      'w=${width.toStringAsFixed(1)}, '
      'h=${height.toStringAsFixed(1)})';
}

/// 计算水印矩形，严格复刻原 App：
///
/// ```
/// w = round2(r[0] * W)
/// h = round2(w * pngH / pngW)
/// x = round2(r[1] * W)
/// y = round2(r[2] * H)          // 自下向上，指向矩形下边缘
/// top = H - y - h
/// ```
///
/// `scale` / `opacity` 是 Inko 额外提供的微调，默认值 1.0 时与原 App 像素级一致。
WatermarkRect computeWatermarkRect({
  required Size frame,
  required List<double> config,
  required Size pngSize,
  required String position,
  double scale = 1.0,
}) {
  final frameW = frame.width;
  final frameH = frame.height;
  if (frameW <= 0 || frameH <= 0 || pngSize.width <= 0 || pngSize.height <= 0) {
    return const WatermarkRect(left: 0, top: 0, width: 0, height: 0);
  }
  if (config.length < 3) {
    return const WatermarkRect(left: 0, top: 0, width: 0, height: 0);
  }

  final baseWidth = round2(config[0] * frameW).toDouble();
  final baseHeight =
      round2(baseWidth * pngSize.height / pngSize.width).toDouble();
  final left = round2(config[1] * frameW).toDouble();
  final bottom = round2(config[2] * frameH).toDouble();

  final width = baseWidth * scale;
  final height = baseHeight * scale;

  // 缩放时保持原来那一侧的外边距不变（右对齐贴右、顶部对齐贴顶）
  double scaledLeft = left;
  if (position.endsWith('Right')) {
    scaledLeft = left + baseWidth - width;
  } else if (position.endsWith('Center')) {
    scaledLeft = left + (baseWidth - width) / 2;
  }

  double scaledTop = frameH - bottom - baseHeight;
  if (position.startsWith('Bottom')) {
    scaledTop = frameH - bottom - height;
  }

  // 限制在画面内，避免缩放过大时溢出
  final maxLeft = (frameW - width).clamp(0.0, double.infinity);
  final maxTop = (frameH - height).clamp(0.0, double.infinity);

  return WatermarkRect(
    left: scaledLeft.clamp(0.0, maxLeft),
    top: scaledTop.clamp(0.0, maxTop),
    width: width,
    height: height,
  );
}
