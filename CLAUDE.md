# iOS/Android Offline Speech Translation

## Critical: No Emulators or Simulators

**DO NOT create, boot, or run iOS Simulators or Android Emulators.** All testing must be done on physical devices only.

- Do not run `xcrun simctl create`, `xcrun simctl boot`, or any simulator commands
- Do not run `emulator`, `avdmanager create avd`, or any Android emulator commands
- Do not suggest using emulators/simulators as a testing strategy
- Build for physical devices using `xcodebuild -destination 'generic/platform=iOS'` or device-specific destinations

Disk space is severely limited. Simulator/emulator images consume 15-35+ GB. All target devices are available as physical hardware.

### Physical Devices
- **iPad Pro 3rd gen (A12X)**: CoreDevice `DFE60F23-ACC0-509E-AD89-FB7D770B42BF`, UDID `00008027-000A50D92EEB002E`
  - `xcrun devicectl device install app --device DFE60F23-ACC0-509E-AD89-FB7D770B42BF <app_path>`
  - xcodebuild destination: `platform=iOS,id=00008027-000A50D92EEB002E`
- **Samsung Galaxy** (Android): connected via USB for `adb install`
