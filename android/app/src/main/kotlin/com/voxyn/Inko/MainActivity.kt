package com.voxyn.Inko

import android.media.MediaMetadataRetriever
import android.os.Handler
import android.util.Log
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 原生入口：只做「文件落盘 + 视频编解码搬运」，不含任何水印排版逻辑。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.voxyn.Inko/media"
        const val PROGRESS_CHANNEL = "com.voxyn.Inko/media/progress"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cancelFlag = AtomicBoolean(false)
    private val busy = AtomicBoolean(false)

    private var progressSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, PROGRESS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            },
        )

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "materializeAsset" -> materializeAsset(call, result)
                "saveImage" -> saveImage(call, result)
                "probeVideo" -> probeVideo(call, result)
                "exportVideo" -> exportVideo(call, result)
                "cancelExport" -> {
                    cancelFlag.set(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 把 Flutter asset 复制到缓存目录，供原生 GL 直接读文件。 */
    private fun materializeAsset(call: MethodCall, result: MethodChannel.Result) {
        val asset = call.argument<String>("asset")
        if (asset == null) {
            result.error("bad_args", "缺少 asset 参数", null)
            return
        }
        val fileName = call.argument<String>("fileName") ?: "inko_asset"
        executor.execute {
            try {
                val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
                val out = File(cacheDir, fileName)
                assets.open(key).use { input ->
                    out.outputStream().use { output -> input.copyTo(output) }
                }
                mainHandler.post { result.success(out.absolutePath) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error("asset_failed", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun saveImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("bad_args", "缺少图片数据", null)
            return
        }
        val fileName = call.argument<String>("fileName") ?: "Inko.jpg"
        val album = call.argument<String>("album") ?: "Inko"
        executor.execute {
            try {
                val saved = MediaSaver(this).saveJpeg(bytes, fileName, album)
                mainHandler.post { result.success(saved) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error("save_failed", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun probeVideo(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        if (input == null) {
            result.error("bad_args", "缺少输入路径", null)
            return
        }
        executor.execute {
            try {
                val retriever = MediaMetadataRetriever()
                retriever.setDataSource(input)
                val width = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    ?.toIntOrNull() ?: 0
                val height = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    ?.toIntOrNull() ?: 0
                val rotation = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    ?.toIntOrNull() ?: 0
                retriever.release()
                val swapped = rotation == 90 || rotation == 270
                val pair = if (swapped) {
                    listOf(height, width)
                } else {
                    listOf(width, height)
                }
                mainHandler.post { result.success(pair) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error("probe_failed", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun exportVideo(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val watermark = call.argument<String>("watermark")
        val rect = call.argument<List<Double>>("rect")
        val shader = call.argument<String>("shader")
        val vertexShader = call.argument<String>("vertexShader")
        if (input == null || watermark == null || rect == null || rect.size < 4 ||
            shader == null || vertexShader == null
        ) {
            result.error("bad_args", "导出参数不完整", null)
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "已有导出任务在进行", null)
            return
        }
        cancelFlag.set(false)

        val opacity = (call.argument<Double>("opacity") ?: 1.0).toFloat()
        val codec = (call.argument<String>("codec") ?: "auto")
            .let { if (it == "h264" || it == "hevc") it else "auto" }
        val fileName = call.argument<String>("fileName") ?: "Inko.mp4"
        val album = call.argument<String>("album") ?: "Inko"

        executor.execute {
            val watermarker = VideoWatermarker()
            try {
                val target = MediaSaver(this).createVideoTarget(fileName, album)
                val request = VideoWatermarker.Request(
                    inputPath = input,
                    watermarkPath = watermark,
                    rect = FloatArray(4) { index -> rect[index].toFloat() },
                    opacity = opacity,
                    codec = codec,
                    fragmentShader = shader,
                    vertexShader = vertexShader,
                    output = target,
                    onProgress = { value ->
                        mainHandler.post { progressSink?.success(value) }
                    },
                    isCancelled = { cancelFlag.get() },
                )
                watermarker.process(request)
                val usedCodec = watermarker.resolvedEncoderMime ?: "video/avc"
                val audioError = watermarker.audioError
                mainHandler.post {
                    result.success(
                        mapOf(
                            "path" to target.display,
                            "codec" to usedCodec,
                            "audio" to (audioError == null),
                            "warning" to audioError,
                        ),
                    )
                }
            } catch (error: Throwable) {
                Log.e("Inko", "视频导出失败（阶段：${watermarker.stage}）", error)
                val stage = watermarker.stage
                val message =
                    "[$stage] ${error.javaClass.simpleName}: ${error.message ?: "无消息"}"
                val detail = Log.getStackTraceString(error)
                mainHandler.post { result.error("export_failed", message, detail) }
            } finally {
                busy.set(false)
            }
        }
    }

    override fun onDestroy() {
        cancelFlag.set(true)
        executor.shutdown()
        super.onDestroy()
    }
}
