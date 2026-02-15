# iOS/Android Offline Speech Translation

## Critical: No Emulators or Simulators

**DO NOT create, boot, or run iOS Simulators or Android Emulators.** All testing must be done on physical devices only.

- Do not run `xcrun simctl create`, `xcrun simctl boot`, or any simulator commands
- Do not run `emulator`, `avdmanager create avd`, or any Android emulator commands
- Do not suggest using emulators/simulators as a testing strategy
- Build for physical devices using `xcodebuild -destination 'generic/platform=iOS'` or device-specific destinations

Disk space is severely limited. Simulator/emulator images consume 15-35+ GB. All target devices are available as physical hardware.

### Physical Devices
- **iPhone 16 Pro Max**: `xcrun devicectl device install app --device DE309C97-CE22-5F5E-91AB-8374A6743161 <app_path>`
- **iPad 9th gen (A13)**: CoreDevice `DF651D99-9E11-5BAA-A225-18DB161230CB`
- **iPad Pro 3rd gen (A12X)**: CoreDevice `DFE60F23-ACC0-509E-AD89-FB7D770B42BF`
