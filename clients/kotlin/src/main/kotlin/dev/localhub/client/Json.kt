package dev.localhub.client

/** Minimal JSON: objects → Map<String, Any?>, arrays → List<Any?>, numbers → Double/Long, plus String/Boolean/null. */
object Json {
    fun parse(text: String): Any? = Parser(text).run { val value = value(); skip(); require(pos == text.length) { "Trailing JSON" }; value }

    fun stringify(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    private fun write(out: StringBuilder, value: Any?) {
        when (value) {
            null -> out.append("null")
            is String -> quote(out, value)
            is Boolean, is Int, is Long -> out.append(value.toString())
            is Double -> out.append(if (value % 1.0 == 0.0 && kotlin.math.abs(value) < 1e15) value.toLong().toString() else value.toString())
            is Float -> write(out, value.toDouble())
            is Map<*, *> -> {
                out.append('{')
                value.entries.filter { it.value != null }.forEachIndexed { index, (key, item) ->
                    if (index > 0) out.append(',')
                    quote(out, key.toString()); out.append(':'); write(out, item)
                }
                out.append('}')
            }
            is Iterable<*> -> { out.append('['); value.forEachIndexed { i, item -> if (i > 0) out.append(','); write(out, item) }; out.append(']') }
            else -> quote(out, value.toString())
        }
    }

    private fun quote(out: StringBuilder, text: String) {
        out.append('"')
        for (c in text) when {
            c == '"' -> out.append("\\\"")
            c == '\\' -> out.append("\\\\")
            c == '\n' -> out.append("\\n")
            c == '\r' -> out.append("\\r")
            c == '\t' -> out.append("\\t")
            c < ' ' -> out.append("\\u%04x".format(c.code))
            else -> out.append(c)
        }
        out.append('"')
    }

    private class Parser(val text: String) {
        var pos = 0
        fun skip() { while (pos < text.length && text[pos].isWhitespace()) pos++ }
        fun value(): Any? {
            skip()
            require(pos < text.length) { "Unexpected end of JSON" }
            return when (val c = text[pos]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (c == '-' || c.isDigit()) num() else throw IllegalArgumentException("Bad JSON at $pos")
            }
        }
        fun literal(word: String, value: Any?): Any? { require(text.startsWith(word, pos)) { "Bad JSON at $pos" }; pos += word.length; return value }
        fun obj(): Map<String, Any?> {
            val map = LinkedHashMap<String, Any?>(); pos++; skip()
            if (text[pos] == '}') { pos++; return map }
            while (true) {
                skip(); val key = str(); skip(); require(text[pos] == ':') { "Expected :" }; pos++
                map[key] = value(); skip()
                when (text[pos++]) { ',' -> continue; '}' -> return map; else -> throw IllegalArgumentException("Expected , or }") }
            }
        }
        fun arr(): List<Any?> {
            val list = ArrayList<Any?>(); pos++; skip()
            if (text[pos] == ']') { pos++; return list }
            while (true) {
                list.add(value()); skip()
                when (text[pos++]) { ',' -> continue; ']' -> return list; else -> throw IllegalArgumentException("Expected , or ]") }
            }
        }
        fun str(): String {
            require(text[pos] == '"') { "Expected string" }; pos++
            val out = StringBuilder()
            while (true) {
                val c = text[pos++]
                when (c) {
                    '"' -> return out.toString()
                    '\\' -> when (val e = text[pos++]) {
                        'n' -> out.append('\n'); 't' -> out.append('\t'); 'r' -> out.append('\r'); 'b' -> out.append('\b'); 'f' -> out.append('\u000c')
                        'u' -> { out.append(text.substring(pos, pos + 4).toInt(16).toChar()); pos += 4 }
                        else -> out.append(e)
                    }
                    else -> out.append(c)
                }
            }
        }
        fun num(): Number {
            val start = pos
            while (pos < text.length && (text[pos].isDigit() || text[pos] in "+-.eE")) pos++
            val raw = text.substring(start, pos)
            return if (raw.any { it in ".eE" }) raw.toDouble() else raw.toLong()
        }
    }
}

@Suppress("UNCHECKED_CAST")
internal fun Any?.obj(): Map<String, Any?> = this as? Map<String, Any?> ?: emptyMap()
internal fun Any?.list(): List<Any?> = this as? List<Any?> ?: emptyList()
