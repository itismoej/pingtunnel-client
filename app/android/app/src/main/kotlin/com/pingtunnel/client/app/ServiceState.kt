package com.pingtunnel.client.app

import android.content.Context

object ServiceState {
    @Volatile
    var proxyRunning: Boolean = false

    @Volatile
    var vpnRunning: Boolean = false

    fun isAnyRunning(): Boolean = proxyRunning || vpnRunning

    fun notifyStateChanged(context: Context) {
        PingtunnelTileService.requestRefresh(context)
    }
}
