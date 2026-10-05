import SwiftUI

struct SidebarView: View {
    static let width: CGFloat = 84

    @ObservedObject var store: ServiceStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(store.controllers, id: \.config.id) { controller in
                        ServiceButton(controller: controller, selected: store.selectedID == controller.config.id) {
                            store.select(controller.config.id)
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
            if let error = store.configError {
                Button(action: ConfigFile.open) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .help(error)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).ignoresSafeArea()
        }
    }
}

private struct ServiceButton: View {
    @ObservedObject var controller: ServiceController
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ServiceIcon(controller: controller)
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    BadgeView(badge: controller.badge).offset(x: 10, y: -8)
                }
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.12 : hovering ? 0.05 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(selected ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(controller.config.name)
        .contextMenu {
            Button("Reload") { controller.reload() }
            Button("Go to Home Page") { controller.goHome() }
            Divider()
            Button("Open in Browser") { controller.openInBrowser() }
            Button("Copy URL") { controller.copyURL() }
            Divider()
            Button("Edit Services…", action: ConfigFile.open)
        }
    }
}

private struct ServiceIcon: View {
    @ObservedObject var controller: ServiceController

    var body: some View {
        if let icon = controller.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Self.color(for: controller.config.name).gradient)
                .overlay(
                    Text(controller.config.name.prefix(1).uppercased())
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                )
        }
    }

    private static func color(for name: String) -> Color {
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

private struct BadgeView: View {
    let badge: Badge

    var body: some View {
        switch badge {
        case .none:
            EmptyView()
        case .dot:
            Circle()
                .fill(Color.red)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        case .count(let n):
            Text(n > 99 ? "99+" : "\(n)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 19, minHeight: 19)
                .background(Capsule().fill(Color.red))
                .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        }
    }
}
