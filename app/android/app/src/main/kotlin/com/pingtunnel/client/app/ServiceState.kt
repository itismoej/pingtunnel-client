package com.pingtunnel.client.app

object ServiceState {
    @Volatile
    var proxyRunning: Boolean = false

    @Volatile
    var vpnRunning: Boolean = false

    fun isAnyRunning(): Boolean = proxyRunning || vpnRunning
}
