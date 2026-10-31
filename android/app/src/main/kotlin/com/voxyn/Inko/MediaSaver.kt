package com.voxyn.Inko

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.content.ContentValues
import android.content.Context
import java.io.File

/**
 * 落盘工具：把合成结果写进系统相册。
 *
 * Android 10 起走 MediaStore 分区存储，不需要任何权限；
 * Android 8/9 退回 App 私有外部目录（同样不需要权限）。
 */
class MediaSaver(private val context: Context) {

    fun saveJpeg(bytes: ByteArray, fileName: String, album: String): String {
        val bitmap =
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                ?: throw IllegalStateException("图片解码失败")

        return try {
            writeToMediaStore(bitmap, fileName, album)
        } finally {
            bitmap.recycle()
        }
    }

    private fun writeToMediaStore(bitmap: Bitmap, fileName: String, album: String): String {
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
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

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, done, null, null)
        }
        return uri.toString()
    }

    /** 视频导出目标：优先交给 MediaStore，失败时退回缓存目录。 */
    fun createVideoFile(fileName: String, album: String): OutputTarget {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_MOVIES}/$album",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                values,
            )
            if (uri != null) {
                val pfd = resolver.openFileDescriptor(uri, "w")
                if (pfd != null) {
                    return OutputTarget(
                        fileDescriptor = pfd,
                        display = uri.toString(),
                        publish = {
                            val done = ContentValues().apply {
                                put(MediaStore.MediaColumns.IS_PENDING, 0)
                            }
                            resolver.update(uri, done, null, null)
                        },
                        abort = { runCatching { resolver.delete(uri, null, null) } },
                    )
                }
                resolver.delete(uri, null, null)
            }
        }

        val dir = File(
            context.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: context.filesDir,
            album,
        )
        dir.mkdirs()
        val file = File(dir, fileName)
        return OutputTarget(
            plainFile = file,
            display = file.absolutePath,
            publish = {},
            abort = { runCatching { file.delete() } },
        )
    }

    class OutputTarget(
        val fileDescriptor: android.os.ParcelFileDescriptor? = null,
        val plainFile: File? = null,
        val display: String,
        val publish: () -> Unit,
        val abort: () -> Unit,
    )
}
