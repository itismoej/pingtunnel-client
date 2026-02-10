package com.pingtunnel.client.app

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

class PingtunnelProxyService : Service() {
    private var pingtunnelProcess: Process? = null
    private var currentConfig: TunnelConfig? = null
    private lateinit var installer: BinaryInstaller

    override fun onCreate() {
        super.onCreate()
        installer = BinaryInstaller(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            ServiceState.proxyRunning = false
            ServiceState.notifyStateChanged(this)
            stopSelf()
            return START_NOT_STICKY
        }

        val action = intent.action
        if (action == Constants.ACTION_STOP) {
            ProcessUtils.stopProcess(pingtunnelProcess)
            pingtunnelProcess = null
            currentConfig = null
            ServiceState.proxyRunning = false
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
            if (ServiceState.proxyRunning && pingtunnelProcess != null) {
                startOrUpdateForeground(currentConfig)
                return START_STICKY
            }
            return START_NOT_STICKY
        }

        val config = TunnelConfig.fromIntent(intent)
        currentConfig = config
        startOrUpdateForeground(config)

        try {
            pingtunnelProcess = startPingtunnel(config)
            ServiceState.proxyRunning = true
            ServiceState.vpnRunning = false
            ServiceState.notifyStateChanged(this)
        } catch (e: Exception) {
            Log.e("PingtunnelProxy", "Failed to start", e)
            ServiceState.proxyRunning = false
            ServiceState.notifyStateChanged(this)
            stopSelf()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        ProcessUtils.stopProcess(pingtunnelProcess)
        pingtunnelProcess = null
        currentConfig = null
        ServiceState.proxyRunning = false
        ServiceState.notifyStateChanged(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startPingtunnel(config: TunnelConfig): Process {
        val bin = installer.ensureBinary("pingtunnel")
        val args = buildPingtunnelArgs(bin.absolutePath, config)
        return ProcessUtils.startProcess("pingtunnel", args, filesDir)
    }

    private fun startOrUpdateForeground(config: TunnelConfig?) {
        val disconnectIntent = ServiceNotifications.createServiceActionIntent(
            this,
            PingtunnelProxyService::class.java,
            Constants.ACTION_STOP,
            1001
        )
        val restoreIntent = ServiceNotifications.createServiceActionIntent(
            this,
            PingtunnelProxyService::class.java,
            Constants.ACTION_RESTORE_NOTIFICATION,
            1002
        )
        val serverHost = config?.serverHost?.takeIf { it.isNotBlank() } ?: "active tunnel"
        val notification = ServiceNotifications.createForegroundNotification(
            this,
            "Pingtunnel Proxy",
            "Connected to $serverHost",
            disconnectIntent,
            restoreIntent
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1, notification)
        }
    }
}
