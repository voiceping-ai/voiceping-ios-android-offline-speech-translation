import SwiftUI

/// Small version label for display on each screen to distinguish builds.
struct AppVersionLabel: View {
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "App"
        return "\(name) v\(version) (\(build))"
    }

    var body: some View {
        Text(versionString)
            .font(.caption2)
            .foregroundStyle(.quaternary)
    }
}
