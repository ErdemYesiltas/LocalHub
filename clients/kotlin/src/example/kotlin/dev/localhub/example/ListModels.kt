package dev.localhub.example

import dev.localhub.client.HubClient
import dev.localhub.client.HubException
import dev.localhub.client.HubInvite
import dev.localhub.client.MemorySessionStore

/** Pair with a running hub from its invite and list models: scripts/example.sh '<invite>' */
fun main(args: Array<String>) {
    val client = HubClient(MemorySessionStore())
    val session = client.pair(HubInvite.parse(args[0]), "Kotlin example", "example")
    println("paired with ${session.hubName ?: session.address} as ${session.deviceId}")
    client.integrations().forEach { println("integration ${it["id"]}: ${it["state"]}") }
    client.models().forEach { println("model ${it["id"]} ${it["capabilities"]}") }
    try {
        client.chat(mapOf("model" to "ollama/llama3", "messages" to emptyList<Any>()))
    } catch (e: HubException) {
        println("ollama ${e.status} ${e.code}: ${e.message}")
    }
    client.unpair()
    println("unpaired")
}
