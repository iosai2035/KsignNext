// KsignNext — KsignNext-Bridging-Header.h
//
// Umbrella bridging header for the app target (see
// Scripts/generate_project.py, which points SWIFT_OBJC_BRIDGING_HEADER
// here). It re-exports the C bridge Swift calls:
//   * ZsignBridge.h — zsign signing (Engines/SigningEngine/)
// Its directory is on HEADER_SEARCH_PATHS. Do not move this file
// without updating SWIFT_OBJC_BRIDGING_HEADER in the generator.
#import "ZsignBridge.h"
