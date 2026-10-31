package com.voxyn.Inko

import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * 视频水印合成。
 *
 * 这里只做三件“搬运”工作：
 *  1. MediaCodec 把视频解码到 GL 外部纹理；
 *  2. 用 **Dart 传下来的着色器** 与 Dart 算好的水印矩形做一次 GPU 混合；
 *  3. 编码回 H.264，并把原音轨原样搬过去。
 *
 * 排版、比例吸附、像素矩形、混合公式全部在 Flutter 侧完成并作为参数传入，
 * 原生侧没有任何硬编码的水印逻辑。
 */
class VideoWatermarker {

    class Request(
        val inputPath: String,
        val watermarkPath: String,
        /** 归一化 `[left, top, width, height]`，左上原点 */
        val rect: FloatArray,
        val opacity: Float,
        /** `auto` / `h264` / `hevc` */
        val codec: String,
        val fragmentShader: String,
        val vertexShader: String,
        val output: MediaSaver.OutputTarget,
        val onProgress: (Double) -> Unit,
        val isCancelled: () -> Boolean,
    )

    private companion object {
        const val TAG = "InkoVideo"
        const val TIMEOUT_US = 10_000L
        const val MAX_DRAIN_ITERATIONS = 200_000
        const val AUDIO_BUFFER_SIZE = 1024 * 1024
        const val MAX_AUDIO_BUFFER_SIZE = 32 * 1024 * 1024
    }

    /** 当前所处阶段，出错时用于定位 */
    @Volatile
    var stage: String = "准备"
        private set

    /** 音轨复制失败的原因；非空表示成片没有声音 */
    @Volatile
    var audioError: String? = null
        private set

    /** 实际使用的编码器 mime，供上层回显 */
    var resolvedEncoderMime: String? = null
        private set

    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1

    private enum class Drain { PROGRESS, IDLE, EOS }

    fun process(request: Request) {
        val extractor = MediaExtractor()
        extractor.setDataSource(request.inputPath)

        var videoTrack = -1
        var audioTrack = -1
        var videoFormat: MediaFormat? = null
        var audioFormat: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/") && videoTrack < 0) {
                videoTrack = i
                videoFormat = format
            } else if (mime.startsWith("audio/") && audioTrack < 0) {
                audioTrack = i
                audioFormat = format
            }
        }
        val sourceFormat = videoFormat
            ?: throw IllegalStateException("文件里没有视频轨")
        val sourceMime = sourceFormat.getString(MediaFormat.KEY_MIME)
            ?: throw IllegalStateException("无法识别视频编码")

        val codedWidth = sourceFormat.getInteger(MediaFormat.KEY_WIDTH)
        val codedHeight = sourceFormat.getInteger(MediaFormat.KEY_HEIGHT)
        val rotation = if (sourceFormat.containsKey(MediaFormat.KEY_ROTATION)) {
            sourceFormat.getInteger(MediaFormat.KEY_ROTATION)
        } else {
            0
        }
        val swapped = rotation == 90 || rotation == 270
        val outWidth = if (swapped) codedHeight else codedWidth
        val outHeight = if (swapped) codedWidth else codedHeight

        val frameRate = if (sourceFormat.containsKey(MediaFormat.KEY_FRAME_RATE)) {
            sourceFormat.getInteger(MediaFormat.KEY_FRAME_RATE).coerceIn(10, 120)
        } else {
            30
        }
        val bitRate = if (sourceFormat.containsKey(MediaFormat.KEY_BIT_RATE)) {
            sourceFormat.getInteger(MediaFormat.KEY_BIT_RATE)
        } else {
            (outWidth.toLong() * outHeight.toLong() * 8L).toInt()
        }
        val durationUs = if (sourceFormat.containsKey(MediaFormat.KEY_DURATION)) {
            sourceFormat.getLong(MediaFormat.KEY_DURATION)
        } else {
            0L
        }

        val egl = EglCore()
        var decoderRef: MediaCodec? = null
        var encoderRef: MediaCodec? = null
        var decoderSurfaceRef: Surface? = null
        var encoderInputSurfaceRef: Surface? = null
        var surfaceTextureRef: SurfaceTexture? = null
        var success = false

        try {
            stage = "初始化 EGL"
            egl.initialize()
            val frameSignal = FrameSignal()
            val externalTexture = egl.createExternalTexture()
            val st = SurfaceTexture(externalTexture)
            surfaceTextureRef = st
            st.setDefaultBufferSize(codedWidth, codedHeight)
            st.setOnFrameAvailableListener { frameSignal.signal() }

            stage = "创建解码器"
            val decoderSurface = Surface(st)
            decoderSurfaceRef = decoderSurface
            val decoder = MediaCodec.createDecoderByType(sourceMime)
            decoderRef = decoder
            decoder.configure(sourceFormat, decoderSurface, null, 0)
            decoder.start()

            stage = "选择编码器"
            val encoderMime = resolveEncoderMime(request.codec, sourceMime)
            resolvedEncoderMime = encoderMime
            val codecLabel = if (encoderMime == MediaFormat.MIMETYPE_VIDEO_HEVC) "HEVC" else "H.264"

            // 先问编码器能不能吃这个尺寸，避免 configure 抛出没有消息的
            // IllegalArgumentException，用户完全看不出发生了什么
            stage = "检查编码器能力"
            val effectiveFrameRate = checkEncoderSupport(encoderMime, outWidth, outHeight, frameRate)
            android.util.Log.i(
                TAG,
                "导出 $codecLabel ${outWidth}x$outHeight @${effectiveFrameRate}fps，源 $sourceMime",
            )

            stage = "配置编码器"
            val targetFormat =
                MediaFormat.createVideoFormat(encoderMime, outWidth, outHeight).apply {
                    setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
                    )
                    setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
                    setInteger(MediaFormat.KEY_FRAME_RATE, effectiveFrameRate)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                }
            val encoder = MediaCodec.createEncoderByType(encoderMime)
            encoderRef = encoder
            encoder.configure(targetFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            stage = "启动编码器"
            val encoderInputSurface = encoder.createInputSurface()
            encoderInputSurfaceRef = encoderInputSurface
            encoder.start()

            egl.createWindowSurface(encoderInputSurface)
            egl.makeCurrent()

            stage = "编译着色器"
            val program = GlProgram(request.vertexShader, request.fragmentShader)
            val watermarkTexture = createTextureFromFile(request.watermarkPath)

            val target = request.output
            stage = "创建封装器"
            muxer = MediaMuxer(
                target.muxerPath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
            )
            if (audioFormat != null) {
                // 个别音频编码 MediaMuxer 不支持，宁可丢音轨也不要整个导出失败
                runCatching { muxer!!.addTrack(audioFormat) }.onSuccess {
                    audioTrackIndex = it
                }.onFailure {
                    android.util.Log.w(TAG, "音轨无法写入 MP4，已跳过", it)
                    audioTrackIndex = -1
                }
            }

            val rectPx = floatArrayOf(
                request.rect[0] * outWidth,
                request.rect[1] * outHeight,
                request.rect[2] * outWidth,
                request.rect[3] * outHeight,
            )

            stage = "解码与合成"
            extractor.selectTrack(videoTrack)
            val info = MediaCodec.BufferInfo()
            val transform = FloatArray(16)
            val rotationMatrix = rotationMatrix(rotation)
            val texMatrix = FloatArray(16)

            var inputDone = false
            var decoderDone = false
            var frameCount = 0

            while (!decoderDone) {
                if (request.isCancelled()) {
                    throw InterruptedException("已取消导出")
                }

                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buffer = decoder.getInputBuffer(inIndex)
                        val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                        if (buffer == null || size < 0) {
                            decoder.queueInputBuffer(
                                inIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(
                                inIndex,
                                0,
                                size,
                                extractor.sampleTime,
                                0,
                            )
                            extractor.advance()
                        }
                    }
                }

                val outIndex = decoder.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                    outIndex >= 0 -> {
                        val endOfStream =
                            (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        val presentationTimeUs = info.presentationTimeUs
                        decoder.releaseOutputBuffer(outIndex, true)
                        if (frameSignal.await(300)) {
                            st.updateTexImage()
                            st.getTransformMatrix(transform)
                            Matrix.multiplyMM(
                                texMatrix,
                                0,
                                transform,
                                0,
                                rotationMatrix,
                                0,
                            )
                            drawFrame(
                                program = program,
                                frameTexture = externalTexture,
                                watermarkTexture = watermarkTexture,
                                texMatrix = texMatrix,
                                width = outWidth,
                                height = outHeight,
                                rect = rectPx,
                                opacity = request.opacity,
                            )
                            egl.present(st.timestamp)
                            frameCount++
                            if (frameCount % 5 == 0) {
                                val progress = if (durationUs > 0) {
                                    presentationTimeUs.toDouble() / durationUs
                                } else {
                                    0.0
                                }
                                request.onProgress(progress.coerceIn(0.0, 1.0))
                            }
                        }
                        drainAll(encoder, info)
                        if (endOfStream) decoderDone = true
                    }
                }
            }

            stage = "写入视频帧"
            finishEncoding(encoder, info)
            stage = "写入音轨"
            try {
                copyAudio(request.inputPath, audioFormat, info)
            } catch (error: Throwable) {
                // 音轨挂了不该毁掉整支片子：成片照出，但要把原因显式带回给用户
                android.util.Log.e(TAG, "音轨复制失败，成片将没有声音", error)
                audioError = error.javaClass.simpleName +
                    (error.message?.let { ": $it" } ?: "（无消息）")
            }
            request.onProgress(1.0)
            success = true
        } finally {
            stage = if (success) "收尾" else stage
            runCatching { decoderRef?.stop() }
            runCatching { decoderRef?.release() }
            runCatching { decoderSurfaceRef?.release() }
            runCatching { surfaceTextureRef?.release() }
            runCatching { encoderRef?.stop() }
            runCatching { encoderRef?.release() }
            runCatching { encoderInputSurfaceRef?.release() }
            runCatching { if (muxerStarted) muxer?.stop() }
            runCatching { muxer?.release() }
            runCatching { egl.release() }
            runCatching { extractor.release() }
            if (success) {
                request.output.commit()
            } else {
                request.output.abort()
            }
        }
    }

    // ------------------------------------------------------------------ 编码

    private fun drainAll(encoder: MediaCodec, info: MediaCodec.BufferInfo) {
        var guard = 0
        while (guard++ < MAX_DRAIN_ITERATIONS) {
            if (drainEncoder(encoder, info, 0L) != Drain.PROGRESS) return
        }
    }

    private fun finishEncoding(encoder: MediaCodec, info: MediaCodec.BufferInfo) {
        encoder.signalEndOfInputStream()
        var guard = 0
        while (guard++ < MAX_DRAIN_ITERATIONS) {
            if (drainEncoder(encoder, info, TIMEOUT_US) == Drain.EOS) return
        }
    }

    private fun drainEncoder(
        encoder: MediaCodec,
        info: MediaCodec.BufferInfo,
        timeoutUs: Long,
    ): Drain {
        val index = encoder.dequeueOutputBuffer(info, timeoutUs)
        when {
            index == MediaCodec.INFO_TRY_AGAIN_LATER -> return Drain.IDLE
            index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                if (!muxerStarted) {
                    videoTrackIndex = muxer!!.addTrack(encoder.outputFormat)
                    muxer!!.start()
                    muxerStarted = true
                }
                return Drain.PROGRESS
            }
            index >= 0 -> {
                val buffer = encoder.getOutputBuffer(index)
                if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                    info.size = 0
                }
                if (buffer != null && info.size > 0 && muxerStarted) {
                    muxer!!.writeSampleData(videoTrackIndex, buffer, info)
                }
                encoder.releaseOutputBuffer(index, false)
                return if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    Drain.EOS
                } else {
                    Drain.PROGRESS
                }
            }
            else -> return Drain.IDLE
        }
    }

    /**
     * 校验编码器是否支持当前尺寸，并返回可用的帧率。
     *
     * H.264 的 Level 上限比 HEVC 低，5.7K 这类素材用 H.264 编码器 configure 会直接抛
     * 没有消息的 IllegalArgumentException；这里提前拦下并给出人能看懂的原因。
     */
    private fun checkEncoderSupport(
        mime: String,
        width: Int,
        height: Int,
        frameRate: Int,
    ): Int {
        val label = if (mime == MediaFormat.MIMETYPE_VIDEO_HEVC) "HEVC" else "H.264"
        val caps = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .firstOrNull { info ->
                    info.isEncoder && info.supportedTypes.any {
                        it.equals(mime, ignoreCase = true) &&
                            info.getCapabilitiesForType(it).colorFormats.any { format ->
                                format == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                            }
                    }
                }?.getCapabilitiesForType(mime)?.videoCapabilities
        }.getOrNull() ?: return frameRate

        val sizeOk = runCatching { caps.isSizeSupported(width, height) }.getOrDefault(true)
        if (!sizeOk) {
            throw IllegalStateException(
                "$label 编码器不支持 ${width}×$height，请改用 HEVC 或换用更小的素材",
            )
        }

        val rateOk = runCatching {
            caps.areSizeAndRateSupported(width, height, frameRate.toDouble())
        }.getOrDefault(true)
        if (rateOk) return frameRate

        val maxRate = runCatching {
            caps.getSupportedFrameRatesFor(width, height).upper
        }.getOrNull() ?: return frameRate
        val clamped = maxRate.toInt().coerceIn(1, frameRate)
        android.util.Log.w(
            TAG,
            "$label 不支持 ${width}x$height@${frameRate}fps，帧率降为 $clamped",
        )
        return clamped
    }

    /**
     * 决定输出编码器。
     *
     * * 显式指定 hevc / h264 时严格按指定来，设备没有就报错，不偷偷替换；
     * * auto 时跟随源编码，HEVC 源优先 HEVC，但没有 HEVC 编码器就回退 H.264。
     */
    private fun resolveEncoderMime(requested: String, sourceMime: String): String {
        val hevc = MediaFormat.MIMETYPE_VIDEO_HEVC
        val avc = MediaFormat.MIMETYPE_VIDEO_AVC
        val want = when (requested) {
            "hevc" -> hevc
            "h264" -> avc
            else -> if (sourceMime.equals(hevc, ignoreCase = true)) hevc else avc
        }
        if (hasSurfaceEncoder(want)) return want
        if (requested == "auto" && want == hevc && hasSurfaceEncoder(avc)) return avc
        throw IllegalStateException(
            if (want == hevc) "这台设备没有可用的 HEVC 编码器" else "这台设备没有可用的 H.264 编码器",
        )
    }

    private fun hasSurfaceEncoder(mime: String): Boolean {
        return try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            list.codecInfos.any { info ->
                info.isEncoder && info.supportedTypes.any { type ->
                    type.equals(mime, ignoreCase = true) &&
                        info.getCapabilitiesForType(type)
                            .colorFormats
                            .any { it == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface }
                }
            }
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 原音轨直通（不解码、不重编码）。
     *
     * 这里刻意用一个**独立的 MediaExtractor**：视频解码循环已经把原来那个 extractor
     * 读到了 EOS，复用它在部分设备上会让 readSampleData 抛出没有消息的
     * IllegalArgumentException。独立实例 + 按 mime 重新定位音轨，最稳。
     */
    private fun copyAudio(
        inputPath: String,
        audioFormat: MediaFormat?,
        info: MediaCodec.BufferInfo,
    ) {
        if (audioFormat == null || audioTrackIndex < 0 || !muxerStarted) return

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(inputPath)

            var track = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i)
                    .getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    track = i
                    break
                }
            }
            if (track < 0) return
            extractor.selectTrack(track)

            var capacity = AUDIO_BUFFER_SIZE
            if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                capacity = maxOf(
                    capacity,
                    audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE),
                )
            }
            var buffer = ByteBuffer.allocateDirect(capacity)

            while (true) {
                buffer.clear()
                val size = try {
                    extractor.readSampleData(buffer, 0)
                } catch (_: IllegalArgumentException) {
                    // 少数设备在缓冲区装不下这一帧时会抛无消息的 IAE：扩容后重读一次
                    if (capacity > MAX_AUDIO_BUFFER_SIZE) throw
                    capacity *= 2
                    buffer = ByteBuffer.allocateDirect(capacity)
                    android.util.Log.w(TAG, "音轨读取失败，缓冲区扩到 $capacity 字节重试")
                    continue
                }
                if (size < 0) break
                info.set(0, size, extractor.sampleTime, extractor.sampleFlags)
                muxer!!.writeSampleData(audioTrackIndex, buffer, info)
                extractor.advance()
            }
        } finally {
            runCatching { extractor.release() }
        }
    }

    // ------------------------------------------------------------------ 渲染

    private fun rotationMatrix(rotation: Int): FloatArray {
        val matrix = FloatArray(16)
        Matrix.setIdentityM(matrix, 0)
        when (((rotation % 360) + 360) % 360) {
            90 -> {
                matrix[0] = 0f; matrix[1] = -1f
                matrix[4] = 1f; matrix[5] = 0f
                matrix[12] = 0f; matrix[13] = 1f
            }
            180 -> {
                matrix[0] = -1f; matrix[5] = -1f
                matrix[12] = 1f; matrix[13] = 1f
            }
            270 -> {
                matrix[0] = 0f; matrix[1] = 1f
                matrix[4] = -1f; matrix[5] = 0f
                matrix[12] = 1f; matrix[13] = 0f
            }
        }
        return matrix
    }

    private fun createTextureFromFile(path: String): Int {
        val handles = IntArray(1)
        GLES20.glGenTextures(1, handles, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, handles[0])
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        val bitmap = BitmapFactory.decodeFile(path)
            ?: throw IllegalStateException("水印图层读取失败")
        try {
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
        } finally {
            bitmap.recycle()
        }
        return handles[0]
    }

    private fun drawFrame(
        program: GlProgram,
        frameTexture: Int,
        watermarkTexture: Int,
        texMatrix: FloatArray,
        width: Int,
        height: Int,
        rect: FloatArray,
        opacity: Float,
    ) {
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program.programId)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, frameTexture)
        GLES20.glUniform1i(program.uniformFrame, 0)

        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, watermarkTexture)
        GLES20.glUniform1i(program.uniformWatermark, 1)

        GLES20.glUniform1f(program.uniformOpacity, opacity)
        GLES20.glUniform2f(program.uniformResolution, width.toFloat(), height.toFloat())
        GLES20.glUniform4f(program.uniformRect, rect[0], rect[1], rect[2], rect[3])
        GLES20.glUniformMatrix4fv(program.uniformTexMatrix, 1, false, texMatrix, 0)

        GLES20.glEnableVertexAttribArray(program.attribPosition)
        GLES20.glVertexAttribPointer(
            program.attribPosition,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            GlProgram.positionBuffer,
        )
        GLES20.glEnableVertexAttribArray(program.attribTexCoord)
        GLES20.glVertexAttribPointer(
            program.attribTexCoord,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            GlProgram.texCoordBuffer,
        )
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(program.attribPosition)
        GLES20.glDisableVertexAttribArray(program.attribTexCoord)
    }

    private class FrameSignal {
        private val lock = Object()
        private var available = false

        fun signal() {
            synchronized(lock) {
                available = true
                lock.notifyAll()
            }
        }

        fun await(timeoutMs: Long): Boolean {
            synchronized(lock) {
                if (!available) {
                    try {
                        lock.wait(timeoutMs)
                    } catch (_: InterruptedException) {
                        return false
                    }
                }
                val got = available
                available = false
                return got
            }
        }
    }

    /** 极简 EGL 封装。 */
    class EglCore {
        private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
        private var context: EGLContext = EGL14.EGL_NO_CONTEXT
        private var config: EGLConfig? = null
        private var windowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
        private var pbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

        fun initialize() {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (display == EGL14.EGL_NO_DISPLAY) {
                throw IllegalStateException("无法获取 EGL display")
            }
            val version = IntArray(2)
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
                throw IllegalStateException("EGL 初始化失败")
            }
            val attributes = intArrayOf(
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                0x3142, 1, // EGL_RECORDABLE_ANDROID
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val numConfigs = IntArray(1)
            if (!EGL14.eglChooseConfig(
                    display,
                    attributes,
                    0,
                    configs,
                    0,
                    1,
                    numConfigs,
                    0,
                )
            ) {
                throw IllegalStateException("EGL 配置失败")
            }
            config = configs[0] ?: throw IllegalStateException("没有可用的 EGL 配置")
            context = EGL14.eglCreateContext(
                display,
                config,
                EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
                0,
            )
            pbufferSurface = EGL14.eglCreatePbufferSurface(
                display,
                config,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE),
                0,
            )
            if (!EGL14.eglMakeCurrent(display, pbufferSurface, pbufferSurface, context)) {
                throw IllegalStateException("EGL makeCurrent 失败")
            }
        }

        fun createExternalTexture(): Int {
            val handles = IntArray(1)
            GLES20.glGenTextures(1, handles, 0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, handles[0])
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            return handles[0]
        }

        fun createWindowSurface(surface: Surface) {
            windowSurface = EGL14.eglCreateWindowSurface(
                display,
                config,
                surface,
                intArrayOf(EGL14.EGL_NONE),
                0,
            )
            if (windowSurface == EGL14.EGL_NO_SURFACE) {
                throw IllegalStateException("无法为编码器创建 EGLSurface")
            }
        }

        fun makeCurrent() {
            if (!EGL14.eglMakeCurrent(display, windowSurface, windowSurface, context)) {
                throw IllegalStateException("EGL 切换到编码器表面失败")
            }
        }

        fun present(presentationTimeNs: Long) {
            if (windowSurface == EGL14.EGL_NO_SURFACE) return
            EGLExt.eglPresentationTimeANDROID(display, windowSurface, presentationTimeNs)
            EGL14.eglSwapBuffers(display, windowSurface)
        }

        fun release() {
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    display,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT,
                )
                if (windowSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(display, windowSurface)
                    windowSurface = EGL14.EGL_NO_SURFACE
                }
                if (pbufferSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(display, pbufferSurface)
                    pbufferSurface = EGL14.EGL_NO_SURFACE
                }
                if (context != EGL14.EGL_NO_CONTEXT) {
                    EGL14.eglDestroyContext(display, context)
                    context = EGL14.EGL_NO_CONTEXT
                }
                EGL14.eglTerminate(display)
                display = EGL14.EGL_NO_DISPLAY
            }
        }
    }
}

/** 编译 Dart 传下来的着色器并缓存句柄。 */
private class GlProgram(vertexSource: String, fragmentSource: String) {
    val programId: Int
    val attribPosition: Int
    val attribTexCoord: Int
    val uniformTexMatrix: Int
    val uniformFrame: Int
    val uniformWatermark: Int
    val uniformResolution: Int
    val uniformRect: Int
    val uniformOpacity: Int

    init {
        val vertex = compile(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragment = compile(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
        programId = GLES20.glCreateProgram()
        GLES20.glAttachShader(programId, vertex)
        GLES20.glAttachShader(programId, fragment)
        GLES20.glLinkProgram(programId)
        val status = IntArray(1)
        GLES20.glGetProgramiv(programId, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(programId)
            GLES20.glDeleteProgram(programId)
            throw IllegalStateException("着色器链接失败：$log")
        }
        attribPosition = GLES20.glGetAttribLocation(programId, "aPosition")
        attribTexCoord = GLES20.glGetAttribLocation(programId, "aTexCoord")
        uniformTexMatrix = GLES20.glGetUniformLocation(programId, "uTexMatrix")
        uniformFrame = GLES20.glGetUniformLocation(programId, "uFrame")
        uniformWatermark = GLES20.glGetUniformLocation(programId, "uWatermark")
        uniformResolution = GLES20.glGetUniformLocation(programId, "uResolution")
        uniformRect = GLES20.glGetUniformLocation(programId, "uRect")
        uniformOpacity = GLES20.glGetUniformLocation(programId, "uOpacity")
    }

    private fun compile(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("着色器编译失败：$log")
        }
        return shader
    }

    companion object {
        /** 铺满裁剪空间的四边形；纹理坐标 (0,0) 对准画面左上角。 */
        val positionBuffer: FloatBuffer = floatBufferOf(
            floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f),
        )

        val texCoordBuffer: FloatBuffer = floatBufferOf(
            floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f),
        )

        private fun floatBufferOf(values: FloatArray): FloatBuffer {
            val buffer = ByteBuffer.allocateDirect(values.size * 4)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
            buffer.put(values)
            buffer.position(0)
            return buffer
        }
    }
}
