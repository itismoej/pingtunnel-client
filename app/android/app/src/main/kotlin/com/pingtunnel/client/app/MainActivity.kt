package com.pingtunnel.client.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private val requestVpnCode = 10101
    private val requestNotificationsCode = 10102

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        maybeRequestNotificationPermission()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Constants.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepareVpn" -> handlePrepareVpn(result)
                    "startProxy" -> {
                        val config = TunnelConfig.fromMap(call.arguments as Map<*, *>)
                        startProxy(config)
                        result.success(true)
                    }
                    "startVpn" -> {
                        val config = TunnelConfig.fromMap(call.arguments as Map<*, *>)
                        startVpn(config)
                        result.success(true)
                    }
                    "stop" -> {
                        stopServices()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handlePrepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingResult = result
            startActivityForResult(intent, requestVpnCode)
        } else {
            result.success(true)
        }
    }

    private fun maybeRequestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                requestNotificationsCode
            )
        }
    }

    private fun startProxy(config: TunnelConfig) {
        val intent = Intent(this, PingtunnelProxyService::class.java).apply {
            action = Constants.ACTION_START
            putExtras(config)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    private fun startVpn(config: TunnelConfig) {
        val intent = Intent(this, PingtunnelVpnService::class.java).apply {
            action = Constants.ACTION_START
            putExtras(config)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    private fun stopServices() {
        val proxyIntent = Intent(this, PingtunnelProxyService::class.java).apply {
            action = Constants.ACTION_STOP
        }
        val vpnIntent = Intent(this, PingtunnelVpnService::class.java).apply {
            action = Constants.ACTION_STOP
        }
        startService(proxyIntent)
        startService(vpnIntent)
        stopService(proxyIntent)
        stopService(vpnIntent)
    }

    private fun Intent.putExtras(config: TunnelConfig) {
        putExtra(Constants.EXTRA_SERVER_HOST, config.serverHost)
        config.serverPort?.let { putExtra(Constants.EXTRA_SERVER_PORT, it) }
        putExtra(Constants.EXTRA_LOCAL_PORT, config.localSocksPort)
        config.key?.let { putExtra(Constants.EXTRA_KEY, it) }
        putExtra(Constants.EXTRA_MODE, config.mode)
        config.encryptMode?.let { putExtra(Constants.EXTRA_ENCRYPT_MODE, it) }
        config.encryptKey?.let { putExtra(Constants.EXTRA_ENCRYPT_KEY, it) }
        config.interfaceName?.let { putExtra(Constants.EXTRA_IFACE, it) }
        config.tunDevice?.let { putExtra(Constants.EXTRA_TUN, it) }
        config.dns?.let { putExtra(Constants.EXTRA_DNS, it) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == requestVpnCode) {
            pendingResult?.success(resultCode == Activity.RESULT_OK)
            pendingResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
