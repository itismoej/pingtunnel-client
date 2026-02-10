package com.pingtunnel.client.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.max

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
                    "isRunning" -> {
                        result.success(ServiceState.isAnyRunning())
                    }
                    "listLaunchableApps" -> {
                        result.success(listLaunchableApps())
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
        LastTunnelConfigStore.save(this, config)
        val intent = Intent(this, PingtunnelProxyService::class.java).apply {
            action = Constants.ACTION_START
            putExtras(config)
        }
        ContextCompat.startForegroundService(this, intent)
        ServiceState.notifyStateChanged(this)
    }

    private fun startVpn(config: TunnelConfig) {
        LastTunnelConfigStore.save(this, config)
        val intent = Intent(this, PingtunnelVpnService::class.java).apply {
            action = Constants.ACTION_START
            putExtras(config)
        }
        ContextCompat.startForegroundService(this, intent)
        ServiceState.notifyStateChanged(this)
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
        ServiceState.notifyStateChanged(this)
    }

    private fun listLaunchableApps(): List<Map<String, Any?>> {
        val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val seen = LinkedHashMap<String, android.content.pm.ResolveInfo>()
        val resolves = packageManager.queryIntentActivities(launcherIntent, 0)
        for (resolveInfo in resolves) {
            val activityInfo = resolveInfo.activityInfo ?: continue
            val appPackage = activityInfo.packageName ?: continue
            if (appPackage == packageName) {
                continue
            }
            if (seen.containsKey(appPackage)) {
                continue
            }
            seen[appPackage] = resolveInfo
        }
        return seen.values
            .sortedWith(
                compareBy<android.content.pm.ResolveInfo>(
                    {
                        resolveInfoLabel(it).ifEmpty {
                            it.activityInfo?.packageName.orEmpty()
                        }.lowercase()
                    },
                    { it.activityInfo?.packageName.orEmpty().lowercase() }
                )
            )
            .map { resolveInfo ->
                val appPackage = resolveInfo.activityInfo?.packageName.orEmpty()
                val label = resolveInfoLabel(resolveInfo).ifEmpty { appPackage }
                mapOf(
                    "packageName" to appPackage,
                    "label" to label,
                    "iconPng" to renderAppIconPng(resolveInfo)
                )
            }
    }

    private fun resolveInfoLabel(resolveInfo: android.content.pm.ResolveInfo): String {
        return resolveInfo.loadLabel(packageManager)?.toString()?.trim().orEmpty()
    }

    private fun renderAppIconPng(resolveInfo: android.content.pm.ResolveInfo): ByteArray? {
        return try {
            val drawable = resolveInfo.loadIcon(packageManager) ?: return null
            val baseBitmap = when (drawable) {
                is BitmapDrawable -> drawable.bitmap
                else -> {
                    val width = max(1, if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 96)
                    val height = max(1, if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 96)
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bitmap)
                    drawable.setBounds(0, 0, canvas.width, canvas.height)
                    drawable.draw(canvas)
                    bitmap
                }
            }

            val targetSize = 64
            val bitmap = if (baseBitmap.width != targetSize || baseBitmap.height != targetSize) {
                Bitmap.createScaledBitmap(baseBitmap, targetSize, targetSize, true)
            } else {
                baseBitmap
            }

            val output = ByteArrayOutputStream()
            val ok = bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            if (bitmap !== baseBitmap) {
                bitmap.recycle()
            }
            if (!ok) null else output.toByteArray()
        } catch (_: Exception) {
            null
        }
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
        putStringArrayListExtra(
            Constants.EXTRA_PROXY_PER_APP_PACKAGES,
            ArrayList(config.proxyPerAppPackages)
        )
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
