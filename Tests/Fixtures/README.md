# Test Fixtures

Test-only fixtures for the Phase 1 unit tests. **No real Apple
material is in this directory** — every identity and profile here is
synthetic, self-signed, and useless outside these tests.

## Password

The throwaway P12 password is **`test123`**. It protects nothing real
and is documented here so the tests can use it. Do not reuse it for
anything else.

## Generation (Linux VM, 2026-11-28)

OpenSSL 3.0.13 was used for the identities; Python `cryptography`
50.0.2 was used only where OpenSSL cannot express the dates (expired
and not-yet-valid certificates — OpenSSL has no option for a past
`notAfter`).

```sh
# Valid development identity (CN carries "Apple Development", OU is the team)
openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
  -subj "/CN=Apple Development: Test User (ABCDE12345)/OU=ABCDE12345/O=Test Org/C=US" \
  -set_serial 0x01A2B3C4
# Legacy PKCS#12 export (3DES/SHA-1 MAC) for SecPKCS12Import compatibility
openssl pkcs12 -export -legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -macalg sha1 -out valid.p12 -passout pass:test123
openssl pkcs12 -export -legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -macalg sha1 -out passwordless.p12 -passout pass:
# Cert-only P12 (no private key) for the .missingPrivateKey test
openssl pkcs12 -export -legacy -nokeys -certpbe PBE-SHA1-3DES -macalg sha1 \
  -out noprivatekey.p12 -passout pass:test123
```

The expired (`expired.p12`, `expired.cer.der`) and not-yet-valid
(`notyetvalid.cer.der`) certificates were minted with Python
`cryptography` (`not_valid_before`/`not_valid_after` 2020–2021 and
2030–2031 respectively, same CN/OU shape).

## Files

| File | Case |
|---|---|
| `valid.p12` / `valid.cer.der` | Valid development identity, password `test123` |
| `passwordless.p12` | Same identity, empty password (W-3) |
| `corrupt.p12` | 512 random bytes (invalid format) |
| `noprivatekey.p12` | Certificate only, no private key |
| `expired.p12` / `expired.cer.der` | Expired 2021-01-01 |
| `notyetvalid.cer.der` | Not valid before 2030-01-01 |
| `distribution.cer.pem` / `distribution.cer.der` | Distribution identity (PEM + DER) |
| `development.mobileprovision` | Valid development profile, 1 device, expiry +365d |
| `expired.mobileprovision` | Expired profile (expiry 2021-01-01) |
| `enterprise.mobileprovision` | `ProvisionsAllDevices`, no device list |
| `appstore.mobileprovision` | No devices, `get-task-allow` false |
| `plist-end-tag.mobileprovision` | String value containing literal `</plist>` mid-document |
| `corrupt.mobileprovision` | Random bytes, no `<?xml` span |

Team identifier everywhere is the fake `ABCDE12345`; the single test
UDID is 40 `A` characters.

## Profiles are not Apple-signed

The `.mobileprovision` files are plain XML plists, not real CMS
envelopes. That is deliberate: the Phase 1 engine scans for the first
`<?xml` and the last `</plist>` and parses the plist, and no signature
verification is attempted (there is no on-device CMS verification in
Phase 1). The R-M1 large-arc OID case is covered by the synthetic DER
builder in `Tests/Support/FixtureBuilder.swift`, not by a file.
