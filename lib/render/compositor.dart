import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'geometry.dart';

/// 图层与画面的解码/合成。
///
/// 合成公式与原 App 的片元着色器一致（直通 alpha 的 source-over）：
/// Flutter 的 `BlendMode.srcOver` 在直通 alpha 源图上的结果恰好等于
/// `mix(dst.rgb, src.rgb, src.a)`，所以照片与预览不需要额外的 GPU 着色器，
/// 也能做到像素级一致。`opacity` 通过 `Paint.color.alpha` 作用于源 alpha，
/// 默认 1.0 时与原 App 完全相同。
class WatermarkCompositor {
  const WatermarkCompositor();

  /// 从 assets 里解码水印图层。
  Future<ui.Image> loadWatermark(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return decodeImage(data.buffer.asUint8List());
  }

  /// 从文件解码照片。
  Future<ui.Image> decodeFile(File file) async {
    final bytes = await file.readAsBytes();
    return decodeImage(bytes);
  }

  Future<ui.Image> decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// 把水印画到照片上，返回合成后的图像。
  Future<ui.Image> compositePhoto({
    required ui.Image frame,
    required ui.Image watermark,
    required WatermarkRect rect,
    required double opacity,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final size = Size(frame.width.toDouble(), frame.height.toDouble());

    canvas.drawImage(frame, Offset.zero, ui.Paint());

    if (rect.width >= 1 && rect.height >= 1) {
      final paint = ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..color = ui.Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
      canvas.drawImageRect(
        watermark,
        Rect.fromLTWH(
          0,
          0,
          watermark.width.toDouble(),
          watermark.height.toDouble(),
        ),
        rect.rect,
        paint,
      );
    }

    final picture = recorder.endRecording();
    try {
      return await picture.toImage(size.width.round(), size.height.round());
    } finally {
      picture.dispose();
    }
  }

  /// 把合成结果编码成 PNG（无损，交给原生侧再压成 JPEG 或直接落盘）。
  Future<Uint8List> encodePng(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('图像编码失败');
    }
    return data.buffer.asUint8List();
  }
}
