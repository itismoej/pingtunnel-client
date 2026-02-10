package com.pingtunnel.client.app

object Constants {
    const val CHANNEL = "pingtunnel"
    const val ACTION_START = "com.pingtunnel.client.app.START"
    const val ACTION_STOP = "com.pingtunnel.client.app.STOP"
    const val ACTION_RESTORE_NOTIFICATION = "com.pingtunnel.client.app.RESTORE_NOTIFICATION"
    const val PREFS_LAST_CONFIG = "last_tunnel_config"

    const val EXTRA_SERVER_HOST = "serverHost"
    const val EXTRA_SERVER_PORT = "serverPort"
    const val EXTRA_LOCAL_PORT = "localSocksPort"
    const val EXTRA_KEY = "key"
    const val EXTRA_MODE = "mode"
    const val EXTRA_ENCRYPT_MODE = "encryptMode"
    const val EXTRA_ENCRYPT_KEY = "encryptKey"
    const val EXTRA_IFACE = "interfaceName"
    const val EXTRA_TUN = "tunDevice"
    const val EXTRA_DNS = "dns"
}
