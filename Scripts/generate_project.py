#!/usr/bin/env python3
"""Generate KsignNext.xcodeproj/project.pbxproj from the source tree.

Scans the KsignNext folder layout (App, Core, Domain, Data, Engines,
Modules, Resources, SupportingFiles, Tests) and emits a valid pbxproj
with one app target (KsignNext), one unit-test target (KsignNextTests)
and one UI-test target (KsignNextUITests), plus SPM dependencies.

SPM packages (pinned as upToNextMajor — resolved by Xcode on macOS):
  ZIPFoundation  https://github.com/weichsel/ZIPFoundation  (MIT)
  SWCompression  https://github.com/tsolomko/SWCompression  (MIT)
  swift-nio      https://github.com/apple/swift-nio          (Apache-2.0)
  swift-crypto   https://github.com/apple/swift-crypto       (Apache-2.0)
  OpenSSL        https://github.com/krzyzanowskim/OpenSSL-Package
                 (OpenSSL license; prebuilt XCFramework for iOS arm64 +
                 simulator — provides the <openssl/...> headers and
                 libcrypto/libssl that the vendored zsign C++ sources
                 need. The C++ files live in Engines/SigningEngine/zsign
                 and are compiled into the app target; see collect().)

Usage: python3 Scripts/generate_project.py   (run from the repo root)
Requires: Python 3 only. No Xcode needed to generate the file.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_NAME = "KsignNext"
BUNDLE_ID = "com.ksignnext.app"

# (repo url, minimum version, product name, package name)
SPM = [
    ("https://github.com/weichsel/ZIPFoundation", "0.9.0", "ZIPFoundation", "ZIPFoundation"),
    ("https://github.com/tsolomko/SWCompression", "4.8.0", "SWCompression", "SWCompression"),
    ("https://github.com/apple/swift-nio", "2.0.0", "NIO", "swift-nio"),
    ("https://github.com/apple/swift-nio", "2.0.0", "NIOHTTP1", "swift-nio"),
    ("https://github.com/apple/swift-crypto", "3.0.0", "Crypto", "swift-crypto"),
    ("https://github.com/krzyzanowskim/OpenSSL-Package", "3.6.5000", "OpenSSL", "OpenSSL-Package"),
]

# source dirs -> target
APP_DIRS = ["App", "Core", "Domain", "Data", "Engines", "Modules"]
RESOURCE_EXTS = {".xcassets", ".storyboard", ".strings", ".xcprivacy",
                 ".xcdatamodeld", ".plist"}


def stable_id(text):
    """Deterministic 24-char hex id, as Xcode expects."""
    return hashlib.sha256(text.encode()).hexdigest()[:24].upper()


def collect():
    app_sources, app_resources, test_sources, uitest_sources, app_headers = [], [], [], [], []
    # C/C++ sources (the vendored zsign library + its bridge shim) are
    # compiled into the app target alongside the Swift files. They live
    # under Engines/SigningEngine/zsign/ and are picked up here, not by
    # the Swift walk, so their header search paths are set in
    # common_app below.
    app_cpp_sources = []
    for d in APP_DIRS:
        base = os.path.join(ROOT, d)
        for dirpath, _dirs, files in os.walk(base):
            for f in sorted(files):
                rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
                if f.endswith(".swift"):
                    app_sources.append(rel)
                elif f.endswith((".cpp", ".c", ".cc", ".mm")):
                    app_cpp_sources.append(rel)
                elif f.endswith(".h"):
                    app_headers.append(rel)
                elif any(rel.endswith(e) for e in RESOURCE_EXTS):
                    app_resources.append(rel)
    for d, out in (("Resources", app_resources), ("SupportingFiles", app_resources)):
        base = os.path.join(ROOT, d)
        for dirpath, _dirs, files in os.walk(base):
            for f in sorted(files):
                rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
                if ".xcassets/" in rel.replace(os.sep, "/"):
                    # Files inside an asset catalog (Contents.json,
                    # AppIcon PNGs, ...) are compiled by actool as part
                    # of the catalog. Copying them loose into the
                    # Resources phase too makes two copy commands produce
                    # the same `KsignNext.app/Contents.json` and Xcode
                    # fails the build with "Multiple commands produce ..."
                    # (verified live in CI run 11, 2026-11-23).
                    continue
                if rel.endswith(".swift"):
                    app_sources.append(rel)
                elif rel.endswith(".h"):
                    app_headers.append(rel)
                elif os.path.basename(rel) in ("Info.plist",) or rel.endswith(".entitlements"):
                    # Referenced by build settings (INFOPLIST_FILE /
                    # CODE_SIGN_ENTITLEMENTS); must NOT be a build-phase file.
                    app_headers.append(rel)
                else:
                    out.append(rel)
    # The asset catalog itself goes into the Resources phase as one
    # folder.assetcatalog entry (compiled by actool); without it the
    # app icon / accent colour never make it into the bundle.
    catalog = os.path.join(ROOT, "Resources", "Assets.xcassets")
    if os.path.isdir(catalog):
        app_resources.append("Resources/Assets.xcassets")
    for dirpath, _dirs, files in os.walk(os.path.join(ROOT, "Tests")):
        for f in sorted(files):
            if not f.endswith(".swift"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, f), ROOT)
            (uitest_sources if "UITests" in rel else test_sources).append(rel)
    return (sorted(set(app_sources)), sorted(set(app_resources)),
            sorted(test_sources), sorted(uitest_sources),
            sorted(set(app_headers)), sorted(set(app_cpp_sources)))


def esc(s):
    return s.replace('"', '\\"')


def main():
    app_src, app_res, test_src, ui_src, app_headers, app_cpp = collect()
    print(f"app sources: {len(app_src)}, c/c++ sources: {len(app_cpp)}, resources: {len(app_res)}, "
          f"unit tests: {len(test_src)}, UI tests: {len(ui_src)}, "
          f"headers/other refs: {len(app_headers)}")
    if not app_src:
        print("ERROR: no Swift sources found — builders have not delivered yet.")
        sys.exit(1)

    out = []
    a = out.append
    a("// !$*UTF8*$!")
    a("{")
    a("\tarchiveVersion = 1;")
    a("\tclasses = {};")
    a("\tobjectVersion = 56;")
    a("\tobjects = {")

    # Rust Apple-refresh core (Phase 1 FFI): the XCFramework is BUILT
    # on CI (Scripts/build_rust_core.sh / the workflow step) before
    # this generator runs, and is never committed. Link it into the
    # app target when it exists on disk; REQUIRE_RUST_XCFRAMEWORK=1
    # (set by CI) makes a missing XCFramework a hard error instead of
    # a warning, so a failed Rust build cannot silently produce an
    # app without the sign-in core.
    xcframework_rel = "RustCore/AppleRefresh.xcframework"
    xcframework_dir = os.path.join(ROOT, xcframework_rel)
    xcframework_present = (
        os.path.isdir(xcframework_dir)
        and os.path.isfile(os.path.join(xcframework_dir, "Info.plist"))
    )
    require_xcframework = os.environ.get("REQUIRE_RUST_XCFRAMEWORK") == "1"
    if xcframework_present:
        print(f"Rust XCFramework found: {xcframework_rel}")
    elif require_xcframework:
        print(f"ERROR: {xcframework_rel} not found — build the Rust core first "
              f"(Scripts/build_rust_core.sh).")
        sys.exit(1)
    else:
        print(f"WARNING: {xcframework_rel} not found — generating project without "
              f"the Rust Apple-refresh core (set REQUIRE_RUST_XCFRAMEWORK=1 to "
              f"make this an error).")

    build_files, file_refs = [], []

    def add_file(rel, last_type=None):
        fid = stable_id("fileref:" + rel)
        bid = stable_id("buildfile:" + rel)
        name = os.path.basename(rel)
        if last_type is None:
            if rel.endswith(".swift"):
                last_type = "sourcecode.swift"
            elif rel.endswith(".cpp"):
                last_type = "sourcecode.cpp.cpp"
            elif rel.endswith(".c"):
                last_type = "sourcecode.c.c"
            elif rel.endswith(".mm"):
                last_type = "sourcecode.cpp.objcpp"
            elif rel.endswith(".xcassets"):
                last_type = "folder.assetcatalog"
            elif rel.endswith(".storyboard"):
                last_type = "file.storyboard"
            elif rel.endswith(".strings"):
                last_type = "text.plist.strings"
            elif rel.endswith(".xcdatamodeld"):
                last_type = "wrapper.xcdatamodel"
            elif rel.endswith(".xcprivacy"):
                last_type = "text.xml"
            elif rel.endswith(".h"):
                last_type = "sourcecode.c.h"
            elif rel.endswith(".entitlements"):
                last_type = "text.plist.entitlements"
            else:
                last_type = "text.plist.xml"
        file_refs.append(
            f'\t\t{fid} /* {esc(name)} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = {last_type}; path = {esc(name)}; '
            f'sourceTree = "<group>"; }};')
        build_files.append(
            f'\t\t{bid} /* {esc(name)} in Sources */ = {{isa = PBXBuildFile; '
            f'fileRef = {fid} /* {esc(name)} */; }};')
        return fid, bid

    src_build, res_build = [], []
    for rel in app_src:
        _f, b = add_file(rel)
        src_build.append(b)
    # C/C++ files are compiled into the app target's Sources phase just
    # like the Swift files (they implement the zsign bridge).
    for rel in app_cpp:
        _f, b = add_file(rel)
        src_build.append(b)
    for rel in app_headers:
        add_file(rel)  # reference only: no build phase
    for rel in app_res:
        _f, b = add_file(rel)
        res_build.append(b)
    test_build, ui_build = [], []
    for rel in test_src:
        _f, b = add_file(rel)
        test_build.append(b)
    for rel in ui_src:
        _f, b = add_file(rel)
        ui_build.append(b)
    # The Rust XCFramework links into the app target's Frameworks
    # phase (a static library — linked, not embedded, so there is no
    # Embed Frameworks phase for it). It is a file reference only
    # here; its build-file id is appended to the Frameworks phase
    # below.
    xc_build = []
    if xcframework_present:
        xfid = stable_id("fileref:" + xcframework_rel)
        xbid = stable_id("buildfile:" + xcframework_rel)
        file_refs.append(
            f'\t\t{xfid} /* AppleRefresh.xcframework */ = {{isa = PBXFileReference; '
            f'explicitFileType = wrapper.xcframework; path = AppleRefresh.xcframework; '
            f'sourceTree = "<group>"; }};')
        build_files.append(
            f'\t\t{xbid} /* AppleRefresh.xcframework in Frameworks */ = {{isa = PBXBuildFile; '
            f'fileRef = {xfid} /* AppleRefresh.xcframework */; }};')
        xc_build.append(xbid)

    # SPM package references (one per repo url)
    pkg_refs, pkg_products = [], []
    seen_urls = {}
    for url, _ver, product, _pkg in SPM:
        if url in seen_urls:
            continue
        pid = stable_id("pkg:" + url)
        seen_urls[url] = pid
        pkg_refs.append(
            f'\t\t{pid} /* XCRemoteSwiftPackageReference "{esc(url)}" */ = '
            f'{{isa = XCRemoteSwiftPackageReference; repositoryURL = "{esc(url)}"; '
            f'requirement = {{kind = upToNextMajorVersion; minimumVersion = '
            f'{[v for u, v, _p, _n in SPM if u == url][0]}; }}; }};')
    for url, _ver, product, _pkg in SPM:
        pid = seen_urls[url]
        did = stable_id("pkgdep:" + product)
        pkg_products.append(
            f'\t\t{did} /* {esc(product)} */ = {{isa = XCSwiftPackageProductDependency; '
            f'package = {pid} /* XCRemoteSwiftPackageReference "{esc(url)}" */; '
            f'productName = {esc(product)}; }};')

    # Groups (flat per top dir, plus nested path via children by dir)
    def group_id(path):
        return stable_id("group:" + path)

    groups = []
    all_files = (app_src + app_cpp + app_res + test_src + ui_src + app_headers
                 + ([xcframework_rel] if xcframework_present else []))
    # Every directory that contains files AND every ancestor of such a
    # directory needs a PBXGroup. A top-level dir like Core/ or Tests/
    # that holds only subdirectories still gets referenced as a child
    # of the root group, so omitting its PBXGroup leaves a dangling
    # reference and Xcode reports "project is damaged / parse error".
    dirs = set()
    for r in all_files:
        d = os.path.dirname(r)
        while d:
            dirs.add(d)
            d = os.path.dirname(d)
    dirs = sorted(dirs)
    for d in dirs:
        kids = []
        for r in all_files:
            if os.path.dirname(r) == d:
                kids.append(stable_id("fileref:" + r))
        for sub in sorted({x for x in dirs if os.path.dirname(x) == d}):
            kids.append(group_id(sub))
        kids_s = ", ".join(kids)
        groups.append(
            f'\t\t{group_id(d)} /* {esc(os.path.basename(d) or d)} */ = '
            f'{{isa = PBXGroup; children = ({kids_s}); '
            f'path = {esc(os.path.basename(d))}; sourceTree = "<group>"; }};')
    top_kids = ", ".join(group_id(d) for d in sorted(
        {r.split("/")[0] for r in all_files}))
    groups.append(
        f'\t\t{group_id("")} = {{isa = PBXGroup; children = ({top_kids}); '
        f'sourceTree = "<group>"; }};')
    # Products group
    prod_app = stable_id("product:app")
    prod_test = stable_id("product:test")
    prod_ui = stable_id("product:ui")
    groups.append(
        f'\t\t{stable_id("group:Products")} = {{isa = PBXGroup; children = '
        f'({prod_app}, {prod_test}, {prod_ui}); name = Products; '
        f'sourceTree = "<group>"; }};')

    for line in build_files + file_refs + pkg_refs + pkg_products + groups:
        a(line)

    # File refs for products
    for pid, name, ftype in (
            (prod_app, "KsignNext.app", "wrapper.application"),
            (prod_test, "KsignNextTests.xctest", "wrapper.cfbundle"),
            (prod_ui, "KsignNextUITests.xctest", "wrapper.cfbundle")):
        a(f'\t\t{pid} /* {name} */ = {{isa = PBXFileReference; '
          f'explicitFileType = {ftype}; includeInIndex = 0; '
          f'path = {name}; sourceTree = BUILT_PRODUCTS_DIR; }};')

    # Build phases
    def phase(pid, name, isa, files, extra=""):
        files_s = ", ".join(files)
        a(f'\t\t{pid} /* {name} */ = {{isa = {isa}; buildActionMask = 2147483647; '
          f'files = ({files_s}); runOnlyForDeploymentPostprocessing = 0;{extra} }};')

    app_src_phase = stable_id("phase:app:src")
    app_fw_phase = stable_id("phase:app:fw")
    app_res_phase = stable_id("phase:app:res")
    test_src_phase = stable_id("phase:test:src")
    test_fw_phase = stable_id("phase:test:fw")
    ui_src_phase = stable_id("phase:ui:src")
    ui_fw_phase = stable_id("phase:ui:fw")
    phase(app_src_phase, "Sources", "PBXSourcesBuildPhase", src_build)
    phase(app_res_phase, "Resources", "PBXResourcesBuildPhase", res_build)
    phase(test_src_phase, "Sources", "PBXSourcesBuildPhase", test_build)
    phase(ui_src_phase, "Sources", "PBXSourcesBuildPhase", ui_build)
    # Frameworks phases link SPM products into the app target
    fw_files = []
    for url, _ver, product, _pkg in SPM:
        did = stable_id("pkgdep:" + product)
        fid = stable_id("fwfile:" + product)
        fw_files.append(fid)
        # Real Xcode projects link SPM products with `productRef`, NOT
        # `fileRef`: the target is an XCSwiftPackageProductDependency,
        # which is not a PBXReference, so Xcode 26.2 rejects the project
        # with "PBXBuildFile ... whose fileReference is not a
        # PBXReference" (verified live in CI run 9, 2026-11-23).
        a(f'\t\t{fid} /* {esc(product)} in Frameworks */ = {{isa = PBXBuildFile; '
          f'productRef = {did} /* {esc(product)} */; }};')
    # The Rust XCFramework links alongside the SPM products.
    fw_files.extend(xc_build)
    phase(app_fw_phase, "Frameworks", "PBXFrameworksBuildPhase", fw_files)
    phase(test_fw_phase, "Frameworks", "PBXFrameworksBuildPhase", [])
    phase(ui_fw_phase, "Frameworks", "PBXFrameworksBuildPhase", [])

    # Targets
    def target(tid, name, product, ptype, phases, deps=(), pkg_deps=()):
        ph = ", ".join(phases)
        dp = ", ".join(deps)
        # Real Xcode projects list the linked SPM products on the target
        # itself (packageProductDependencies). Without it, and with the
        # productRef fix above, Xcode still cannot resolve the products.
        pd = ", ".join(pkg_deps)
        pkg_attr = (f'packageProductDependencies = ({pd}); '
                    if pkg_deps else "")
        a(f'\t\t{tid} /* {name} */ = {{isa = PBXNativeTarget; '
          f'buildConfigurationList = {stable_id("cfglist:" + name)} /* Build configuration list for PBXNativeTarget "{name}" */; '
          f'buildPhases = ({ph}); buildRules = (); dependencies = ({dp}); '
          f'name = {name}; {pkg_attr}productName = {name}; productReference = '
          f'{stable_id("product:" + ("app" if name == "KsignNext" else "test" if name == "KsignNextTests" else "ui"))} /* {product} */; '
          f'productType = "{ptype}"; }};')

    app_target = stable_id("target:app")
    test_target = stable_id("target:test")
    ui_target = stable_id("target:ui")
    app_pkg_deps = [stable_id("pkgdep:" + product)
                    for _url, _ver, product, _pkg in SPM]
    # Target dependencies: the test targets must declare a dependency
    # on the app target, or `xcodebuild test` never builds the app
    # module first and every `@testable import KsignNext` fails with
    # "Unable to find module dependency: 'KsignNext'" (verified live in
    # CI run 13, 2026-11-23). Format mirrors the real Ksign project:
    # PBXTargetDependency + PBXContainerItemProxy (proxyType 1).
    for tname in ("test", "ui"):
        dep_id = stable_id(f"targetdep:{tname}")
        proxy_id = stable_id(f"targetproxy:{tname}")
        a(f'\t\t{dep_id} /* PBXTargetDependency */ = {{isa = PBXTargetDependency; '
          f'target = {app_target} /* KsignNext */; '
          f'targetProxy = {proxy_id} /* PBXContainerItemProxy */; }};')
        a(f'\t\t{proxy_id} /* PBXContainerItemProxy */ = {{isa = PBXContainerItemProxy; '
          f'containerPortal = {stable_id("project")} /* Project object */; proxyType = 1; '
          f'remoteGlobalIDString = {app_target}; remoteInfo = KsignNext; }};')
    target(app_target, "KsignNext", "KsignNext.app",
           "com.apple.product-type.application",
           [app_src_phase, app_fw_phase, app_res_phase],
           pkg_deps=app_pkg_deps)
    target(test_target, "KsignNextTests", "KsignNextTests.xctest",
           "com.apple.product-type.bundle.unit-test",
           [test_src_phase, test_fw_phase],
           deps=(stable_id("targetdep:test"),))
    target(ui_target, "KsignNextUITests", "KsignNextUITests.xctest",
           "com.apple.product-type.bundle.ui-testing",
           [ui_src_phase, ui_fw_phase],
           deps=(stable_id("targetdep:ui"),))

    # Project
    proj_id = stable_id("project")
    a(f'\t\t{proj_id} /* Project object */ = {{isa = PBXProject; '
      f'attributes = {{BuildIndependentTargetsInParallel = 1; '
      f'LastUpgradeCheck = 1700; TargetAttributes = {{'
      f'{app_target} = {{CreatedOnToolsVersion = 17.0; }}; '
      f'{test_target} = {{CreatedOnToolsVersion = 17.0; TestTargetID = {app_target}; }}; '
      f'{ui_target} = {{CreatedOnToolsVersion = 17.0; TestTargetID = {app_target}; }}; }}; }}; '
      f'buildConfigurationList = {stable_id("cfglist:project")} /* Build configuration list for PBXProject "KsignNext" */; '
      f'compatibilityVersion = "Xcode 14.0"; developmentRegion = en; '
      f'hasScannedForEncodings = 0; knownRegions = (en, ar); '
      f'mainGroup = {group_id("")}; '
      f'packageReferences = ({", ".join(seen_urls.values())}); '
      f'productRefGroup = {stable_id("group:Products")} /* Products */; '
      f'projectDirPath = ""; projectRoot = ""; '
      f'targets = ({app_target}, {test_target}, {ui_target}); }};')

    # Build configurations
    def config(cid, name, settings):
        # An empty value renders as `KEY = ;`, which is invalid old-style
        # plist and makes Xcode report "project is damaged / parse error".
        # Skip empty settings entirely (e.g. DEVELOPMENT_TEAM until the
        # user supplies a real team id); the workflow sets it via
        # DEVELOPMENT_TEAM from the APPLE_TEAM_ID secret when present.
        # (Verified 2026-11-23: a strict plist parse of the generated
        # project passes only with this filter in place.)
        items = ";\n".join(f"\t\t\t\t{k} = {v}" for k, v in settings.items()
                            if v != "")
        a(f'\t\t{cid} /* {name} */ = {{isa = XCBuildConfiguration; '
          f'buildSettings = {{\n{items};\n\t\t\t}}; name = {name}; }};')

    common_app = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": "SupportingFiles/KsignNext.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "3",
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "SupportingFiles/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        # Without an explicit SDKROOT, xcodebuild defaults to the macOS
        # SDK: the scheme then offers only macOS destinations and both
        # `test` (iPhone 17 simulator) and `archive`
        # (generic/platform=iOS) fail with "Unable to find a destination"
        # (verified live in CI run 10, 2026-11-23). Real projects set
        # SDKROOT = iphoneos on their iOS targets.
        "SDKROOT": "iphoneos",
        # Umbrella bridging header (SupportingFiles/): it re-exports
        # ZsignBridge.h and AppleRefreshBridge.h. The Rust header
        # resolves through HEADER_SEARCH_PATHS below.
        "SWIFT_OBJC_BRIDGING_HEADER": "SupportingFiles/KsignNext-Bridging-Header.h",
        "SWIFT_VERSION": "5.0",
        # The vendored zsign C++ sources build with -std=c++11 upstream
        # (see research/references/zsign/build/macos/Makefile); keep
        # that standard for the app target, which is the only target
        # compiling C++ here.
        "CLANG_CXX_LANGUAGE_STANDARD": '"c++11"',
        # zsign's quoted includes ("common.h", "minizip/zip.h",
        # "zlib.h") resolve through these directories; <openssl/...>
        # comes from the OpenSSL-Package XCFramework linked below.
        # $(SRCROOT)/Engines/SigningEngine lets the umbrella bridging
        # header find ZsignBridge.h; $(SRCROOT)/RustCore/... lets it
        # find AppleRefreshBridge.h (the repo copy is the source of
        # truth; the XCFramework copy is for portability).
        "HEADER_SEARCH_PATHS": '"$(inherited) $(SRCROOT)/Engines/SigningEngine/zsign $(SRCROOT)/Engines/SigningEngine/zsign/common $(SRCROOT)/Engines/SigningEngine/zsign/third-party $(SRCROOT)/Engines/SigningEngine/zsign/third-party/zlib $(SRCROOT)/Engines/SigningEngine $(SRCROOT)/RustCore/apple_refresh/include"',
        # minizip (used by zsign's Zip::Archive/Extract) calls zlib,
        # but only its headers are vendored — the implementation is the
        # system libz that ships in the iOS SDK, so the 1.3 MB of
        # vendored zlib sources are not in the repo.
        # The Rust Apple-refresh core additionally needs the system
        # frameworks its transitive deps link against (design §8.3.3):
        # Security — getrandom (SecRandomCopyBytes) + security-framework
        # (rustls platform verifier + TLS); SystemConfiguration —
        # reqwest system-proxy; CoreFoundation — security-framework /
        # core-foundation bindings. No -lc++ is needed for the Rust
        # static library itself (pure Rust + C from ring); the app
        # already links libc++ for zsign.
        "OTHER_LDFLAGS": '"$(inherited) -lz -framework Security -framework SystemConfiguration -framework CoreFoundation"',
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }
    for cfg, extra in (("Debug", {"CODE_SIGN_IDENTITY": '"Apple Development"',
                                  "DEBUG_INFORMATION_FORMAT": "dwarf",
                                  # @testable import needs the app module
                                  # built with testability enabled.
                                  "ENABLE_TESTABILITY": "YES",
                                  "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"'}),
                       ("Release", {"CODE_SIGN_IDENTITY": '"Apple Distribution"',
                                    "COPY_PHASE_STRIP": "NO",
                                    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
                                    "SWIFT_OPTIMIZATION_LEVEL": '"-O"'})):
        s = dict(common_app)
        s.update(extra)
        config(stable_id(f"cfg:app:{cfg}"), cfg, s)
    for cfg in ("Debug", "Release"):
        config(stable_id(f"cfg:test:{cfg}"), cfg, {
            "BUNDLE_LOADER": '"$(TEST_HOST)"',
            "CODE_SIGN_STYLE": "Automatic",
            "ENABLE_TESTABILITY": "YES",
            "INFOPLIST_FILE": "Tests/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
            "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @loader_path/Frameworks"',
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".tests",
            "PRODUCT_NAME": '"$(TARGET_NAME)"',
            "SDKROOT": "iphoneos",
            "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": '"1,2"',
            "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/KsignNext.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/KsignNext"',
        })
        config(stable_id(f"cfg:ui:{cfg}"), cfg, {
            "CODE_SIGN_STYLE": "Automatic",
            "ENABLE_TESTABILITY": "YES",
            "INFOPLIST_FILE": "Tests/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".uitests",
            "PRODUCT_NAME": '"$(TARGET_NAME)"',
            "SDKROOT": "iphoneos",
            "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": '"1,2"',
            "TEST_TARGET_NAME": "KsignNext",
        })
        config(stable_id(f"cfg:proj:{cfg}"), cfg, {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
            "CLANG_ENABLE_MODULES": "YES",
            "CURRENT_PROJECT_VERSION": "3",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if cfg == "Debug" else '"dwarf-with-dsym"',
            "GCC_C_LANGUAGE_STANDARD": "gnu11",
            "MARKETING_VERSION": "1.0",
            "SWIFT_VERSION": "5.0",
        })

    def cfglist(lid, name, cfgs):
        items = ", ".join(f"{stable_id(c)} /* {n} */" for c, n in cfgs)
        a(f'\t\t{lid} /* Build configuration list for PBXNativeTarget "{name}" */ = '
          f'{{isa = XCConfigurationList; buildConfigurations = ({items}); '
          f'defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')

    cfglist(stable_id("cfglist:KsignNext"), "KsignNext",
            [(f"cfg:app:{c}", c) for c in ("Debug", "Release")])
    cfglist(stable_id("cfglist:KsignNextTests"), "KsignNextTests",
            [(f"cfg:test:{c}", c) for c in ("Debug", "Release")])
    cfglist(stable_id("cfglist:KsignNextUITests"), "KsignNextUITests",
            [(f"cfg:ui:{c}", c) for c in ("Debug", "Release")])
    cfglist(stable_id("cfglist:project"), "KsignNext",
            [(f"cfg:proj:{c}", c) for c in ("Debug", "Release")])

    a("\t};")
    a(f'\trootObject = {proj_id} /* Project object */;')
    a("}")

    outdir = os.path.join(ROOT, "KsignNext.xcodeproj")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "project.pbxproj"), "w") as f:
        f.write("\n".join(out) + "\n")
    print("Wrote KsignNext.xcodeproj/project.pbxproj")

    # Shared scheme: CI runs xcodebuild -scheme KsignNext, and a fresh
    # checkout has no auto-generated schemes, so the scheme must be in
    # the repo (xcshareddata). Without it every xcodebuild step fails
    # with "scheme not found" before doing any real work.
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      runPostActionsOnFailure = "NO">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "KsignNext.app"
               BlueprintName = "KsignNext"
               ReferencedContainer = "container:KsignNext.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "KsignNextTests.xctest"
               BlueprintName = "KsignNextTests"
               ReferencedContainer = "container:KsignNext.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ui_target}"
               BuildableName = "KsignNextUITests.xctest"
               BlueprintName = "KsignNextUITests"
               ReferencedContainer = "container:KsignNext.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "KsignNextTests.xctest"
               BlueprintName = "KsignNextTests"
               ReferencedContainer = "container:KsignNext.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ui_target}"
               BuildableName = "KsignNextUITests.xctest"
               BlueprintName = "KsignNextUITests"
               ReferencedContainer = "container:KsignNext.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "KsignNext.app"
            BlueprintName = "KsignNext"
            ReferencedContainer = "container:KsignNext.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "KsignNext.app"
            BlueprintName = "KsignNext"
            ReferencedContainer = "container:KsignNext.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    scheme_dir = os.path.join(outdir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)
    with open(os.path.join(scheme_dir, "KsignNext.xcscheme"), "w") as f:
        f.write(scheme)
    print("Wrote KsignNext.xcodeproj/xcshareddata/xcschemes/KsignNext.xcscheme")


if __name__ == "__main__":
    main()
