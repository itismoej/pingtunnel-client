package com.pingtunnel.client.app

import android.content.Intent


data class TunnelConfig(
    val serverHost: String,
    val serverPort: Int?,
    val localSocksPort: Int,
    val key: Int?,
    val mode: String,
    val encryptMode: String?,
    val encryptKey: String?,
    val interfaceName: String?,
    val tunDevice: String?,
    val dns: String?,
    val proxyPerAppPackages: List<String>
) {
    fun serverAddress(): String {
        return if (serverPort == null) serverHost else "$serverHost:$serverPort"
    }

    companion object {
        fun fromMap(map: Map<*, *>): TunnelConfig {
            val host = map[Constants.EXTRA_SERVER_HOST] as? String
                ?: throw IllegalArgumentException("serverHost missing")
            val port = (map[Constants.EXTRA_SERVER_PORT] as? Number)?.toInt()
            val localPort = (map[Constants.EXTRA_LOCAL_PORT] as? Number)?.toInt() ?: 1080
            val key = (map[Constants.EXTRA_KEY] as? Number)?.toInt()
            val mode = map[Constants.EXTRA_MODE] as? String ?: "proxy"
            val encryptMode = map[Constants.EXTRA_ENCRYPT_MODE] as? String
            val encryptKey = map[Constants.EXTRA_ENCRYPT_KEY] as? String
            val iface = map[Constants.EXTRA_IFACE] as? String
            val tun = map[Constants.EXTRA_TUN] as? String
            val dns = map[Constants.EXTRA_DNS] as? String
            val proxyPerAppPackages = (map[Constants.EXTRA_PROXY_PER_APP_PACKAGES] as? List<*>)
                ?.mapNotNull { it?.toString()?.trim() }
                ?.filter { it.isNotEmpty() }
                ?.distinct()
                ?: emptyList()

            if (encryptMode.isNullOrBlank() && key == null) {
                throw IllegalArgumentException("key missing")
            }

            return TunnelConfig(
                serverHost = host,
                serverPort = port,
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

        fun fromIntent(intent: Intent): TunnelConfig {
            val host = intent.getStringExtra(Constants.EXTRA_SERVER_HOST)
                ?: throw IllegalArgumentException("serverHost missing")
            val port = if (intent.hasExtra(Constants.EXTRA_SERVER_PORT)) {
                intent.getIntExtra(Constants.EXTRA_SERVER_PORT, 0)
            } else {
                null
            }
            val localPort = intent.getIntExtra(Constants.EXTRA_LOCAL_PORT, 1080)
            val key = if (intent.hasExtra(Constants.EXTRA_KEY)) {
                intent.getIntExtra(Constants.EXTRA_KEY, 0)
            } else {
                null
            }
            val mode = intent.getStringExtra(Constants.EXTRA_MODE) ?: "proxy"
            val encryptMode = intent.getStringExtra(Constants.EXTRA_ENCRYPT_MODE)
            val encryptKey = intent.getStringExtra(Constants.EXTRA_ENCRYPT_KEY)
            val iface = intent.getStringExtra(Constants.EXTRA_IFACE)
            val tun = intent.getStringExtra(Constants.EXTRA_TUN)
            val dns = intent.getStringExtra(Constants.EXTRA_DNS)
            val proxyPerAppPackages = intent
                .getStringArrayListExtra(Constants.EXTRA_PROXY_PER_APP_PACKAGES)
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?.distinct()
                ?: emptyList()

            if (encryptMode.isNullOrBlank() && key == null) {
                throw IllegalArgumentException("key missing")
            }

            return TunnelConfig(
                serverHost = host,
                serverPort = port,
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
}
