import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 与原生侧的桥。
///
/// 原生只做三件“搬运”工作，不含任何水印排版或混合逻辑：
/// 1. 把合成好的照片写进系统相册；
/// 2. 视频解码 → GPU 纹理（水印矩形、图层、透明度、混合着色器全部由 Dart 传入）；
/// 3. 重新编码并复用原音轨，写进系统相册。
class MediaBridge {
  MediaBridge._();

  static const MethodChannel _methods = MethodChannel('com.voxyn.Inko/media');
  static const EventChannel _progress =
      EventChannel('com.voxyn.Inko/media/progress');

  /// 视频导出进度，0..1。
  static Stream<double> get exportProgress => _progress
      .receiveBroadcastStream()
      .map((event) => (event as num).toDouble());

  /// 保存照片。返回落盘位置（相册 uri 或文件路径）。
  static Future<String?> saveImage({
    required Uint8List png,
    required String fileName,
    required String albumName,
  }) async {
    return _methods.invokeMethod<String>('saveImage', <String, dynamic>{
      'bytes': png,
      'fileName': fileName,
      'album': albumName,
    });
  }

  /// 导出视频。
  ///
  /// * [rect] —— 归一化的 `[left, top, width, height]`，左上原点；
  /// * [shader] —— 混合内核源码，原生侧原样编译（保证与预览同源）；
  /// * [codec] —— `auto` / `h264` / `hevc`；
  /// * [watermarkPath] —— 已落盘的水印 PNG 绝对路径。
  static Future<VideoExportResult?> exportVideo({
    required String inputPath,
    required String watermarkPath,
    required List<double> rect,
    required double opacity,
    required String shader,
    required String vertexShader,
    required String codec,
    required String fileName,
    required String albumName,
  }) async {
    final raw = await _methods.invokeMethod<Map<Object?, Object?>>(
      'exportVideo',
      <String, dynamic>{
        'input': inputPath,
        'watermark': watermarkPath,
        'rect': rect,
        'opacity': opacity,
        'shader': shader,
        'vertexShader': vertexShader,
        'codec': codec,
        'fileName': fileName,
        'album': albumName,
      },
    );
    if (raw == null) return null;
    return VideoExportResult(
      location: raw['path'] as String? ?? '',
      codec: raw['codec'] as String? ?? '',
    );
  }

  static Future<void> cancelExport() async {
    await _methods.invokeMethod<void>('cancelExport');
  }

  /// 把水印图层写进缓存目录，供原生 GL 读取。
  static Future<String> materializeAsset(
    String assetPath,
    String fileName,
  ) async {
    final path = await _methods.invokeMethod<String>('materializeAsset', {
      'asset': assetPath,
      'fileName': fileName,
    });
    if (path == null) {
      throw StateError('无法释放水印图层资源');
    }
    return path;
  }

  static Future<ui.Size?> probeVideo(String path) async {
    final raw = await _methods.invokeMethod<List<dynamic>>('probeVideo', {
      'input': path,
    });
    if (raw == null || raw.length < 2) return null;
    return ui.Size((raw[0] as num).toDouble(), (raw[1] as num).toDouble());
  }
}

/// 视频导出结果：落盘位置 + 实际使用的编码器。
class VideoExportResult {
  const VideoExportResult({required this.location, required this.codec});

  final String location;

  /// 实际使用的 mime，例如 `video/hevc`。
  final String codec;

  /// 面向用户的编码器名字。
  String get codecLabel {
    switch (codec) {
      case 'video/hevc':
        return 'HEVC';
      case 'video/avc':
        return 'H.264';
      default:
        return codec.isEmpty ? '视频' : codec;
    }
  }
}

/// 便捷的 BuildContext 扩展，避免到处写 `MediaQuery.of(context)`。
extension InkoContext on BuildContext {
  Size get screenSize => MediaQuery.sizeOf(this);
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}
