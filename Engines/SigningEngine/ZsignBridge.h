// KsignNext — ZsignBridge.h
//
// C interface between KsignNext's Swift signing code and the zsign
// signing library.
//
// The .cpp implementation of these functions is supplied by the
// MIT-licensed zsign library (claration/zsign) as a build-time
// dependency. It is NOT vendored in this repository: no zsign source
// file, header, or prebuilt binary lives under ~/workspace/ksign-next.
// Add the zsign sources to the Xcode target (or link the built
// library) and add this header to the target's bridging header; the
// Swift side calls only the ksignnext_* names declared below.
//
// Return convention: 0 on success, non-zero on failure. All string
// parameters are UTF-8, NUL-terminated C strings; any parameter may be
// NULL when it does not apply (for example provision_path for ad-hoc
// signing, or p12_password when the P12 has no password).

#ifndef KSIGNNEXT_ZSIGN_BRIDGE_H
#define KSIGNNEXT_ZSIGN_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Sign the .app bundle at app_path in place.
/// provision_path: .mobileprovision file, or NULL.
/// p12_path / p12_password: signing identity, or NULL when adhoc != 0.
/// entitlements_path: .entitlements plist, or NULL.
/// bundle_id / bundle_name / bundle_version: overrides, or NULL to keep
/// the values already in the bundle's Info.plist.
/// adhoc: non-zero for ad-hoc signing (no certificate required).
int ksignnext_zsign_sign(
    const char *app_path,
    const char *provision_path,
    const char *p12_path,
    const char *p12_password,
    const char *entitlements_path,
    const char *bundle_id,
    const char *bundle_name,
    const char *bundle_version,
    int adhoc);

/// Remove each named dylib from the Mach-O executable at app_executable.
/// dylib_names is an array of dylib_count file names (for example
/// "Tweak.dylib"); entries that are not linked are skipped, not errors.
int ksignnext_zsign_remove_dylibs(
    const char *app_executable,
    const char *const *dylib_names,
    int dylib_count);

/// Add a LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB load command for dylib_path
/// to the Mach-O executable at app_executable.
int ksignnext_zsign_inject_dylib(
    const char *app_executable,
    const char *dylib_path);

/// Rewrite a linked dylib install name in the Mach-O executable at
/// app_executable from old_path to new_path (for example to
/// "@rpath/Tweak.dylib").
int ksignnext_zsign_change_dylib_path(
    const char *app_executable,
    const char *old_path,
    const char *new_path);

#ifdef __cplusplus
}
#endif

#endif /* KSIGNNEXT_ZSIGN_BRIDGE_H */
