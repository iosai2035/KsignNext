// KsignNext — KsignNext-Bridging-Header.h
//
// Umbrella bridging header for the app target (see
// Scripts/generate_project.py, which points SWIFT_OBJC_BRIDGING_HEADER
// here). It re-exports the two C bridges Swift calls:
//   * ZsignBridge.h — zsign signing (Engines/SigningEngine/)
//   * AppleRefreshBridge.h — Rust Apple-refresh core
//     (RustCore/apple_refresh/include/)
// Both directories are on HEADER_SEARCH_PATHS. Do not move this file
// without updating SWIFT_OBJC_BRIDGING_HEADER in the generator.
#import "ZsignBridge.h"
#import "AppleRefreshBridge.h"
