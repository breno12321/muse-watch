import SwiftUI
import WatchKit

enum MuseStyle {
    static let accent = Color(red: 0.66, green: 0.24, blue: 0.28)
    static let bubble = Color(white: 0.12)
    static let userBubble = Color(red: 0.25, green: 0.035, blue: 0.055)
    static let secondary = Color(white: 0.62)
}

struct AvatarView: View {
    var size: CGFloat = 92
    @Environment(MuseStore.self) private var store
    var body: some View {
        avatar.resizable().scaledToFill()
            .frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .accessibilityLabel("\(store.museName), your Muse avatar")
            .id(store.avatarVersion)
    }
    private var avatar: Image {
        if let data = try? Data(contentsOf: store.avatarURL), let image = UIImage(data: data) { return Image(uiImage: image) }
        return Image("CalAvatar")
    }
}

struct MuseRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: 28).foregroundStyle(.white.opacity(0.9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.body, design: .rounded, weight: .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.caption2).foregroundStyle(MuseStyle.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.gray)
        }.padding(.vertical, 7)
    }
}

struct ConnectionLabel: View {
    @Environment(MuseStore.self) private var store
    var body: some View {
        Text(store.paired ? (store.phoneReachable ? "VIA IPHONE" : "CACHED · WILL SYNC") : "CONNECT ON IPHONE")
            .font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1)
            .foregroundStyle(MuseStyle.secondary)
    }
}
