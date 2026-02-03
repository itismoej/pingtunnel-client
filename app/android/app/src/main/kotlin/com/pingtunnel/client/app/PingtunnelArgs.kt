package com.pingtunnel.client.app

fun buildPingtunnelArgs(binPath: String, config: TunnelConfig): List<String> {
    val args = mutableListOf(
        binPath,
        "-type",
        "client",
        "-l",
        ":${config.localSocksPort}",
        "-s",
        config.serverAddress(),
        "-sock5",
        "1"
    )

    if (!config.encryptMode.isNullOrBlank()) {
        args.add("-encrypt")
        args.add(config.encryptMode!!)
        if (config.encryptKey.isNullOrBlank()) {
            throw IllegalArgumentException("encrypt key missing")
        }
        args.add("-encrypt-key")
        args.add(config.encryptKey!!)
    } else {
        val key = config.key ?: throw IllegalArgumentException("key missing")
        args.add("-key")
        args.add(key.toString())
    }

    return args
}
