package dev.localhub.client

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpsConfigurator
import com.sun.net.httpserver.HttpsServer
import java.io.File
import java.net.InetSocketAddress
import java.net.URLEncoder
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

private const val TOKEN = "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT"
private val PNG = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
private val requests = mutableListOf<Triple<String, String, String>>()
private var passed = 0

private fun test(name: String, body: () -> Unit) {
    body()
    passed++
    println("✔ $name")
}

private fun reply(exchange: HttpExchange, status: Int, body: String, type: String = "application/json") {
    val bytes = body.encodeToByteArray()
    exchange.responseHeaders.add("Content-Type", type)
    exchange.sendResponseHeaders(status, bytes.size.toLong())
    exchange.responseBody.use { it.write(bytes) }
}

/** Runs against JDK's HttpsServer with a self-signed keystore made by scripts/test.sh (keytool). */
fun main(args: Array<String>) {
    val keystore = KeyStore.getInstance("PKCS12").apply { File(args[0]).inputStream().use { load(it, "secret".toCharArray()) } }
    val fingerprint = MessageDigest.getInstance("SHA-256").digest(keystore.getCertificate("hub").encoded).joinToString("") { "%02x".format(it) }
    val ssl = SSLContext.getInstance("TLS").apply {
        init(KeyManagerFactory.getInstance("SunX509").apply { init(keystore, "secret".toCharArray()) }.keyManagers, null, null)
    }
    val server = HttpsServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply { httpsConfigurator = HttpsConfigurator(ssl) }
    server.createContext("/") { exchange ->
        val body = exchange.requestBody.readAllBytes().decodeToString()
        synchronized(requests) { requests.add(Triple("${exchange.requestMethod} ${exchange.requestURI.path}", exchange.requestHeaders.getFirst("Authorization") ?: "", body)) }
        when ("${exchange.requestMethod} ${exchange.requestURI.path}") {
            "POST /v2/pair" -> if (Json.parse(body).obj()["code"] == "123456")
                reply(exchange, 200, """{"deviceID":"dev-1","token":"$TOKEN","scopes":["chat","image.edit"]}""")
                else reply(exchange, 401, """{"error":{"code":"wrong_code","message":"Wrong pairing code"}}""")
            "GET /v1/models" -> reply(exchange, 200, """{"object":"list","data":[{"id":"lmstudio/qwen","capabilities":["chat"]}]}""")
            "GET /v2/profiles" -> reply(exchange, 200, """[{"id":"draft","name":"Quick Draft","models":{},"steps":4}]""")
            "POST /v1/chat/completions" -> {
                val input = Json.parse(body).obj()
                when {
                    (input["model"] as String).startsWith("ollama/") ->
                        reply(exchange, 503, """{"error":{"code":"provider_unavailable","message":"Ollama is not running on this Mac","provider":"ollama"}}""")
                    input["stream"] == true -> reply(exchange, 200,
                        "data: {\"choices\":[{\"delta\":{\"content\":\"Mer\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"haba\"}}]}\n\ndata: [DONE]\n\n", "text/event-stream")
                    else -> reply(exchange, 200, """{"choices":[{"message":{"role":"assistant","content":"Merhaba"}}]}""")
                }
            }
            "POST /v1/images/edits" -> reply(exchange, 200, """{"created":1,"data":[{"b64_json":"${Base64.getEncoder().encodeToString(PNG)}","file_id":"file-1"}]}""")
            "GET /v1/jobs/job-1/recipe" -> reply(exchange, 200, """{"schemaVersion":1,"workflowName":"SDXL","parameters":{"prompt":"a fox","seed":42},"inputs":[],"modelFiles":[]}""")
            "POST /v1/jobs/job-1/replay" -> reply(exchange, 200, """{"id":"job-replay","status":"queued","variation":${Json.parse(body).obj()["variation"]}}""")
            "GET /v1/jobs/job-1/events" -> reply(exchange, 200,
                "event: progress\ndata: {\"id\":\"job-1\",\"status\":\"in_progress\",\"progress\":0.5}\n\nevent: completed\ndata: {\"id\":\"job-1\",\"status\":\"completed\"}\n\n", "text/event-stream")
            "DELETE /v2/session" -> { exchange.sendResponseHeaders(204, -1); exchange.close() }
            else -> reply(exchange, 404, """{"error":{"code":"not_found","message":"nope"}}""")
        }
    }
    server.start()
    val address = "https://127.0.0.1:${server.address.port}"
    fun invite(fp: String = fingerprint, code: String = "123456") =
        HubInvite.parse("localhub://pair?v=2&u=${URLEncoder.encode(address, Charsets.UTF_8)}&fp=$fp&c=$code&id=hub-1&n=Studio%20Mac")

    try {
        test("parses v2 and v1 invites and rejects bad ones") {
            val v2 = invite()
            check(v2.version == 2 && v2.hubId == "hub-1" && v2.hubName == "Studio Mac")
            val v1 = HubInvite.parse("artblend-companion://pair?v=1&u=https%3A%2F%2F10.0.0.2%3A8765&fp=${"AB:".repeat(31)}AB&c=999999")
            check(v1.version == 1 && v1.fingerprint == "ab".repeat(32))
            for (bad in listOf("https://evil/pair?v=2", "localhub://pair?v=1&u=https%3A%2F%2Fa%3A1&fp=${"ab".repeat(32)}&c=123456",
                    "localhub://pair?v=2&u=http%3A%2F%2Fa%3A1&fp=${"ab".repeat(32)}&c=123456", "localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=abcd&c=123456",
                    "localhub://pair?v=2&u=https%3A%2F%2Fa%3A1&fp=${"ab".repeat(32)}&c=123456&c=1")) {
                check(runCatching { HubInvite.parse(bad) }.isFailure) { bad }
            }
        }

        test("a wrong pin fails before any request reaches the hub") {
            val before = requests.size
            val failure = runCatching { HubClient(MemorySessionStore()).pair(invite(fp = "00".repeat(32)), "x", "kotlin-tests") }.exceptionOrNull()
            check(failure is PinMismatchException) { "got $failure" }
            check(requests.size == before)
        }

        test("pairs, stores the session and chats over the pin") {
            val store = MemorySessionStore()
            val client = HubClient(store)
            val session = client.pair(invite(), "Pixel 9", "kotlin-tests", listOf("chat", "image.edit"))
            check(session.token == TOKEN && session.scopes == listOf("chat", "image.edit"))
            check(HubSession.fromJson(session.toJson()) == session)
            val restored = HubClient(store).also { it.restore() }
            check(restored.models().single()["id"] == "lmstudio/qwen")
            check(requests.last().second == "Bearer $TOKEN")
            check(restored.chat(mapOf("model" to "lmstudio/qwen", "messages" to listOf(mapOf("role" to "user", "content" to "hi")))) == "Merhaba")
            val text = StringBuilder()
            restored.chatStream(mapOf("model" to "lmstudio/qwen", "messages" to emptyList<Any>())) { chunk ->
                text.append(chunk["choices"].list().first().obj()["delta"].obj()["content"] as String); true
            }
            check(text.toString() == "Merhaba")
        }

        test("hub errors carry their code; edits upload multipart; jobs stream") {
            val client = HubClient(MemorySessionStore())
            val wrong = runCatching { client.pair(invite(code = "000000"), "x", "kotlin-tests") }.exceptionOrNull()
            check(wrong is HubException && wrong.code == "wrong_code" && wrong.status == 401)
            client.pair(invite(), "x", "kotlin-tests")
            val down = runCatching { client.chat(mapOf("model" to "ollama/llama3", "messages" to emptyList<Any>())) }.exceptionOrNull()
            check(down is HubException && down.status == 503 && down.code == "provider_unavailable" && down.provider == "ollama")
            check(client.workProfiles().single()["id"] == "draft")
            val result = client.editImage(mapOf("prompt" to "add a hat", "strength" to 0.6, "profile" to "draft"), MediaInput.Bytes(PNG, "canvas.png"))
            check(result.single().first == "file-1" && result.single().second!!.contentEquals(PNG))
            val multipart = requests.last().third
            check("name=\"prompt\"\r\n\r\nadd a hat\r\n" in multipart && "filename=\"canvas.png\"\r\nContent-Type: image/png" in multipart)
            val states = mutableListOf<String>()
            client.jobEvents("job-1") { states.add(it["status"] as String) }
            check(states == listOf("in_progress", "completed"))
            check(client.recipe("job-1")["workflowName"] == "SDXL")
            check(client.replayJob("job-1", true)["variation"] == true)
            client.unpair()
            check(requests.last().first == "DELETE /v2/session" && client.session == null)
        }
        println("All $passed tests passed")
    } finally {
        server.stop(0)
    }
}
