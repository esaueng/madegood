import SwiftUI

struct WatchContentView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sailboat")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(AppInfo.name)
                .font(.headline)
            Text(AppInfo.version)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    WatchContentView()
}
