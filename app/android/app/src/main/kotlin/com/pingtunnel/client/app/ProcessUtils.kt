package com.pingtunnel.client.app

import android.system.Os
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.FileDescriptor
import java.io.InputStreamReader
import kotlin.concurrent.thread

object ProcessUtils {
    private fun buildProcessBuilder(
        command: List<String>,
        workDir: File?,
        env: Map<String, String>?
    ): ProcessBuilder {
        val builder = ProcessBuilder(command).redirectErrorStream(true)
        if (workDir != null) {
            builder.directory(workDir)
        }
        if (env != null) {
            builder.environment().putAll(env)
        }
        return builder
    }

    fun startProcess(
        tag: String,
        command: List<String>,
        workDir: File? = null,
        env: Map<String, String>? = null
    ): Process {
        Log.i(tag, "Starting: ${command.joinToString(" ")}")
        val builder = buildProcessBuilder(command, workDir, env)
        val process = builder.start()
        streamLogs(tag, process)
        return process
    }

    fun startProcessWithStdinFd(
        tag: String,
        command: List<String>,
        workDir: File? = null,
        stdinFd: FileDescriptor? = null,
        env: Map<String, String>? = null
    ): Process {
        Log.i(tag, "Starting: ${command.joinToString(" ")}")
        val builder = buildProcessBuilder(command, workDir, env)

        var stdinDup: FileDescriptor? = null
        if (stdinFd != null) {
            stdinDup = Os.dup(FileDescriptor.`in`)
            Os.dup2(stdinFd, 0)
            builder.redirectInput(ProcessBuilder.Redirect.INHERIT)
        }

        val process = try {
            builder.start()
        } finally {
            if (stdinDup != null) {
                Os.dup2(stdinDup, 0)
                Os.close(stdinDup)
            }
        }

        streamLogs(tag, process)
        return process
    }

    fun stopProcess(process: Process?) {
        if (process == null) return
        process.destroy()
        thread(start = true, name = "proc-wait") {
            try {
                process.waitFor()
            } catch (_: Exception) {
            }
        }
        thread(start = true, name = "proc-kill") {
            try {
                Thread.sleep(1500)
                process.destroyForcibly()
            } catch (_: Exception) {
            }
        }
    }

    private fun streamLogs(tag: String, process: Process) {
        thread(start = true, name = "$tag-logger") {
            val reader = BufferedReader(InputStreamReader(process.inputStream))
            try {
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isNotEmpty()) {
                        Log.i(tag, line)
                    }
                }
            } catch (e: Exception) {
                Log.d(tag, "Log stream closed: $e")
            }
        }
    }
}
