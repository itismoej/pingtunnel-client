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
    private var currentConfig: TunnelConfig? = null
    private lateinit var installer: BinaryInstaller

    override fun onCreate() {
        super.onCreate()
        installer = BinaryInstaller(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            ServiceState.vpnRunning = false
            ServiceState.notifyStateChanged(this)
            stopSelf()
            return START_NOT_STICKY
        }

        val action = intent.action
        if (action == Constants.ACTION_STOP) {
            stopVpn()
            currentConfig = null
            ServiceState.vpnRunning = false
            ServiceState.notifyStateChanged(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        if (action == Constants.ACTION_RESTORE_NOTIFICATION) {
            if (ServiceState.vpnRunning && pingtunnelProcess != null) {
                startOrUpdateForeground(currentConfig)
                return START_STICKY
            }
            return START_NOT_STICKY
        }

        val config = TunnelConfig.fromIntent(intent)
        currentConfig = config
        startOrUpdateForeground(config)

        try {
            startVpn(config)
            ServiceState.vpnRunning = true
            ServiceState.proxyRunning = false
            ServiceState.notifyStateChanged(this)
        } catch (e: Exception) {
            Log.e("PingtunnelVPN", "Failed to start", e)
            ServiceState.vpnRunning = false
            ServiceState.notifyStateChanged(this)
            stopSelf()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        stopVpn()
        currentConfig = null
        ServiceState.vpnRunning = false
        ServiceState.notifyStateChanged(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
        ServiceState.vpnRunning = false
        ServiceState.notifyStateChanged(this)
        super.onRevoke()
    }

    private fun startVpn(config: TunnelConfig) {
        val builder = Builder()
            .setSession("Pingtunnel")
            .setMtu(1500)
            .addAddress("198.18.0.1", 15)
            .addRoute("0.0.0.0", 0)

        val isProxyPerAppMode = config.mode.equals("proxy_per_app", ignoreCase = true)

        if (!config.dns.isNullOrBlank()) {
            config.dns.split(",").map { it.trim() }.filter { it.isNotEmpty() }.forEach {
                builder.addDnsServer(it)
            }
        } else {
            builder.addDnsServer("1.1.1.1")
            builder.addDnsServer("8.8.8.8")
        }

        if (isProxyPerAppMode) {
            val selectedPackages = config.proxyPerAppPackages
                .map { it.trim() }
                .filter { it.isNotEmpty() && it != packageName }
                .distinct()

            if (selectedPackages.isEmpty()) {
                throw IllegalArgumentException("Select at least one app for Proxy per app mode")
            }

            var allowedCount = 0
            for (appPackage in selectedPackages) {
                try {
                    builder.addAllowedApplication(appPackage)
                    allowedCount += 1
                } catch (e: Exception) {
                    Log.w("PingtunnelVPN", "Failed to allow package $appPackage", e)
                }
            }
            if (allowedCount == 0) {
                throw IllegalArgumentException("None of the selected apps are available")
            }
        } else {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {
            }
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
        ServiceState.vpnRunning = false
        ServiceState.notifyStateChanged(this)

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

    private fun startOrUpdateForeground(config: TunnelConfig?) {
        val disconnectIntent = ServiceNotifications.createServiceActionIntent(
            this,
            PingtunnelVpnService::class.java,
            Constants.ACTION_STOP,
            2001
        )
        val restoreIntent = ServiceNotifications.createServiceActionIntent(
            this,
            PingtunnelVpnService::class.java,
            Constants.ACTION_RESTORE_NOTIFICATION,
            2002
        )
        val serverHost = config?.serverHost?.takeIf { it.isNotBlank() } ?: "active tunnel"
        val isProxyPerAppMode = config?.mode?.equals("proxy_per_app", ignoreCase = true) == true
        val notification = ServiceNotifications.createForegroundNotification(
            this,
            if (isProxyPerAppMode) "Pingtunnel Proxy per app" else "Pingtunnel VPN",
            "Connected to $serverHost",
            disconnectIntent,
            restoreIntent
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(2, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(2, notification)
        }
    }
}
