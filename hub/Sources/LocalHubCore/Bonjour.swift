import dnssd
import Foundation

/// Advertises the hub as `_localhub._tcp` so paired clients can find it again after the Mac's
/// IP changes. The TXT record (`v`, `id`, `fp`, `n`) only helps a client pick the right hub;
/// trust still comes from the fingerprint the client pinned when pairing.
final class BonjourAdvertiser: @unchecked Sendable {
    private var service: DNSServiceRef?

    init?(identity: HubIdentity, fingerprint: String, port: Int) {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        for (key, value) in [("v", "2"), ("id", identity.id), ("fp", fingerprint), ("n", String(identity.name.prefix(40)))] {
            let bytes = Array(value.utf8)
            guard TXTRecordSetValue(&txt, key, UInt8(bytes.count), bytes) == kDNSServiceErr_NoError else { return nil }
        }
        var ref: DNSServiceRef?
        let error = DNSServiceRegister(&ref, 0, 0, String(identity.name.prefix(60)), "_localhub._tcp", nil, nil,
            UInt16(port).bigEndian, TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), nil, nil)
        guard error == kDNSServiceErr_NoError, let ref else { return nil }
        service = ref
    }

    func stop() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
    }

    deinit { stop() }
}
