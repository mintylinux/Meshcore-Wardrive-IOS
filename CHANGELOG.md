# Changelog

## v1.0.26 - 2026-02-12

### Fixed
- **Ping Timeout**: Increased ping timeout from 20 seconds to 30 seconds to respect repeater rate limits
  - Repeaters are rate-limited to 4 responses per 120 seconds (30 seconds between responses)
  - Previous 20-second timeout could trigger pings too quickly at highway speeds
  - New 30-second timeout ensures at least 60 seconds between pings (30s travel + 30s timeout)
  - Prevents overwhelming single repeaters in low-density areas

### Added
- **Miles Traveled Tracking**: Display cumulative distance traveled during tracking sessions
  - Shows distance in control panel when tracking is active
  - Supports both miles and kilometers (configurable in settings)
  - Distance resets at the start of each new tracking session
  - Updates in real-time as you move
- **Screenshot Capture**: Take clean map screenshots without UI clutter
  - New camera button in app bar to capture screenshots
  - Automatically hides UI elements, control panel, floating buttons, and user location marker
  - Saves high-quality PNG to device gallery
  - Option to share screenshot immediately after capture
  - Perfect for sharing coverage maps with others
- **Color Blind Accessibility Mode**: Alternative color palettes for users with color vision deficiencies
  - Support for Deuteranopia (red-green, most common)
  - Support for Protanopia (red-green)
  - Support for Tritanopia (blue-yellow)
  - Applies to coverage boxes, sample markers, and repeater icons
  - Normal mode uses traditional green/red colors
  - Color blind modes use blue/orange, blue/yellow, or pink/teal palettes
  - Configurable in settings menu

### Technical
- Added distance tracking streams to LocationService
- Created ColorBlindPalette utility class with scientifically-designed accessible color schemes
- Modified AggregationService to accept color blind mode parameter
- Integrated screenshot package for high-quality image capture
- Added image_gallery_saver for saving screenshots to device

## v1.0.25 - 2026-01-31

### Added
- **Multi-Site Upload**: Upload your data to multiple endpoints simultaneously
  - New "Manage Upload Sites" option in settings to add/remove custom upload endpoints
  - Select which sites to upload to with checkboxes
  - Shows individual progress and results for each site
  - Default meshcore.live endpoint included by default
- **Apply Whitelist to Edges**: New toggle to optionally filter edges by Include Only Repeaters whitelist
  - When enabled, edges only show connections to whitelisted repeaters
  - Useful for analyzing coverage from specific repeaters

### Fixed
- **Upload Sites List UI**: Reworked "Manage Upload Sites" as a draggable bottom sheet to prevent overflow on all devices/themes
  - Replaced AlertDialog with DraggableScrollableSheet bottom sheet (same pattern as Settings)
  - Scrollable list with Add/Cancel/Save actions pinned at bottom
  - Eliminates the white panel stretching past the window boundary
- **Multi-Site Upload Tracking**: Samples can now be uploaded to multiple endpoints independently
  - Each endpoint tracks which samples it has received separately
  - Uploading to default endpoint no longer blocks uploading to custom endpoints
  - Database now uses per-endpoint upload tracking instead of global flag
  - Existing uploaded samples automatically migrated to new tracking system
- **Upload Reliability**: Fixed upload failures with large datasets (1000+ samples)
  - Uploads now split into batches of 100 samples to prevent timeouts
  - Increased timeout from 30 seconds to 60 seconds per batch
  - Automatic retry logic: failed batches are retried once before giving up
  - Progress feedback: UI shows "Uploading batch X of Y" during multi-batch uploads
  - Better error messages: shows which batch failed and why
  - Resolves "Failed to Upload Error: 500" issues reported by users
- **Toggle Animations**: Fixed settings dialog toggle switches not animating when clicked
  - Wrapped settings dialog in StatefulBuilder for proper state updates
  - Toggle switches now animate smoothly without closing the dialog

### Improved
- **Disconnect Control**: Added disconnect button (link_off) next to Manual Ping when connected
- **Setting Label**: Renamed "Lock Rotation to North" to "Lock Map Rotation" for clarity
- **Minimized Control Panel**: Reduced control panel to single compact row
  - Shows connection status, battery level, sample count, and Connect/Manual Ping button
  - Cleaner map view with more screen space for the map
- **Reorganized Settings**: Moved Export, Import, and Clear Map buttons from main screen to settings menu
  - New "Data Management" section in settings for better organization
  - Main screen is now less cluttered
- **Enhanced Clear Confirmation**: Clear Map dialog now shows exact sample count and warns about permanent deletion
- **Repeater Display**: Combined live (LoRa service) and historical (aggregation) repeaters
  - Repeaters remain visible on map even when disconnected from LoRa device
  - Shows complete picture of discovered repeaters
- **Privacy Enhancement**: Limited web map maximum precision to street-level (7, ~153m)
  - Removed building-level precision option (8, ~38m) for user privacy
  - Added privacy note explaining the limitation
- **Edge Filtering**: Edges from repeaters at position 0,0 are now filtered out
  - Prevents invalid edges from unconfigured/mobile repeaters
- Upload process is now more reliable for users with days of accumulated data
- Clear progress indication during large uploads
- Failed uploads now provide specific error details for troubleshooting

## v1.0.24 - 2026-01-26

### Added
- **Bluetooth Disconnection Detection**: App now detects when Bluetooth connection to LoRa device is lost
  - Automatically fails any pending pings with "Bluetooth connection lost" error
  - Updates UI within 5 seconds to show disconnected state
  - Manual ping button becomes unavailable when disconnected
  - Prevents confusing "ping failed" messages when connection is lost mid-ping

### Fixed
- Manual ping now shows clear error message when Bluetooth disconnects unexpectedly
- Pending pings are properly cleaned up when connection is lost
- Connection status UI accurately reflects current Bluetooth state

## v1.0.23 - 2026-01-26

### Added
- **App Version Tracking**: Coverage data uploaded to the web map now includes app version information
  - Web map displays which app version was used to collect each coverage area
  - Visible in coverage square popups as "App Version: 1.0.XX"
  - Helps track data quality and identify issues with specific versions
  - App versions before this release will show as UNKOWN
  
### Technical
- Centralized version constant in `lib/constants/app_version.dart`
  - Single source of truth for version number across app and uploads
  - Automatically included in all sample uploads

## v1.0.22 - 2026-01-25

### Fixed
- **Sample Layering**: Newer samples now render on top of older samples
  - When retracing paths with improved coverage, new green dots (successful) now appear on top of old red dots (failed)
  - Samples are sorted by timestamp before rendering (oldest first, newest last)
  - Fixes issue where updated coverage was hidden under outdated samples

## v1.0.21 - 2026-01-24

### Added
- **Compass/North Button**: Floating action button with compass icon to reset map rotation to north
- **Lock Rotation to North**: New setting to disable map rotation gestures, keeping map always north-oriented
- **Show Successful Pings Only**: Filter to hide failed pings and GPS-only samples, showing only successful coverage
- **Include Only Repeaters**: Whitelist specific repeaters by comma-separated prefix list (e.g., "BAD5DC49,11A958")
  - Useful for testing coverage from specific repeaters
  - Filters out samples from other repeaters

### Improved
- **Show Edges**: Fixed edge rendering to properly display purple lines connecting coverage squares to repeaters
  - Edges now only connect coverage areas to repeaters that actually responded
  - Increased line opacity from 0.3 to 0.6 and width from 1 to 2 for better visibility
  - Fixed bug where edges were never generated due to empty repeater list

### Fixed
- Edge generation now correctly passes discovered repeaters to aggregation service
- Edges no longer connect to nearest repeater; only show actual response paths

## v1.0.20 - 2026-01-21

### Fixed
- **Ignore Repeater Prefix**: Now correctly filters mobile repeaters in Discovery protocol
  - Added ignore check to Discovery responses (DISCOVER_RESP)
  - Added ignore check to ACK responses from zero-hop advertisements
  - Previously only worked with contact responses, missing Discovery/ACK packets

### Added
- **Import Data**: Import previously exported JSON files back into the app
  - New "Import" button in control panel
  - Automatically skips duplicate samples by ID
  - Shows count of newly imported samples
  - Useful for restoring data or merging datasets
- **Export Options**: Choose how to export your data
  - **Save to Folder**: Pick any location on your phone (Downloads, Documents, etc.)
  - **Share**: Share via messaging apps, email, etc. (great for sharing with wardrive groups)
  - No longer saves to hidden app folder that requires computer access

### Improved
- **Faster Ping Results**: Discovery pings now complete much faster
  - Returns immediately after 3 seconds if repeaters respond (was 10 seconds fixed)
  - Still waits full 10 seconds if no responses yet (catches slower repeaters)
  - Typical ping time reduced from 10s to 3s in good coverage areas

## v1.0.19 - 2026-01-19

### Changed
- **Switched to Discovery Protocol**: Replaced legacy #meshwar channel message pings with MeshCore Discovery protocol (DISCOVER_REQ/DISCOVER_RESP)
  - Pings now broadcast to all repeaters simultaneously instead of using channels
  - Faster response times and better reliability
  - No longer depends on finding #meshwar channel
  - Repeaters rate-limited to 4 responses per 2 minutes to prevent spam
- **Upload Deduplication**: Added client-side and server-side deduplication to prevent uploading the same samples multiple times
  - Client tracks uploaded samples per endpoint in local database
  - Server uses Cloudflare KV storage with 90-day TTL to reject duplicate sample IDs
  - Deduplication only applies to default map endpoint; self-hosted maps can upload without restriction
  - Users can keep their data locally without worrying about duplicate uploads

### Improved
- **Repeater Key Display**: All repeater public keys now display as 8-character prefixes throughout the app
  - Manual ping results show truncated keys (e.g., "BAD5DC49" instead of 64-character full key)
  - Foreground notification displays truncated keys
  - Upload payloads send 8-character prefixes instead of full keys
  - Discovered repeater list shows truncated IDs
  - Much more readable and consistent UI

### Fixed
- Build cache issue requiring `flutter clean` for proper code updates

## v1.0.17 - 2026-01-18

### Added
- **Portrait mode lock** - App now stays in true north orientation, no longer rotates with device
- **Unified tracking button** - Play button now starts both GPS tracking and auto-ping together
- **Simplified upload message** - Success dialog shows just "Upload Complete"

### Removed
- **Auto-ping toggle switch** - Now controlled by tracking button

### Changed
- Auto-ping automatically starts when tracking starts (if LoRa connected)
- Both tracking and auto-ping stop together

## v1.0.16 - 2026-01-17

### Fixed
- **CRITICAL: #meshwar channel discovery now searches all 40 channels**
  - Previously only searched channels 0-7, missing #meshwar on higher channel numbers
  - Extended discovery timeout from 3s to 6s to accommodate querying all channels
  - Fixes connection issues for users with #meshwar on channels 8-39

## v1.0.15 - 2026-01-16

### Features
- **Show Coverage Boxes Toggle**: Added toggle in settings to hide/show coverage squares on the map
- **Smaller Sample Markers**: Reduced sample marker size by 25% (from 16px to 12px) for cleaner map display
- **Repeater Friendly Names Upload**: App now uploads repeater friendly names to web map alongside node IDs
- **Settings Service Enhancement**: Added `getShowCoverage()` and `setShowCoverage()` methods to persist coverage visibility preference

### Improvements
- Users can now declutter the map by toggling coverage boxes on/off
- Sample dots are less intrusive on the map while remaining visible
- Coverage visibility setting persists between app sessions
- Web map will now display custom repeater names (e.g., "Bob's Repeater") instead of just node IDs
- Repeater names pulled from discovered repeaters list and LoRa service contact cache

## v1.0.14 - 2026-01-16

### Features
- **Repeater Name Display**: Added intelligent repeater name lookup that checks both discovered repeaters and LoRa service contact cache
- **Refresh Contact List**: Added "Refresh Contact List" button in settings to manually reload repeater names from device
- **Settings Persistence**: All app settings now persist between sessions
  - Show Samples, Show Edges, Show Repeaters, Show GPS Samples toggles
  - Color Mode (Quality/Age)
  - Ping Interval
  - Coverage Resolution/Precision
  - Ignored Repeater Prefix
- Settings are now automatically loaded on app startup and saved when changed

### Improvements
- Repeater info now displays as "RepeaterName (ID)" when name is available
- Better sample info dialog with properly formatted repeater names
- Settings state now survives app restarts

### Bug Fixes
- **CRITICAL**: Fixed repeater ID parsing - now correctly reads repeater public keys from packet path field instead of encrypted payload
  - This fixes the issue where repeater IDs were showing as incorrect values like "018C3073" instead of actual IDs like "11A958"
  - Repeater ignore feature now works correctly with proper IDs
- Fixed repeater name lookup to work with contact list data
- Fixed syntax errors in sample info display code

## v1.0.13 - 2026-01-13

### Features
- Added "Show GPS Samples" toggle to hide/show blue GPS-only markers

### Changes
- Reverted from DISCOVER_REQ/RESP to legacy channel message pings for compatibility

## v1.0.12 - 2026-01-13

### Features
- Initial stable release with wardriving functionality
- GPS tracking and sample collection
- LoRa ping via channel messages
- Coverage map visualization
- Repeater discovery
