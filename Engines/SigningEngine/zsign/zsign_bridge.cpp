// zsign_bridge.cpp
//
// Implements the C functions declared in ZsignBridge.h by driving the
// vendored zsign library (MIT, see LICENSE-zsign in this directory).
// Written for Ksign Next: it mirrors the zsign command-line flows
// (sign a folder, unzip-sign-rezip an IPA, inject/remove a dylib)
// without copying the CLI itself.
//
// Return convention (per ZsignBridge.h): 0 = success, nonzero = failure.
// The zsign library logs its own diagnostics to stderr; callers turn a
// nonzero code into a SigningError with the stage and file attached.

#include "bundle.h"
#include "macho.h"
#include "openssl.h"
#include "common/archive.h"
#include "common/fs.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

std::string orEmpty(const char *s) { return s ? std::string(s) : std::string(); }

// Signs one extracted bundle folder with the given asset. Mirrors the
// zsign CLI's SignFolder call (force, SHA-256 only, no cache).
bool signFolder(const std::string &folder, const std::string &p12Path,
                const std::string &password, const std::string &provPath,
                const std::string &entitlementsPath, const std::string &bundleId,
                const std::string &bundleVersion, const std::string &bundleName,
                bool adhoc) {
    ZSignAsset asset;
    if (!asset.Init("", p12Path, provPath, entitlementsPath, password, adhoc,
                    /* bSHA256Only */ true, /* bSingleBinary */ false)) {
        return false;
    }
    ZBundle bundle;
    return bundle.SignFolder(&asset, folder, bundleId, bundleVersion, bundleName,
                             /* dylibFiles */ {}, /* removeDylibNames */ {},
                             /* bForce */ true, /* bWeakInject */ false,
                             /* bEnableCache */ false, /* bRemoveProvision */ false);
}

uint32_t readU32(const uint8_t *p, bool swap) {
    uint32_t v;
    std::memcpy(&v, p, sizeof(v));
    return swap ? __builtin_bswap32(v) : v;
}

// Rewrites one dylib install name inside a single thin Mach-O slice.
// The new name must fit in the space the old name occupied (same length
// or shorter); anything longer is refused rather than corrupting the
// header. Returns 0 on a rewrite, 1 when the old name is absent, 2 when
// the new name does not fit, 3 when the slice is not a Mach-O.
int rewriteSlice(uint8_t *base, uint32_t length, const std::string &oldPath,
                 const std::string &newPath) {
    if (length < 4) return 3;
    uint32_t magic = readU32(base, false);
    bool is64 = false;
    bool swap = false;
    if (magic == MH_MAGIC_64) {
        is64 = true;
    } else if (magic == MH_MAGIC) {
        is64 = false;
    } else if (magic == MH_CIGAM_64) {
        is64 = true;
        swap = true;
    } else if (magic == MH_CIGAM) {
        is64 = false;
        swap = true;
    } else {
        return 3;
    }
    const uint32_t headerSize = is64 ? 32 : 28;
    if (length < headerSize) return 3;
    const uint32_t ncmds = readU32(base + 16, swap);
    uint32_t off = headerSize;
    bool found = false;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (off + 8 > length) return 3;
        const uint32_t cmd = readU32(base + off, swap);
        const uint32_t cmdsize = readU32(base + off + 4, swap);
        if (cmdsize < 8 || off + cmdsize > length) return 3;
        if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB ||
            cmd == LC_REEXPORT_DYLIB || cmd == LC_LOAD_UPWARD_DYLIB ||
            cmd == LC_ID_DYLIB) {
            // dylib_command: cmd, cmdsize, name.offset, timestamp,
            // current_version, compatibility_version (24 bytes).
            const uint32_t nameOff = readU32(base + off + 8, swap);
            if (nameOff + 1 <= cmdsize) {
                const char *name = reinterpret_cast<const char *>(base + off + nameOff);
                const uint32_t room = cmdsize - nameOff;
                if (std::strncmp(name, oldPath.c_str(), room) == 0 &&
                    std::strlen(name) == oldPath.size()) {
                    if (newPath.size() + 1 > room) return 2;
                    std::memcpy(base + off + nameOff, newPath.c_str(), newPath.size() + 1);
                    std::memset(base + off + nameOff + newPath.size() + 1, 0,
                                room - (uint32_t)newPath.size() - 1);
                    found = true;
                }
            }
        }
        off += cmdsize;
    }
    return found ? 0 : 1;
}

} // namespace

extern "C" int ksignnext_zsign_sign(
    const char *app_path, const char *provision_path, const char *p12_path,
    const char *p12_password, const char *entitlements_path, const char *bundle_id,
    const char *bundle_name, const char *bundle_version, int adhoc) {
    if (!app_path || !*app_path) return 1;
    const std::string strAppPath = app_path;
    const bool isZip = ZFile::IsZipFile(strAppPath.c_str());
    std::string folder = strAppPath;
    std::string tempFolder;
    if (isZip) {
        // Mirror the CLI: unzip to a temp folder, sign, re-archive.
        char tmpl[] = "/tmp/zsign_folder_XXXXXX";
        if (!mkdtemp(tmpl)) return 2;
        tempFolder = tmpl;
        folder = tempFolder;
        if (!Zip::Extract(strAppPath.c_str(), folder.c_str())) {
            ZFile::RemoveFolder(tempFolder.c_str());
            return 3;
        }
    } else if (!ZFile::IsFolder(strAppPath.c_str())) {
        // Single Mach-O files are not signed through this entry point;
        // the engine always passes bundle folders.
        return 4;
    }
    const bool ok = signFolder(folder, orEmpty(p12_path), orEmpty(p12_password),
                               orEmpty(provision_path), orEmpty(entitlements_path),
                               orEmpty(bundle_id), orEmpty(bundle_version),
                               orEmpty(bundle_name), adhoc != 0);
    if (!ok) {
        if (!tempFolder.empty()) ZFile::RemoveFolder(tempFolder.c_str());
        return 5;
    }
    if (isZip) {
        // Re-archive the signed tree over the original file, like the CLI.
        // The temp folder is the extraction root and already contains
        // Payload/, so archiving it keeps the Payload/ prefix.
        std::string tmpZip = strAppPath + ".zsign-tmp";
        if (!Zip::Archive(tempFolder.c_str(), tmpZip.c_str(), 6)) {
            ZFile::RemoveFolder(tempFolder.c_str());
            return 6;
        }
        ZFile::RemoveFile(strAppPath.c_str());
        if (::rename(tmpZip.c_str(), strAppPath.c_str()) != 0) {
            ZFile::RemoveFolder(tempFolder.c_str());
            return 7;
        }
        ZFile::RemoveFolder(tempFolder.c_str());
    }
    return 0;
}

extern "C" int ksignnext_zsign_remove_dylibs(
    const char *app_executable, const char *const *dylib_names, int dylib_count) {
    if (!app_executable || !*app_executable || !dylib_names || dylib_count <= 0) return 1;
    ZMachO macho;
    if (!macho.Init(app_executable)) return 2;
    std::set<std::string> names;
    for (int i = 0; i < dylib_count; i++) {
        if (!dylib_names[i]) continue;
        std::string name = dylib_names[i];
        // Bare names match the @executable_path/ form, mirroring the CLI.
        if (name.find('/') == std::string::npos) name = "@executable_path/" + name;
        names.insert(name);
    }
    macho.RemoveDylibs(names);
    return 0;
}

extern "C" int ksignnext_zsign_inject_dylib(
    const char *app_executable, const char *dylib_path) {
    if (!app_executable || !*app_executable || !dylib_path || !*dylib_path) return 1;
    ZMachO macho;
    if (!macho.Init(app_executable)) return 2;
    if (!macho.InjectDylib(/* bWeakInject */ false, dylib_path)) return 3;
    return 0;
}

extern "C" int ksignnext_zsign_change_dylib_path(
    const char *app_executable, const char *old_path, const char *new_path) {
    if (!app_executable || !*app_executable || !old_path || !*old_path ||
        !new_path || !*new_path) {
        return 1;
    }
    const std::string oldStr = old_path;
    const std::string newStr = new_path;
    const int fd = ::open(app_executable, O_RDWR);
    if (fd < 0) return 2;
    struct stat st;
    if (::fstat(fd, &st) != 0 || st.st_size < 4) {
        ::close(fd);
        return 2;
    }
    uint8_t *base = static_cast<uint8_t *>(
        ::mmap(nullptr, static_cast<size_t>(st.st_size), PROT_READ | PROT_WRITE,
               MAP_SHARED, fd, 0));
    if (base == MAP_FAILED) {
        ::close(fd);
        return 2;
    }
    const size_t fileSize = static_cast<size_t>(st.st_size);
    int result = 0;
    const uint32_t rawMagic = readU32(base, false);
    if (rawMagic == FAT_MAGIC || rawMagic == FAT_CIGAM) {
        // Fat binary: the header and arch table are big-endian on disk.
        const uint32_t nfat = readU32(base + 4, /* swap */ true);
        if (8 + nfat * 20 > fileSize) {
            result = 3;
        } else {
            bool anyRewritten = false;
            for (uint32_t i = 0; i < nfat; i++) {
                const uint8_t *arch = base + 8 + i * 20;
                const uint32_t offset = readU32(arch + 8, /* swap */ true);
                const uint32_t size = readU32(arch + 12, /* swap */ true);
                if (offset + size > fileSize) {
                    result = 3;
                    break;
                }
                const int r = rewriteSlice(base + offset, size, oldStr, newStr);
                if (r == 0) {
                    anyRewritten = true;
                } else if (r == 2) {
                    result = 5; // new name does not fit
                    break;
                } else if (r == 3) {
                    result = 3;
                    break;
                }
            }
            if (result == 0 && !anyRewritten) result = 4; // old path not found
        }
    } else {
        result = rewriteSlice(base, static_cast<uint32_t>(fileSize), oldStr, newStr);
        if (result == 1) result = 4; // old path not found
        if (result == 2) result = 5; // new name does not fit
    }
    ::msync(base, fileSize, MS_SYNC);
    ::munmap(base, fileSize);
    ::close(fd);
    return result;
}
