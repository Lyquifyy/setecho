import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Session", systemImage: "list.bullet.rectangle") { Placeholder(title: "Today's session") }
            Tab("Record", systemImage: "record.circle") { Placeholder(title: "Record a set") }
            Tab("Coach", systemImage: "bubble.left.and.text.bubble.right") { Placeholder(title: "Coach") }
        }
        .tint(Theme.signal)
    }
}

private struct Placeholder: View {
    let title: String
    var body: some View {
        ZStack {
            Theme.iron.ignoresSafeArea()
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(Theme.chalk)
        }
    }
}

#Preview { RootView() }
