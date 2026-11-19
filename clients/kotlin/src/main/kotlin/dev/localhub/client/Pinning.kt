package dev.localhub.client

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Date
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

/**
 * Trusts exactly one certificate: the one whose DER SHA-256 is the paired fingerprint, and only while in date.
 * The TLS handshake fails before any HTTP bytes (or the token) are written.
 */
class PinningTrustManager(fingerprint: String) : X509TrustManager {
    private val expected = normalizeFingerprint(fingerprint)

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("No certificate")
        leaf.checkValidity(Date())
        val digest = MessageDigest.getInstance("SHA-256").digest(leaf.encoded).joinToString("") { "%02x".format(it) }
        if (digest != expected) throw PinMismatchException()
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = throw CertificateException("Not a server")
    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    companion object {
        fun socketFactory(fingerprint: String): SSLSocketFactory =
            SSLContext.getInstance("TLS").apply { init(null, arrayOf(PinningTrustManager(fingerprint)), null) }.socketFactory
    }
}

class PinMismatchException : CertificateException("The hub certificate does not match the paired fingerprint")
