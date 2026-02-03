package com.pingtunnel.client.app

import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.FileDescriptor

class PingtunnelVpnService : VpnService() {
    private var pingtunnelProcess: Process? = null
    private var tun2socksProcess: Process? = null
    private var tunFd: FileDescriptor? = null
    private var tunParcel: ParcelFileDescriptor? = null
    private lateinit var installer: BinaryInstaller

    override fun onCreate() {
        super.onCreate()
        installer = BinaryInstaller(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        val action = intent.action
        if (action == Constants.ACTION_STOP) {
            stopVpn()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        val config = TunnelConfig.fromIntent(intent)
        val notification = ServiceNotifications.createForegroundNotification(
            this,
            "Pingtunnel VPN",
            "Connected to ${config.serverHost}"
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(2, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(2, notification)
        }

        try {
            startVpn(config)
        } catch (e: Exception) {
            Log.e("PingtunnelVPN", "Failed to start", e)
            stopSelf()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        stopVpn()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
        super.onRevoke()
    }

    private fun startVpn(config: TunnelConfig) {
        val builder = Builder()
            .setSession("Pingtunnel")
            .setMtu(1500)
            .addAddress("198.18.0.1", 15)
            .addRoute("0.0.0.0", 0)

        if (!config.dns.isNullOrBlank()) {
            config.dns.split(",").map { it.trim() }.filter { it.isNotEmpty() }.forEach {
                builder.addDnsServer(it)
            }
        } else {
            builder.addDnsServer("1.1.1.1")
            builder.addDnsServer("8.8.8.8")
        }

        try {
            builder.addDisallowedApplication(packageName)
        } catch (_: Exception) {
        }

        tunParcel = builder.establish()
            ?: throw IllegalStateException("Failed to establish VPN")

        val parcel = tunParcel ?: throw IllegalStateException("Failed to acquire TUN fd")
        val fd = parcel.fileDescriptor
        try {
            Os.fcntlInt(fd, OsConstants.F_SETFD, 0)
        } catch (_: Exception) {
        }
        tunFd = fd

        pingtunnelProcess = startPingtunnel(config)
        tun2socksProcess = startTun2socks(config, tunFd!!)
    }

    private fun stopVpn() {
        ProcessUtils.stopProcess(tun2socksProcess)
        ProcessUtils.stopProcess(pingtunnelProcess)
        tun2socksProcess = null
        pingtunnelProcess = null

        tunFd = null

        try {
            tunParcel?.close()
        } catch (_: Exception) {
        }
        tunParcel = null
    }

    private fun startPingtunnel(config: TunnelConfig): Process {
        val bin = installer.ensureBinary("pingtunnel")
        val args = buildPingtunnelArgs(bin.absolutePath, config)
        return ProcessUtils.startProcess("pingtunnel", args, filesDir)
    }

    private fun startTun2socks(config: TunnelConfig, fd: FileDescriptor): Process {
        val bin = installer.ensureBinary("tun2socks")
        val proxy = "socks5://127.0.0.1:${config.localSocksPort}"
        val args = listOf(
            bin.absolutePath,
            "--device",
            "fd://0",
            "--proxy",
            proxy,
            "--loglevel",
            "info"
        )
        return ProcessUtils.startProcessWithStdinFd("tun2socks", args, filesDir, fd)
    }
}
