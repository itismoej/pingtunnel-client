package com.pingtunnel.client.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.core.content.ContextCompat

class PingtunnelTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()

        val wasRunning = ServiceState.isAnyRunning()
        if (wasRunning) {
            stopServices()
            setTileState(false)
            ServiceState.notifyStateChanged(this)
            return
        }

        val config = LastTunnelConfigStore.load(this)
        if (config == null) {
            openApp()
            setTileState(false)
            return
        }

        val mode = config.mode.lowercase()
        if (mode == "vpn" || mode == "proxy_per_app") {
            val prepareIntent = VpnService.prepare(this)
            if (prepareIntent != null) {
                openApp()
                setTileState(false)
                return
            } else {
                startVpn(config)
            }
        } else {
            startProxy(config)
        }

        setTileState(true)
        ServiceState.notifyStateChanged(this)
    }

    private fun updateTileState() {
        setTileState(ServiceState.isAnyRunning())
    }

    private fun setTileState(active: Boolean) {
        val tile = qsTile ?: return
        tile.icon = Icon.createWithResource(this, R.drawable.ic_stat_ping)
        tile.label = getString(R.string.quick_tile_label)
        tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    private fun openApp() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_SINGLE_TOP or
            Intent.FLAG_ACTIVITY_CLEAR_TOP
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            startActivityAndCollapse(launchIntent)
        } else {
            startActivity(launchIntent)
        }
    }

    private fun startProxy(config: TunnelConfig) {
        val intent = Intent(this, PingtunnelProxyService::class.java).apply {
            action = Constants.ACTION_START
            putTunnelExtras(config)
        }
        ContextCompat.startForegroundService(this, intent)
    }

    private fun startVpn(config: TunnelConfig) {
        val intent = Intent(this, PingtunnelVpnService::class.java).apply {
            action = Constants.ACTION_START
            putTunnelExtras(config)
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

    private fun Intent.putTunnelExtras(config: TunnelConfig) {
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

    companion object {
        fun requestRefresh(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                return
            }
            TileService.requestListeningState(
                context,
                ComponentName(context, PingtunnelTileService::class.java)
            )
        }
    }
}
