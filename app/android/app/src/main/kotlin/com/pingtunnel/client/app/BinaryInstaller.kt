package com.pingtunnel.client.app

import android.content.Context
import android.os.Build
import android.system.Os
import android.util.Log
import java.io.File

class BinaryInstaller(private val context: Context) {
    fun ensureBinary(name: String): File {
        val nativePath = File(context.applicationInfo.nativeLibraryDir, "lib$name.so")
        if (nativePath.exists()) {
            if (nativePath.canExecute()) {
                Log.i("Pingtunnel", "Using native lib binary: ${nativePath.absolutePath}")
                return nativePath
            }
            Log.w(
                "Pingtunnel",
                "Native binary is not executable; copying to app storage: ${nativePath.absolutePath}"
            )

            val arch = resolveArch()
            val primaryDir = File(context.filesDir, "bin/$name/$arch")
            val primary = installBinary(primaryDir, name, nativePath)
            if (primary.canExecute()) {
                return primary
            }

            val fallbackDir = File(context.codeCacheDir, "bin/$name/$arch")
            val fallback = installBinary(fallbackDir, name, nativePath)
            if (fallback.canExecute()) {
                return fallback
            }

            throw IllegalStateException("Binary is not executable: ${primary.absolutePath}")
        }

        throw IllegalStateException("Missing native lib binary: ${nativePath.absolutePath}")
    }

    private fun resolveArch(): String {
        val abis = Build.SUPPORTED_ABIS.map { it.lowercase() }
        return when {
            abis.any { it.contains("arm64") } -> "arm64"
            abis.any { it.contains("armeabi") || it.contains("armv7") } -> "arm"
            else -> "arm64"
        }
    }

    private fun copyFile(source: File, outFile: File) {
        source.inputStream().use { input ->
            outFile.outputStream().use { output ->
                input.copyTo(output)
            }
        }
    }

    private fun installBinary(outDir: File, name: String, source: File): File {
        if (!outDir.exists()) {
            outDir.mkdirs()
        }
        val outFile = File(outDir, name)
        if (!outFile.exists() || outFile.length() != source.length()) {
            copyFile(source, outFile)
        }
        try {
            outFile.setReadable(true, false)
            outFile.setWritable(true, false)
            outFile.setExecutable(true, false)
            Os.chmod(outFile.absolutePath, 493)
        } catch (e: Exception) {
            Log.w("Pingtunnel", "chmod failed for ${outFile.absolutePath}: $e")
        }
        Log.i(
            "Pingtunnel",
            "Binary ${outFile.absolutePath} size=${outFile.length()} exec=${outFile.canExecute()}"
        )
        return outFile
    }
}
