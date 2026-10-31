import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:inko/data/catalog.dart';
import 'package:inko/render/geometry.dart';

void main() {
  group('round2（原 App 的取偶规则）', () {
    test('四舍五入后向下取偶', () {
      expect(round2(418.56), 418);
      expect(round2(419.0), 418);
      expect(round2(419.6), 420);
      expect(round2(127.44), 126);
      expect(round2(0), 0);
    });
  });

  group('水印矩形', () {
    // X4 · 16:9 · 右下：0.109##0.858##0.059，图层 627×87
    const config = <double>[0.109, 0.858, 0.059];
    const frame = Size(3840, 2160);
    const png = Size(627, 87);

    test('3840×2160 与原 App 的结果逐像素一致', () {
      final rect = computeWatermarkRect(
        frame: frame,
        config: config,
        pngSize: png,
        position: 'BottomRight',
      );
      expect(rect.width, 418);
      expect(rect.height, 58);
      expect(rect.left, 3294);
      // 纵坐标自下向上：下边距 126，因此顶边 = 2160 - 126 - 58
      expect(rect.top, 1976);
    });

    test('缩放到 100% 时不改变任何数值', () {
      final rect = computeWatermarkRect(
        frame: frame,
        config: config,
        pngSize: png,
        position: 'BottomRight',
        scale: 1,
      );
      expect(rect.left, 3294);
      expect(rect.width, 418);
    });

    test('比例工具函数', () {
      expect(ratioValue('16:9'), closeTo(16 / 9, 1e-9));
      expect(ratioValue('9:16'), closeTo(9 / 16, 1e-9));
    });
  });
}
