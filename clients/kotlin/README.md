# dev.localhub.client (Kotlin)

Android / JVM client with no dependencies beyond the JDK (`HttpsURLConnection`, a tiny JSON reader/writer).
Pairing, pinning in the TLS handshake (`PinningTrustManager`), chat (+ streaming), embeddings, images, jobs,
speech, transcription, files and typed `HubException`s. Calls block: run them on `Dispatchers.IO` or similar.

```kotlin
val hub = HubClient(MySecureSessionStore(context))   // implement SessionStore with EncryptedSharedPreferences
hub.restore()
hub.pair(HubInvite.parse(scannedText), "Pixel 9", "my-app", listOf("chat"))
println(hub.chat(mapOf("model" to "lmstudio/qwen/qwen3-8b", "messages" to listOf(mapOf("role" to "user", "content" to "Merhaba")))))
```

Copy `src/main/kotlin` into your app module (or wrap it in a Gradle module). Android needs the local network
permission on API 37+ and the `INTERNET` permission.

```bash
scripts/test.sh                 # compiles with Android Studio's bundled kotlinc + JDK, runs the tests (no downloads)
scripts/example.sh '<invite>'   # pairs with a running hub and lists models
```
