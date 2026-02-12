package com.pingtunnel.client.app

import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.IDN
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.URI
import kotlin.concurrent.thread

class HttpToSocksProxy(
    private val tag: String = "MixedLocalProxy"
) {
    @Volatile
    private var running = false

    @Volatile
    private var serverSocket: ServerSocket? = null

    private val clientSockets = mutableSetOf<Socket>()
    private val clientSocketsLock = Any()

    private data class ParsedRequest(
        val method: String,
        val target: String,
        val version: String,
        val headers: List<Pair<String, String>>
    )

    private data class Target(
        val host: String,
        val port: Int,
        val scheme: String,
        val pathAndQuery: String
    )

    private data class Authority(
        val host: String,
        val port: Int
    )

    fun start(listenPort: Int, socksPort: Int) {
        stop()

        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress("127.0.0.1", listenPort))
        serverSocket = server
        running = true

        Log.i(tag, "Listening on 127.0.0.1:$listenPort and forwarding via SOCKS5 127.0.0.1:$socksPort")

        thread(start = true, name = "http-socks-accept") {
            acceptLoop(server, socksPort)
        }
    }

    fun stop() {
        running = false

        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null

        synchronized(clientSocketsLock) {
            clientSockets.toList().forEach { closeQuietly(it) }
            clientSockets.clear()
        }
    }

    private fun acceptLoop(server: ServerSocket, socksPort: Int) {
        while (running) {
            val client = try {
                server.accept()
            } catch (e: SocketException) {
                if (running) {
                    Log.w(tag, "Accept failed: ${e.message}")
                }
                break
            } catch (e: IOException) {
                if (running) {
                    Log.e(tag, "Accept IO error", e)
                }
                break
            }

            addClientSocket(client)
            thread(start = true, name = "http-socks-client") {
                handleClient(client, socksPort)
            }
        }
    }

    private fun handleClient(client: Socket, socksPort: Int) {
        client.tcpNoDelay = true
        var upstream: Socket? = null
        var isHttpRequest = false

        try {
            val clientInput = BufferedInputStream(client.getInputStream())
            val clientOutput = client.getOutputStream()
            val firstByte = clientInput.read()
            if (firstByte == -1) {
                return
            }

            if (!isLikelyHttpMethodStart(firstByte)) {
                upstream = connectToSocksServer(socksPort)
                val upstreamOutput = upstream.getOutputStream()
                upstreamOutput.write(firstByte)
                upstreamOutput.flush()
                tunnel(clientInput, clientOutput, upstream)
                return
            }

            isHttpRequest = true
            val headerBytes = readRequestHeaders(clientInput, firstByte)
            val request = parseRequest(headerBytes)

            if (request.method == "CONNECT") {
                val authority = parseAuthority(request.target, defaultPort = 443)
                upstream = connectViaSocks(
                    socksPort = socksPort,
                    targetHost = authority.host,
                    targetPort = authority.port
                )
                clientOutput.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                clientOutput.flush()
                tunnel(clientInput, clientOutput, upstream)
            } else {
                val target = resolveHttpTarget(request)
                upstream = connectViaSocks(
                    socksPort = socksPort,
                    targetHost = target.host,
                    targetPort = target.port
                )

                val rewritten = buildForwardRequest(request, target)
                val upstreamOutput = upstream.getOutputStream()
                upstreamOutput.write(rewritten)
                upstreamOutput.flush()

                tunnel(clientInput, clientOutput, upstream)
            }
        } catch (e: Exception) {
            Log.w(tag, "Client handling failed: ${e.message}")
            if (isHttpRequest) {
                try {
                    writeHttpError(client.getOutputStream(), 502, "Bad Gateway")
                } catch (_: Exception) {
                }
            }
        } finally {
            closeQuietly(upstream)
            removeClientSocket(client)
            closeQuietly(client)
        }
    }

    private fun tunnel(
        clientInput: InputStream,
        clientOutput: OutputStream,
        upstream: Socket
    ) {
        val upstreamInput = upstream.getInputStream()
        val upstreamOutput = upstream.getOutputStream()

        val uploadThread = thread(start = true, name = "http-socks-upload") {
            try {
                copyStream(clientInput, upstreamOutput)
            } catch (_: Exception) {
            } finally {
                try {
                    upstream.shutdownOutput()
                } catch (_: Exception) {
                }
            }
        }

        try {
            copyStream(upstreamInput, clientOutput)
        } finally {
            try {
                clientOutput.flush()
            } catch (_: Exception) {
            }
            try {
                uploadThread.join(300)
            } catch (_: Exception) {
            }
        }
    }

    private fun readRequestHeaders(input: BufferedInputStream, firstByte: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(firstByte)
        var state = if (firstByte == '\r'.code) 1 else 0

        while (out.size() < 64 * 1024) {
            val value = input.read()
            if (value == -1) {
                throw IOException("Client closed before sending request headers")
            }

            out.write(value)
            state = when (state) {
                0 -> if (value == '\r'.code) 1 else 0
                1 -> if (value == '\n'.code) 2 else 0
                2 -> if (value == '\r'.code) 3 else 0
                3 -> if (value == '\n'.code) 4 else 0
                else -> 0
            }

            if (state == 4) {
                return out.toByteArray()
            }
        }

        throw IOException("Request headers too large")
    }

    private fun parseRequest(headers: ByteArray): ParsedRequest {
        val text = headers.toString(Charsets.ISO_8859_1)
        val lines = text.split("\r\n")
        val requestLine = lines.firstOrNull()?.trim().orEmpty()
        if (requestLine.isEmpty()) {
            throw IOException("Empty request line")
        }

        val parts = requestLine.split(" ")
        if (parts.size < 3) {
            throw IOException("Invalid request line: $requestLine")
        }

        val parsedHeaders = mutableListOf<Pair<String, String>>()
        for (line in lines.drop(1)) {
            if (line.isEmpty()) {
                break
            }
            val separator = line.indexOf(':')
            if (separator <= 0) {
                continue
            }
            val name = line.substring(0, separator).trim()
            val value = line.substring(separator + 1).trim()
            parsedHeaders.add(name to value)
        }

        return ParsedRequest(
            method = parts[0].uppercase(),
            target = parts[1],
            version = parts[2],
            headers = parsedHeaders
        )
    }

    private fun resolveHttpTarget(request: ParsedRequest): Target {
        val rawTarget = request.target.trim()
        if (rawTarget.startsWith("http://", ignoreCase = true) ||
            rawTarget.startsWith("https://", ignoreCase = true)
        ) {
            val uri = URI(rawTarget)
            val scheme = (uri.scheme ?: "http").lowercase()
            val host = uri.host ?: throw IOException("Missing target host")
            val port = if (uri.port != -1) uri.port else if (scheme == "https") 443 else 80
            return Target(
                host = host,
                port = port,
                scheme = scheme,
                pathAndQuery = buildPathAndQuery(uri.rawPath, uri.rawQuery)
            )
        }

        val hostHeader = request.headers
            .firstOrNull { it.first.equals("Host", ignoreCase = true) }
            ?.second
            ?: throw IOException("Missing Host header")

        val authority = parseAuthority(hostHeader, defaultPort = 80)
        val path = if (rawTarget.startsWith("/")) rawTarget else "/$rawTarget"
        return Target(
            host = authority.host,
            port = authority.port,
            scheme = "http",
            pathAndQuery = path
        )
    }

    private fun buildForwardRequest(request: ParsedRequest, target: Target): ByteArray {
        val sb = StringBuilder()
        sb.append(request.method)
            .append(' ')
            .append(target.pathAndQuery)
            .append(' ')
            .append(request.version)
            .append("\r\n")

        var hasHost = false
        request.headers.forEach { (name, value) ->
            val lowerName = name.lowercase()
            if (lowerName == "proxy-connection" || lowerName == "proxy-authorization") {
                return@forEach
            }
            if (lowerName == "connection") {
                return@forEach
            }
            if (lowerName == "host") {
                hasHost = true
                sb.append("Host: ")
                    .append(formatHostHeader(target.host, target.port, target.scheme))
                    .append("\r\n")
                return@forEach
            }
            sb.append(name).append(": ").append(value).append("\r\n")
        }

        if (!hasHost) {
            sb.append("Host: ")
                .append(formatHostHeader(target.host, target.port, target.scheme))
                .append("\r\n")
        }

        sb.append("Connection: close\r\n")
        sb.append("\r\n")
        return sb.toString().toByteArray(Charsets.ISO_8859_1)
    }

    private fun parseAuthority(authority: String, defaultPort: Int): Authority {
        val value = authority.trim()
        if (value.isEmpty()) {
            throw IOException("Empty authority")
        }

        if (value.startsWith("[")) {
            val end = value.indexOf(']')
            if (end <= 0) {
                throw IOException("Invalid IPv6 authority: $authority")
            }
            val host = value.substring(1, end)
            val hasPort = end + 1 < value.length && value[end + 1] == ':'
            val port = if (hasPort) {
                value.substring(end + 2).toIntOrNull() ?: throw IOException("Invalid port: $authority")
            } else {
                defaultPort
            }
            return Authority(host, port)
        }

        val lastColon = value.lastIndexOf(':')
        val singleColon = value.indexOf(':') == lastColon
        if (lastColon > 0 && singleColon) {
            val host = value.substring(0, lastColon)
            val port = value.substring(lastColon + 1).toIntOrNull()
                ?: throw IOException("Invalid port: $authority")
            return Authority(host, port)
        }

        return Authority(value, defaultPort)
    }

    private fun formatHostHeader(host: String, port: Int, scheme: String): String {
        val defaultPort = if (scheme == "https") 443 else 80
        val printableHost = if (host.contains(':') && !host.startsWith("[") && !host.endsWith("]")) {
            "[$host]"
        } else {
            host
        }
        return if (port == defaultPort) {
            printableHost
        } else {
            "$printableHost:$port"
        }
    }

    private fun buildPathAndQuery(path: String?, query: String?): String {
        val rawPath = if (path.isNullOrEmpty()) "/" else path
        return if (query.isNullOrEmpty()) rawPath else "$rawPath?$query"
    }

    private fun connectViaSocks(socksPort: Int, targetHost: String, targetPort: Int): Socket {
        val socket = connectToSocksServer(socksPort)

        val input = socket.getInputStream()
        val output = socket.getOutputStream()

        output.write(byteArrayOf(0x05, 0x01, 0x00))
        output.flush()

        val greeting = readExact(input, 2)
        if (greeting[0].toInt() != 0x05 || greeting[1].toInt() != 0x00) {
            throw IOException("SOCKS5 auth negotiation failed")
        }

        val request = ByteArrayOutputStream()
        request.write(byteArrayOf(0x05, 0x01, 0x00))
        request.write(buildSocksAddress(targetHost))
        request.write(byteArrayOf(((targetPort shr 8) and 0xff).toByte(), (targetPort and 0xff).toByte()))

        output.write(request.toByteArray())
        output.flush()

        val responseHead = readExact(input, 4)
        if (responseHead[0].toInt() != 0x05 || responseHead[1].toInt() != 0x00) {
            throw IOException("SOCKS5 connect failed (code=${responseHead[1].toInt() and 0xff})")
        }

        when (responseHead[3].toInt() and 0xff) {
            0x01 -> readExact(input, 4 + 2) // IPv4 + port
            0x04 -> readExact(input, 16 + 2) // IPv6 + port
            0x03 -> {
                val domainLength = readExact(input, 1)[0].toInt() and 0xff
                readExact(input, domainLength + 2)
            }
            else -> throw IOException("Unsupported SOCKS5 address type in response")
        }

        return socket
    }

    private fun connectToSocksServer(socksPort: Int): Socket {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress("127.0.0.1", socksPort), 8000)
        return socket
    }

    private fun isLikelyHttpMethodStart(value: Int): Boolean {
        return (value in 'A'.code..'Z'.code) || (value in 'a'.code..'z'.code)
    }

    private fun buildSocksAddress(hostInput: String): ByteArray {
        val host = hostInput.trim().removePrefix("[").removeSuffix("]")

        val ipv4Parts = host.split('.')
        if (ipv4Parts.size == 4 && ipv4Parts.all { it.toIntOrNull() in 0..255 }) {
            val out = ByteArrayOutputStream()
            out.write(0x01)
            ipv4Parts.forEach { out.write(it.toInt()) }
            return out.toByteArray()
        }

        if (host.contains(':')) {
            val addr = InetAddress.getByName(host)
            if (addr is Inet6Address) {
                val out = ByteArrayOutputStream()
                out.write(0x04)
                out.write(addr.address)
                return out.toByteArray()
            }
        }

        val asciiHost = IDN.toASCII(host)
        val encoded = asciiHost.toByteArray(Charsets.UTF_8)
        if (encoded.isEmpty() || encoded.size > 255) {
            throw IOException("Invalid target host")
        }

        val out = ByteArrayOutputStream()
        out.write(0x03)
        out.write(encoded.size)
        out.write(encoded)
        return out.toByteArray()
    }

    private fun copyStream(input: InputStream, output: OutputStream) {
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) {
                break
            }
            output.write(buffer, 0, read)
            output.flush()
        }
    }

    private fun readExact(input: InputStream, length: Int): ByteArray {
        val out = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = input.read(out, offset, length - offset)
            if (read == -1) {
                throw IOException("Unexpected EOF")
            }
            offset += read
        }
        return out
    }

    private fun writeHttpError(output: OutputStream, code: Int, message: String) {
        val body = "$code $message\n".toByteArray(Charsets.UTF_8)
        val header = buildString {
            append("HTTP/1.1 ").append(code).append(' ').append(message).append("\r\n")
            append("Connection: close\r\n")
            append("Content-Type: text/plain; charset=utf-8\r\n")
            append("Content-Length: ").append(body.size).append("\r\n")
            append("\r\n")
        }.toByteArray(Charsets.ISO_8859_1)
        output.write(header)
        output.write(body)
        output.flush()
    }

    private fun addClientSocket(socket: Socket) {
        synchronized(clientSocketsLock) {
            clientSockets.add(socket)
        }
    }

    private fun removeClientSocket(socket: Socket) {
        synchronized(clientSocketsLock) {
            clientSockets.remove(socket)
        }
    }

    private fun closeQuietly(socket: Socket?) {
        try {
            socket?.close()
        } catch (_: Exception) {
        }
    }
}
