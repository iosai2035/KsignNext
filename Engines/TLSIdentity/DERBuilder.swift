import Foundation

/// Hand-built DER for the self-signed TLS identity certificate.
/// Pure functions, no I/O: the caller supplies the TBS fields and
/// the ECDSA signature, and gets the certificate bytes back.
///
/// Certificate fields (verified against the X.509 profile in the
/// Phase 2 design, §B.5): v3, serial = 8 random bytes (high bit
/// cleared), signature = ecdsa-with-SHA256 (1.2.840.10045.4.3.2),
/// issuer = subject = CN = device name, validity = UTCTime
/// now → now + 365 days, subjectPublicKeyInfo = id-ecPublicKey +
/// P-256 with the uncompressed point, extensions: basicConstraints
/// critical CA:FALSE, keyUsage critical digitalSignature-only,
/// extendedKeyUsage non-critical serverAuth (1.3.6.1.5.5.7.3.1),
/// subjectAltName non-critical (IP 127.0.0.1 + LAN IPv4 when known
/// + DNS "localhost").
public enum DERBuilder {

    // MARK: - Public API

    /// Builds a complete self-signed certificate. `signatureDER`
    /// must be the DER-encoded ECDSA signature over `tbs` (the
    /// caller signs the TBS bytes returned by
    /// `tbsCertificate(...)`); use `buildCertificate(...)` when the
    /// signer is available inline.
    public static func buildCertificate(commonName: String, serial: Data,
                                        notBefore: Date, notAfter: Date,
                                        publicKeyPoint: Data, lanIP: String?,
                                        signatureDER: Data) -> Data {
        let tbs = tbsCertificate(commonName: commonName, serial: serial, notBefore: notBefore,
                                 notAfter: notAfter, publicKeyPoint: publicKeyPoint, lanIP: lanIP)
        let algorithm = sequence([oid([1, 2, 840, 10045, 4, 3, 2])]) // ecdsa-with-SHA256
        let signatureValue = bitString(Data([0x00]) + signatureDER)
        return sequence([tbs, algorithm, signatureValue])
    }

    /// The TBS bytes to sign. The certificate is
    /// `SEQUENCE { tbs, algorithm, signatureValue }`.
    public static func tbsCertificate(commonName: String, serial: Data,
                                      notBefore: Date, notAfter: Date,
                                      publicKeyPoint: Data, lanIP: String?) -> Data {
        let version = contextSpecific(0, integer(2)) // [0] EXPLICIT INTEGER 2 (v3)
        let serialNumber = integer(serial)
        let algorithm = sequence([oid([1, 2, 840, 10045, 4, 3, 2])])
        let name = distinguishedName(commonName: commonName)
        let validity = sequence([utcTime(notBefore), utcTime(notAfter)])
        let subjectPublicKeyInfo = sequence([
            sequence([oid([1, 2, 840, 10045, 2, 1]), oid([1, 2, 840, 10045, 3, 1, 7])]),
            bitString(Data([0x00]) + publicKeyPoint),
        ])
        let extensions = contextSpecific(3, sequence([
            extensionItem(oid: [2, 5, 29, 19], critical: true,
                          value: sequence([])), // basicConstraints CA:FALSE
            extensionItem(oid: [2, 5, 29, 15], critical: true,
                          value: bitString(Data([0x07, 0x80]))), // keyUsage digitalSignature
            extensionItem(oid: [2, 5, 29, 37], critical: false,
                          value: sequence([oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])), // EKU serverAuth
            extensionItem(oid: [2, 5, 29, 17], critical: false,
                          value: subjectAltName(lanIP: lanIP)),
        ]))
        return sequence([version, serialNumber, algorithm, name, validity, name,
                         subjectPublicKeyInfo, extensions])
    }

    /// PKCS#8 DER for an EC private key: SEQUENCE { INTEGER 0,
    /// SEQUENCE { id-ecPublicKey, P-256 }, OCTET STRING { SEC1
    /// ECPrivateKey { INTEGER 1, OCTET STRING key, [0] P-256,
    /// [1] BIT STRING publicKey } } }. This is what
    /// `NIOSSLPrivateKey(bytes:format:.der)` accepts.
    public static func pkcs8DER(privateKeyRaw: Data, publicKeyPoint: Data) -> Data {
        let ecPrivateKey = sequence([
            integer(1),
            octetString(privateKeyRaw),
            contextSpecific(0, oid([1, 2, 840, 10045, 3, 1, 7])),
            contextSpecific(1, bitString(Data([0x00]) + publicKeyPoint)),
        ])
        return sequence([
            integer(0),
            sequence([oid([1, 2, 840, 10045, 2, 1]), oid([1, 2, 840, 10045, 3, 1, 7])]),
            octetString(ecPrivateKey),
        ])
    }

    // MARK: - DER primitives (all length-prefixed, DER-canonical)

    /// DER length: short form below 128, long form otherwise.
    public static func lengthBytes(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    public static func tlv(tag: UInt8, _ value: Data) -> Data {
        Data([tag]) + lengthBytes(value.count) + value
    }

    public static func sequence(_ elements: [Data]) -> Data {
        tlv(tag: 0x30, elements.reduce(Data(), +))
    }

    public static func set(_ elements: [Data]) -> Data {
        tlv(tag: 0x31, elements.reduce(Data(), +))
    }

    /// Context-specific constructed tag [n] EXPLICIT (0xA0 + n).
    public static func contextSpecific(_ n: Int, _ value: Data) -> Data {
        tlv(tag: UInt8(0xA0 + n), value)
    }

    /// DER INTEGER: leading zero bytes stripped, a 0x00 prefix added
    /// when the top bit is set (non-negative), at least one byte.
    public static func integer(_ value: Data) -> Data {
        var bytes = value
        while bytes.count > 1, bytes.first == 0x00 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes = Data([0x00]) + bytes
        }
        if bytes.isEmpty { bytes = Data([0x00]) }
        return tlv(tag: 0x02, bytes)
    }

    public static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return integer(Data(bytes))
    }

    public static func bitString(_ contents: Data) -> Data {
        tlv(tag: 0x03, contents)
    }

    public static func octetString(_ contents: Data) -> Data {
        tlv(tag: 0x04, contents)
    }

    public static func boolean(_ value: Bool) -> Data {
        tlv(tag: 0x01, Data([value ? 0xFF : 0x00]))
    }

    /// OID with base-128 arc encoding (first two arcs combined).
    public static func oid(_ arcs: [Int]) -> Data {
        precondition(arcs.count >= 2)
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var value = arc
            var encoded: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8((value & 0x7F) | 0x80), at: 0)
                value >>= 7
            }
            body.append(contentsOf: encoded)
        }
        return tlv(tag: 0x06, body)
    }

    /// UTCTime `YYMMDDHHMMSSZ` in UTC (valid through 2049).
    public static func utcTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%02d%02d%02d%02d%02d%02dZ",
                          (components.year ?? 0) % 100, components.month ?? 0, components.day ?? 0,
                          components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
        return tlv(tag: 0x17, Data(text.utf8))
    }

    public static func utf8String(_ value: String) -> Data {
        tlv(tag: 0x0C, Data(value.utf8))
    }

    // MARK: - X.509 structures

    /// `SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String } } }`.
    public static func distinguishedName(commonName: String) -> Data {
        sequence([set([sequence([oid([2, 5, 4, 3]), utf8String(commonName)])])])
    }

    /// One extension: `SEQUENCE { OID, [BOOLEAN critical], OCTET
    /// STRING { value } }`. The critical flag is omitted when false.
    public static func extensionItem(oid arcs: [Int], critical: Bool, value: Data) -> Data {
        var elements: [Data] = [oid(arcs)]
        if critical { elements.append(boolean(true)) }
        elements.append(octetString(value))
        return sequence(elements)
    }

    /// SAN: `SEQUENCE { [7] IP 127.0.0.1, [7] IP lanIP?, [2] DNS
    /// "localhost" }`. An unparseable LAN address is skipped, never
    /// written as garbage.
    public static func subjectAltName(lanIP: String?) -> Data {
        var elements: [Data] = []
        elements.append(tlv(tag: 0x87, Data([127, 0, 0, 1])))
        if let lanIP, let octets = ipv4Octets(lanIP) {
            elements.append(tlv(tag: 0x87, octets))
        }
        elements.append(tlv(tag: 0x82, Data("localhost".utf8)))
        return sequence(elements)
    }

    public static func ipv4Octets(_ address: String) -> Data? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return Data(bytes)
    }
}
