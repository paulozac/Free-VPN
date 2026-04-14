import SwiftUI

// MARK: - Sample Data

private enum SampleProfiles {
    static let wireGuard1 = SavedProfile(
        id: UUID(),
        name: "US East - New York",
        configString: "[Interface]\nAddress = 10.0.0.2/24\nPrivateKey = abc123\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = xyz789\nAllowedIPs = 0.0.0.0/0\nEndpoint = us-east.vpn.example.com:51820",
        dateAdded: Date(),
        endpoint: "us-east.vpn.example.com:51820",
        address: "10.0.0.2/24",
        protocolType: .wireGuard
    )

    static let wireGuard2 = SavedProfile(
        id: UUID(),
        name: "EU West - Amsterdam",
        configString: "[Interface]\nAddress = 10.0.1.5/24\nPrivateKey = def456\nDNS = 8.8.8.8\n\n[Peer]\nPublicKey = uvw321\nAllowedIPs = 0.0.0.0/0\nEndpoint = eu-west.vpn.example.com:51820",
        dateAdded: Date(),
        endpoint: "eu-west.vpn.example.com:51820",
        address: "10.0.1.5/24",
        protocolType: .wireGuard
    )

    static let openVPN1 = SavedProfile(
        id: UUID(),
        name: "Japan - Tokyo",
        configString: "client\nremote jp-tokyo.vpn.example.com 1194\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB...\n-----END CERTIFICATE-----\n</ca>",
        dateAdded: Date(),
        endpoint: "jp-tokyo.vpn.example.com:1194",
        address: nil,
        protocolType: .openVPN
    )

    static let openVPN2 = SavedProfile(
        id: UUID(),
        name: "Brazil - Sao Paulo",
        configString: "client\nremote br-sp.vpn.example.com 443\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB...\n-----END CERTIFICATE-----\n</ca>",
        dateAdded: Date(),
        endpoint: "br-sp.vpn.example.com:443",
        address: nil,
        protocolType: .openVPN
    )

    static let all = [wireGuard1, openVPN1, wireGuard2, openVPN2]
}

// MARK: - Screenshot: Connected State

private struct ScreenshotConnected: View {
    private let accent = Color(red: 0.13, green: 0.69, blue: 0.34)
    private let selectedID: UUID

    init() {
        selectedID = SampleProfiles.wireGuard1.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left panel
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(accent)
                    .padding(.top, 40)

                Text("Connected")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("Connected 12 minutes ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("IP: 185.212.44.73")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("New York, New York, US")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button { } label: {
                    Text("Disconnect")
                        .frame(maxWidth: .infinity)
                }

                Button { } label: {
                    Label("Upload Profile", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }

                Spacer().frame(height: 20)
            }
            .frame(width: 760)
            .padding(.horizontal, 40)

            // Right panel
            VStack(alignment: .leading, spacing: 8) {
                Text("Profiles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)

                Text("Long press a profile to rename or delete")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                VStack(spacing: 2) {
                    ForEach(SampleProfiles.all) { profile in
                        profileRow(profile)
                    }
                }
            }
            .frame(width: 950)
            .padding(.trailing, 40)
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: SavedProfile) -> some View {
        HStack {
            Image(systemName: profile.id == selectedID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.id == selectedID ? accent : .secondary)

            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.body)
                    Text(profile.vpnProtocol.shortName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(profile.vpnProtocol == .wireGuard ? accent.opacity(0.2) : Color.orange.opacity(0.2))
                        .foregroundStyle(profile.vpnProtocol == .wireGuard ? accent : .orange)
                        .clipShape(Capsule())
                }
                if let endpoint = profile.endpoint {
                    Text(endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if profile.id == selectedID {
                Text("ACTIVE")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Screenshot: Upload QR Code

private struct ScreenshotUpload: View {
    var body: some View {
        VStack(spacing: 30) {
            Text("Upload VPN Profile")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(Color(red: 0.13, green: 0.69, blue: 0.34))

            // Placeholder QR code
            RoundedRectangle(cornerRadius: 12)
                .fill(.white)
                .frame(width: 280, height: 280)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 100))
                            .foregroundStyle(.black)
                        Text("QR Code")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }

            Text("Scan this QR code with your phone\nor open the URL in a browser")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("http://192.168.1.42:8080")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)

            Button { } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 10)
        }
        .padding(40)
    }
}

// MARK: - Previews

#Preview("Screenshot: Connected with Profiles") {
    ScreenshotConnected()
}

#Preview("Screenshot: Upload QR Code") {
    ScreenshotUpload()
}
