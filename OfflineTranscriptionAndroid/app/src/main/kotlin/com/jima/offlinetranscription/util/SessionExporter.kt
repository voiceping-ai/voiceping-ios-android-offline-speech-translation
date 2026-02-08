package com.voiceping.offlinetranscription.util

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import com.voiceping.offlinetranscription.data.TranscriptionEntity
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Exports a transcription session as a ZIP bundle containing:
 * - transcript.txt
 * - metadata.json
 * - audio.wav (if available)
 */
object SessionExporter {

    data class ExportResult(
        val zipFile: File,
        val shareIntent: Intent
    )

    fun export(
        context: Context,
        record: TranscriptionEntity,
        audioFile: File?
    ): ExportResult {
        val exportDir = File(context.cacheDir, "exports")
        exportDir.mkdirs()

        val dateStr = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(record.createdAt))
        val zipFile = File(exportDir, "session_${dateStr}.zip")

        ZipOutputStream(BufferedOutputStream(FileOutputStream(zipFile))).use { zos ->
            // transcript.txt
            zos.putNextEntry(ZipEntry("transcript.txt"))
            zos.write(record.text.toByteArray(Charsets.UTF_8))
            zos.closeEntry()

            // metadata.json
            val metadata = JSONObject().apply {
                put("id", record.id)
                put("createdAt", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).format(Date(record.createdAt)))
                put("durationSeconds", record.durationSeconds)
                put("modelUsed", record.modelUsed)
                record.language?.let { put("language", it) }
            }
            zos.putNextEntry(ZipEntry("metadata.json"))
            zos.write(metadata.toString(2).toByteArray(Charsets.UTF_8))
            zos.closeEntry()

            // audio.wav (if available)
            if (audioFile != null && audioFile.exists()) {
                zos.putNextEntry(ZipEntry("audio.wav"))
                FileInputStream(audioFile).use { fis ->
                    fis.copyTo(zos, bufferSize = 8192)
                }
                zos.closeEntry()
            }
        }

        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            zipFile
        )

        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "application/zip"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        return ExportResult(zipFile, Intent.createChooser(shareIntent, "Export session"))
    }
}
