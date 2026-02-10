package com.pingtunnel.client.app

import android.content.Context

object LastTunnelConfigStore {
    private const val KEY_HAS_VALUE = "hasValue"
    private const val KEY_HAS_SERVER_PORT = "hasServerPort"
    private const val KEY_HAS_KEY = "hasKey"

    fun save(context: Context, config: TunnelConfig) {
        val prefs = context.getSharedPreferences(Constants.PREFS_LAST_CONFIG, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_HAS_VALUE, true)
            .putString(Constants.EXTRA_SERVER_HOST, config.serverHost)
            .putBoolean(KEY_HAS_SERVER_PORT, config.serverPort != null)
            .putInt(Constants.EXTRA_SERVER_PORT, config.serverPort ?: 0)
            .putInt(Constants.EXTRA_LOCAL_PORT, config.localSocksPort)
            .putBoolean(KEY_HAS_KEY, config.key != null)
            .putInt(Constants.EXTRA_KEY, config.key ?: 0)
            .putString(Constants.EXTRA_MODE, config.mode)
            .putString(Constants.EXTRA_ENCRYPT_MODE, config.encryptMode)
            .putString(Constants.EXTRA_ENCRYPT_KEY, config.encryptKey)
            .putString(Constants.EXTRA_IFACE, config.interfaceName)
            .putString(Constants.EXTRA_TUN, config.tunDevice)
            .putString(Constants.EXTRA_DNS, config.dns)
            .putStringSet(
                Constants.EXTRA_PROXY_PER_APP_PACKAGES,
                config.proxyPerAppPackages.toSet()
            )
            .apply()
    }

    fun load(context: Context): TunnelConfig? {
        val prefs = context.getSharedPreferences(Constants.PREFS_LAST_CONFIG, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_HAS_VALUE, false)) {
            return null
        }

        val host = prefs.getString(Constants.EXTRA_SERVER_HOST, null) ?: return null
        val hasServerPort = prefs.getBoolean(KEY_HAS_SERVER_PORT, false)
        val serverPort = if (hasServerPort) prefs.getInt(Constants.EXTRA_SERVER_PORT, 0) else null

        val localPort = prefs.getInt(Constants.EXTRA_LOCAL_PORT, 1080)
        val hasKey = prefs.getBoolean(KEY_HAS_KEY, false)
        val key = if (hasKey) prefs.getInt(Constants.EXTRA_KEY, 0) else null
        val mode = prefs.getString(Constants.EXTRA_MODE, "proxy") ?: "proxy"
        val encryptMode = prefs.getString(Constants.EXTRA_ENCRYPT_MODE, null)
        val encryptKey = prefs.getString(Constants.EXTRA_ENCRYPT_KEY, null)
        val iface = prefs.getString(Constants.EXTRA_IFACE, null)
        val tun = prefs.getString(Constants.EXTRA_TUN, null)
        val dns = prefs.getString(Constants.EXTRA_DNS, null)
        val proxyPerAppPackages = prefs
            .getStringSet(Constants.EXTRA_PROXY_PER_APP_PACKAGES, emptySet())
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.distinct()
            ?: emptyList()

        if (encryptMode.isNullOrBlank() && key == null) {
            return null
        }

        return TunnelConfig(
            serverHost = host,
            serverPort = serverPort,
            localSocksPort = localPort,
            key = key,
            mode = mode,
            encryptMode = encryptMode,
            encryptKey = encryptKey,
            interfaceName = iface,
            tunDevice = tun,
            dns = dns,
            proxyPerAppPackages = proxyPerAppPackages
        )
    }
}
