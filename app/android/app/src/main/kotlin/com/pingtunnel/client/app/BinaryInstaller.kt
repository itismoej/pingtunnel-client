package com.pingtunnel.client.app

import android.content.Context
import android.os.Build
import android.system.Os
import android.util.Log
import java.io.File

class BinaryInstaller(private val context: Context) {
    fun ensureBinary(name: String): File {
        val nativePath = File(context.applicationInfo.nativeLibraryDir, "lib$name.so")
        if (nativePath.exists() && nativePath.canExecute()) {
            Log.i("Pingtunnel", "Using native lib binary: ${nativePath.absolutePath}")
            return nativePath
        }

        val arch = resolveArch()
        val ext = ""

        val primaryDir = File(context.filesDir, "bin/$name/$arch")
        val primary = installBinary(primaryDir, name, arch, ext)
        if (primary.canExecute()) {
            return primary
        }

        val fallbackDir = File(context.codeCacheDir, "bin/$name/$arch")
        val fallback = installBinary(fallbackDir, name, arch, ext)
        if (fallback.canExecute()) {
            return fallback
        }

        throw IllegalStateException("Binary is not executable: ${primary.absolutePath}")
    }

    private fun resolveArch(): String {
        val abis = Build.SUPPORTED_ABIS.map { it.lowercase() }
        return when {
            abis.any { it.contains("arm64") } -> "arm64"
            abis.any { it.contains("armeabi") || it.contains("armv7") } -> "arm"
            else -> "arm64"
        }
    }

    private fun copyAsset(assetPath: String, outFile: File) {
        context.assets.open(assetPath).use { input ->
            outFile.outputStream().use { output ->
                input.copyTo(output)
            }
        }
    }

    private fun installBinary(outDir: File, name: String, arch: String, ext: String): File {
        if (!outDir.exists()) {
            outDir.mkdirs()
        }
        val outFile = File(outDir, "$name$ext")
        if (!outFile.exists()) {
            val assetCandidates = listOf(
                "flutter_assets/assets/binaries/$name/android-$arch/$name$ext",
                "binaries/$name/android-$arch/$name$ext"
            )
            var lastError: Exception? = null
            for (assetPath in assetCandidates) {
                try {
                    copyAsset(assetPath, outFile)
                    lastError = null
                    break
                } catch (e: Exception) {
                    lastError = e
                }
            }
            if (lastError != null) {
                throw IllegalStateException(
                    "Missing Android binary: ${assetCandidates.joinToString()}",
                    lastError
                )
            }
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
