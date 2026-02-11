import SwiftUI

extension Notification.Name {
    static let showHowToScan = Notification.Name("AudioEnv.showHowToScan")
}

struct HowToScanView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How To Scan")
                .font(.headline)
                .fontWeight(.semibold)

            Text("1. Click Scan in the toolbar to scan default locations.")
            Text("2. For more folders, open Manage Paths and add a directory.")
            Text("3. Click Start Scan to include the new paths.")

            Divider().padding(.vertical, 6)

            Text("Defaults scanned: Documents, Desktop, Music, Downloads")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
