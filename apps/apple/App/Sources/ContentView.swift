import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sailboat")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(AppInfo.name)
                .font(.largeTitle.bold())
            Text(AppInfo.version)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
