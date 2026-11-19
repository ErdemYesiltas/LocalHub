package dev.localhub.client

import java.net.URI
import java.net.URLDecoder

/** What the hub's QR carries. Scanning grants no more trust than typing the same values. */
data class HubInvite(val address: URI, val fingerprint: String, val code: String, val version: Int, val hubId: String?, val hubName: String?) {
    companion object {
        /** v2: `localhub://pair?v=2&u=…&fp=…&c=…&id=…&n=…`; v1: `artblend-companion://pair?v=1&u=…&fp=…&c=…`. */
        fun parse(raw: String): HubInvite {
            val text = raw.trim()
            if (text.length > 1024) throw IllegalArgumentException("Not a LocalHub pairing code")
            val uri = runCatching { URI(text) }.getOrElse { throw IllegalArgumentException("Not a LocalHub pairing code") }
            if ((uri.scheme != "localhub" && uri.scheme != "artblend-companion") || uri.host != "pair" ||
                !(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/") || uri.rawUserInfo != null || uri.rawFragment != null) {
                throw IllegalArgumentException("Not a LocalHub pairing code")
            }
            val params = (uri.rawQuery ?: "").split('&').filter { it.isNotEmpty() }.map {
                val (k, v) = it.split('=', limit = 2).let { p -> p[0] to (p.getOrNull(1) ?: "") }
                URLDecoder.decode(k, Charsets.UTF_8) to URLDecoder.decode(v, Charsets.UTF_8)
            }
            fun single(name: String, required: Boolean = true): String? {
                val values = params.filter { it.first == name }.map { it.second }
                if (values.size > 1 || (required && values.isEmpty())) throw IllegalArgumentException("Incomplete pairing code")
                return values.firstOrNull()
            }
            val v2 = uri.scheme == "localhub" && single("v") == "2"
            if (!v2 && !(uri.scheme == "artblend-companion" && single("v") == "1")) throw IllegalArgumentException("Unsupported pairing code version")
            val code = single("c")!!
            if (!Regex("^\\d{6}$").matches(code)) throw IllegalArgumentException("Invalid pairing code in QR")
            return HubInvite(
                address = hubAddress(single("u")!!), fingerprint = normalizeFingerprint(single("fp")!!), code = code, version = if (v2) 2 else 1,
                hubId = if (v2) single("id", false)?.takeIf { Regex("^[a-z0-9-]{1,64}$").matches(it) } else null,
                hubName = if (v2) single("n", false)?.take(40) else null,
            )
        }
    }
}

fun normalizeFingerprint(value: String): String {
    val normalized = value.replace(":", "").filterNot { it.isWhitespace() }.lowercase()
    if (!Regex("^[a-f0-9]{64}$").matches(normalized)) throw IllegalArgumentException("Expected a SHA-256 certificate fingerprint")
    return normalized
}

fun hubAddress(value: String): URI {
    val uri = runCatching { URI(value.trim()) }.getOrElse { throw IllegalArgumentException("Enter an HTTPS hub address") }
    if (uri.scheme != "https" || uri.host.isNullOrEmpty() || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null ||
        !(uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")) {
        throw IllegalArgumentException("Enter an HTTPS hub address without a path or credentials")
    }
    return URI("https", null, uri.host, uri.port, null, null, null)
}
