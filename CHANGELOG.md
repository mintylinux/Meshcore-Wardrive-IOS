# Changelog

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
