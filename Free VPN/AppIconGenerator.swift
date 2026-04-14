import SwiftUI

/// Render this view in a preview, screenshot it, and use as app icon.
/// tvOS icon sizes: 400x240 (small), 800x480 (large), 1280x768 (App Store)
struct AppIconView: View {
    var body: some View {
        ZStack {
            // Dark green gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.35, blue: 0.17),
                    Color(red: 0.10, green: 0.55, blue: 0.28),
                    Color(red: 0.06, green: 0.35, blue: 0.17)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                // Shield icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 120, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))

                // App name
                Text("ZacVPN")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(2)
            }
        }
        .frame(width: 1280, height: 768)
    }
}

#Preview("App Icon - App Store (1280x768)") {
    AppIconView()
}

#Preview("App Icon - Square Crop (768x768)") {
    AppIconView()
        .frame(width: 768, height: 768)
        .clipped()
}
