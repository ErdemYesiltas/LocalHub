package dev.localhub.client

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.URI
import java.util.Base64
import java.util.UUID
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLHandshakeException

data class HubSession(
    val address: URI, val fingerprint: String, val token: String, val deviceId: String, val scopes: List<String>,
    val hubId: String? = null, val hubName: String? = null,
) {
    fun toJson(): String = Json.stringify(mapOf("address" to address.toString(), "fingerprint" to fingerprint, "token" to token,
        "deviceID" to deviceId, "scopes" to scopes, "hubID" to hubId, "hubName" to hubName))

    companion object {
        fun fromJson(text: String): HubSession {
            val json = Json.parse(text).obj()
            val token = json["token"] as? String ?: throw IllegalArgumentException("Invalid LocalHub session")
            require(token.length in 32..199) { "Invalid LocalHub session" }
            return HubSession(hubAddress(json["address"] as String), normalizeFingerprint(json["fingerprint"] as String), token,
                json["deviceID"] as String, json["scopes"].list().map { it.toString() }, json["hubID"] as? String, json["hubName"] as? String)
        }
    }
}

/** Where the session (and its token) lives. On Android: EncryptedSharedPreferences or the Keystore; never plain prefs. */
interface SessionStore {
    fun load(): HubSession?
    fun save(session: HubSession)
    fun clear()
}

class MemorySessionStore : SessionStore {
    @Volatile private var session: HubSession? = null
    override fun load() = session
    override fun save(session: HubSession) { this.session = session }
    override fun clear() { session = null }
}

/** The hub's `{"error": {code, message, provider?}}`, e.g. `provider_unavailable` when LM Studio is closed. */
class HubException(val status: Int, val code: String, message: String, val provider: String? = null) : IOException(message)

/** A file to upload with an edit request, or one already on the hub. */
sealed class MediaInput {
    class Bytes(val data: ByteArray, val filename: String = "image.png", val contentType: String = "image/png") : MediaInput()
    class FileId(val id: String) : MediaInput()
}

/**
 * LocalHub client for Android and the JVM, using only the JDK (HttpsURLConnection). Blocking calls:
 * run them off the main thread (coroutines' Dispatchers.IO, an executor…).
 */
class HubClient(private val store: SessionStore) {
    @Volatile var session: HubSession? = null
        private set

    fun restore(): HubSession? = store.load().also { session = it }

    fun pair(invite: HubInvite, deviceName: String, app: String, scopes: List<String>? = null): HubSession {
        val body = Json.stringify(mapOf("code" to invite.code, "deviceName" to deviceName.trim(), "app" to app, "scopes" to scopes))
        val result = Json.parse(exchange(invite.address, invite.fingerprint, null, "POST", if (invite.version == 2) "/v2/pair" else "/pair",
            Body.JsonBody(body)).decodeToString()).obj()
        val paired = HubSession(invite.address, invite.fingerprint, result["token"] as String, result["deviceID"] as String,
            result["scopes"].list().map { it.toString() }, invite.hubId, invite.hubName)
        store.save(paired)
        session = paired
        return paired
    }

    fun unpair() {
        if (session != null) {
            try { call("DELETE", "/v2/session") } catch (e: HubException) { if (e.status != 401) throw e }
        }
        store.clear()
        session = null
    }

    fun models(): List<Map<String, Any?>> = Json.parse(call("GET", "/v1/models").decodeToString()).obj()["data"].list().map { it.obj() }
    fun workProfiles(): List<Map<String, Any?>> = Json.parse(call("GET", "/v2/profiles").decodeToString()).list().map { it.obj() }

    fun integrations(): List<Map<String, Any?>> = Json.parse(call("GET", "/v2/integrations").decodeToString()).list().map { it.obj() }

    /** The assistant's reply text. `body` is OpenAI's chat body; `model` is a hub id such as `lmstudio/qwen/qwen3-8b`. */
    fun chat(body: Map<String, Any?>): String {
        val reply = Json.parse(call("POST", "/v1/chat/completions", Body.JsonBody(Json.stringify(body + ("stream" to false)))).decodeToString()).obj()
        return reply["choices"].list().firstOrNull().obj()["message"].obj()["content"] as? String ?: ""
    }

    /**
     * Streams reply chunks to [onChunk] (OpenAI `chat.completion.chunk` maps) until done. Return `false` from
     * [onChunk] to stop: the connection closes and the hub stops the generation.
     */
    fun chatStream(body: Map<String, Any?>, onChunk: (Map<String, Any?>) -> Boolean) {
        events("POST", "/v1/chat/completions", Body.JsonBody(Json.stringify(body + ("stream" to true)))) { data ->
            if (data == "[DONE]") false else onChunk(Json.parse(data).obj())
        }
    }

    fun embeddings(model: String, input: List<String>, profile: String? = null): List<List<Double>> =
        Json.parse(call("POST", "/v1/embeddings", Body.JsonBody(Json.stringify(mapOf("model" to model, "input" to input, "profile" to profile)))).decodeToString())
            .obj()["data"].list().map { item -> item.obj()["embedding"].list().map { (it as Number).toDouble() } }

    /** Waits for the image (up to the Mac's workflow timeout); returns the PNG/JPEG bytes and file ids. */
    fun generateImage(body: Map<String, Any?>): List<Pair<String, ByteArray?>> = media("/v1/images/generations", body)

    fun editImage(fields: Map<String, Any?>, image: MediaInput, mask: MediaInput? = null): List<Pair<String, ByteArray?>> =
        media("/v1/images/edits", fields, listOfNotNull("image" to image, mask?.let { "mask" to it }))

    /** A job you can follow with [jobEvents] and stop with [cancelJob]. */
    fun startImage(body: Map<String, Any?>): Map<String, Any?> =
        Json.parse(call("POST", "/v1/images/generations", Body.JsonBody(Json.stringify(body)), mapOf("Prefer" to "respond-async")).decodeToString()).obj()

    fun job(id: String): Map<String, Any?> = Json.parse(call("GET", "/v1/jobs/${segment(id)}").decodeToString()).obj()
    fun cancelJob(id: String): Map<String, Any?> = Json.parse(call("POST", "/v1/jobs/${segment(id)}/cancel").decodeToString()).obj()
    fun recipe(id: String): Map<String, Any?> = Json.parse(call("GET", "/v1/jobs/${segment(id)}/recipe").decodeToString()).obj()
    fun replayJob(id: String, variation: Boolean = false): Map<String, Any?> =
        Json.parse(call("POST", "/v1/jobs/${segment(id)}/replay", Body.JsonBody(Json.stringify(mapOf("variation" to variation)))).decodeToString()).obj()

    /** Job snapshots until it completes, fails or is cancelled. */
    fun jobEvents(id: String, onUpdate: (Map<String, Any?>) -> Unit) {
        events("GET", "/v1/jobs/${segment(id)}/events", null) { data -> onUpdate(Json.parse(data).obj()); true }
    }

    fun speech(input: String, voice: String? = null, profile: String? = null): ByteArray =
        call("POST", "/v1/audio/speech", Body.JsonBody(Json.stringify(mapOf("input" to input, "voice" to voice, "profile" to profile))))

    fun transcribe(audio: ByteArray, filename: String = "audio.wav", language: String? = null, profile: String? = null): String {
        val fields = listOfNotNull(language?.let { "language" to it }, profile?.let { "profile" to it })
        val reply = call("POST", "/v1/audio/transcriptions", Body.Multipart(fields, listOf(Part("file", filename, "application/octet-stream", audio))))
        return Json.parse(reply.decodeToString()).obj()["text"] as? String ?: ""
    }

    fun uploadFile(data: ByteArray, filename: String, contentType: String, purpose: String? = null): Map<String, Any?> =
        Json.parse(call("POST", "/v1/files", Body.Multipart(listOfNotNull(purpose?.let { "purpose" to it }),
            listOf(Part("file", filename, contentType, data)))).decodeToString()).obj()

    fun fileContent(id: String): ByteArray = call("GET", "/v1/files/${segment(id)}/content")
    fun deleteFile(id: String) { call("DELETE", "/v1/files/${segment(id)}") }

    // Plumbing

    private class Part(val name: String, val filename: String, val contentType: String, val data: ByteArray)
    private sealed class Body {
        class JsonBody(val text: String) : Body()
        class Multipart(val fields: List<Pair<String, String>>, val files: List<Part>) : Body()
    }

    private fun media(path: String, fields: Map<String, Any?>, inputs: List<Pair<String, MediaInput>> = emptyList()): List<Pair<String, ByteArray?>> {
        val uploads = inputs.filter { it.second is MediaInput.Bytes }
        val references = inputs.filter { it.second is MediaInput.FileId }.associate { "${it.first}_file_id" to (it.second as MediaInput.FileId).id }
        val body = if (uploads.isEmpty()) Body.JsonBody(Json.stringify(fields + references)) else Body.Multipart(
            (fields + references).filterValues { it != null }.map { it.key to it.value.toString() },
            uploads.map { (name, input) -> (input as MediaInput.Bytes).let { Part(name, it.filename, it.contentType, it.data) } })
        val reply = Json.parse(call("POST", path, body, timeoutMs = 660_000).decodeToString()).obj()
        return reply["data"].list().map { item ->
            val entry = item.obj()
            (entry["file_id"] as String) to (entry["b64_json"] as? String)?.let { Base64.getDecoder().decode(it) }
        }
    }

    private fun segment(value: String) = java.net.URLEncoder.encode(value, Charsets.UTF_8)

    private fun requireSession() = session ?: throw IllegalStateException("LocalHub is not paired")

    private fun call(method: String, path: String, body: Body? = null, headers: Map<String, String> = emptyMap(), timeoutMs: Int = 120_000): ByteArray {
        val s = requireSession()
        return exchange(s.address, s.fingerprint, s.token, method, path, body, headers, timeoutMs)
    }

    private fun open(address: URI, fingerprint: String, token: String?, method: String, path: String, body: Body?,
                     headers: Map<String, String>, timeoutMs: Int): HttpsURLConnection {
        require(path.startsWith("/") && !path.startsWith("//")) { "LocalHub paths are relative to the paired hub" }
        val connection = address.resolve(path).toURL().openConnection() as HttpsURLConnection
        connection.sslSocketFactory = PinningTrustManager.socketFactory(fingerprint)
        connection.hostnameVerifier = javax.net.ssl.HostnameVerifier { host, _ -> host == address.host }  // the pin is the identity
        connection.instanceFollowRedirects = false
        connection.requestMethod = method
        connection.connectTimeout = 15_000
        connection.readTimeout = timeoutMs
        connection.setRequestProperty("Accept", "application/json")
        headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
        if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
        when (body) {
            // Not streamed: a streamed body turns a 401 into HttpRetryException and hides the hub's error.
            is Body.JsonBody -> write(connection, "application/json", body.text.encodeToByteArray(), streamed = false)
            is Body.Multipart -> {
                val boundary = "localhub-${UUID.randomUUID()}"
                val out = ByteArrayOutputStream()
                fun clean(s: String) = s.replace("\"", "").replace("\r", "").replace("\n", "")
                for ((name, value) in body.fields) out.write("--$boundary\r\nContent-Disposition: form-data; name=\"${clean(name)}\"\r\n\r\n$value\r\n".encodeToByteArray())
                for (part in body.files) {
                    out.write("--$boundary\r\nContent-Disposition: form-data; name=\"${clean(part.name)}\"; filename=\"${clean(part.filename)}\"\r\nContent-Type: ${part.contentType}\r\n\r\n".encodeToByteArray())
                    out.write(part.data); out.write("\r\n".encodeToByteArray())
                }
                out.write("--$boundary--\r\n".encodeToByteArray())
                write(connection, "multipart/form-data; boundary=$boundary", out.toByteArray(), streamed = true)
            }
            null -> Unit
        }
        return connection
    }

    private fun write(connection: HttpsURLConnection, type: String, data: ByteArray, streamed: Boolean) {
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", type)
        if (streamed) connection.setFixedLengthStreamingMode(data.size)
        connection.outputStream.use { it.write(data) }
    }

    private fun exchange(address: URI, fingerprint: String, token: String?, method: String, path: String, body: Body?,
                         headers: Map<String, String> = emptyMap(), timeoutMs: Int = 120_000): ByteArray {
        val connection = try {
            open(address, fingerprint, token, method, path, body, headers, timeoutMs).also { it.responseCode }
        } catch (e: SSLHandshakeException) {
            throw if (e.cause is PinMismatchException || e.findCause<PinMismatchException>() != null) PinMismatchException() else e
        } catch (e: java.net.HttpRetryException) {
            throw HubException(e.responseCode(), if (e.responseCode() == 401) "unauthorized" else "http_error", e.message ?: "LocalHub HTTP ${e.responseCode()}")
        }
        try {
            if (connection.responseCode !in 200..299) throw error(connection)
            return connection.inputStream.use { read(it, 1L shl 30) }
        } finally {
            connection.disconnect()
        }
    }

    private fun events(method: String, path: String, body: Body?, onData: (String) -> Boolean) {
        val s = requireSession()
        val connection = open(s.address, s.fingerprint, s.token, method, path, body, mapOf("Accept" to "text/event-stream"), 660_000)
        try {
            if (connection.responseCode != 200) throw error(connection)
            connection.inputStream.bufferedReader().useLines { lines ->
                for (line in lines) {
                    if (!line.startsWith("data:")) continue
                    if (!onData(line.removePrefix("data:").trim())) break
                }
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun error(connection: HttpsURLConnection): HubException {
        val status = connection.responseCode
        val text = runCatching { connection.errorStream?.use { read(it, 65_536).decodeToString() } }.getOrNull()
        val error = runCatching { Json.parse(text ?: "").obj()["error"].obj() }.getOrDefault(emptyMap())
        return HubException(status, error["code"] as? String ?: "http_error", error["message"] as? String ?: "LocalHub HTTP $status",
            error["provider"] as? String)
    }

    private fun read(input: InputStream, limit: Long): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16_384)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return out.toByteArray()
            if (out.size() + count > limit) throw IOException("LocalHub response too large")
            out.write(buffer, 0, count)
        }
    }
}

private inline fun <reified T : Throwable> Throwable.findCause(): T? {
    var current: Throwable? = this
    while (current != null) { if (current is T) return current; current = current.cause }
    return null
}
