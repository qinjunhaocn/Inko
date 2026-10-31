package com.voxyn.Inko

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/**
 * 落盘工具。
 *
 * 照片直接写进系统相册；视频则**先 mux 到缓存里的临时文件**，成功后再整体搬进相册。
 * 这样做是因为 MediaMuxer 要求可随机寻址的 FileDescriptor，而相册 ContentProvider
 * 给出的 fd 并不保证可 seek；先落临时文件可以彻底绕开这个坑。
 */
class MediaSaver(private val context: Context) {

    fun saveJpeg(bytes: ByteArray, fileName: String, album: String): String {
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalStateException("图片解码失败")
        return try {
            writeImage(bitmap, fileName, album)
        } finally {
            bitmap.recycle()
        }
    }

    /** 视频输出目标。 */
    fun createVideoTarget(fileName: String, album: String): OutputTarget {
        val temp = File(context.cacheDir, "inko_export_${System.currentTimeMillis()}.mp4")
        val resolver = context.contentResolver

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_MOVIES}/$album",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri: Uri? = resolver.insert(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                values,
            )
            if (uri != null) {
                return OutputTarget(
                    muxerPath = temp.absolutePath,
                    display = uri.toString(),
                    commit = {
                        resolver.openOutputStream(uri)?.use { output ->
                            temp.inputStream().use { input -> input.copyTo(output) }
                        } ?: throw IllegalStateException("无法写入相册")
                        val done = ContentValues().apply {
                            put(MediaStore.MediaColumns.IS_PENDING, 0)
                        }
                        resolver.update(uri, done, null, null)
                        temp.delete()
                    },
                    abort = {
                        runCatching { resolver.delete(uri, null, null) }
                        temp.delete()
                    },
                )
            }
        }

        // Android 8/9 或相册插入失败：落到 App 私有外部目录，同样不需要权限
        val dir = File(
            context.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: context.filesDir,
            album,
        )
        dir.mkdirs()
        val destination = File(dir, fileName)
        return OutputTarget(
            muxerPath = temp.absolutePath,
            display = destination.absolutePath,
            commit = {
                destination.outputStream().use { output ->
                    temp.inputStream().use { input -> input.copyTo(output) }
                }
                temp.delete()
            },
            abort = { temp.delete() },
        )
    }

    class OutputTarget(
        /** MediaMuxer 直接写这个路径（缓存目录，可 seek） */
        val muxerPath: String,
        /** 给用户看的落盘位置 */
        val display: String,
        val commit: () -> Unit,
        val abort: () -> Unit,
    )

    private fun writeImage(bitmap: Bitmap, fileName: String, album: String): String {
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/$album",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val resolver = context.contentResolver
        val uri: Uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("无法在相册中创建文件")

        resolver.openOutputStream(uri)?.use { stream ->
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 95, stream)) {
                throw IllegalStateException("图片编码失败")
            }
        } ?: throw IllegalStateException("无法写入相册")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, done, null, null)
        }
        return uri.toString()
    }
}
