//
//  ContentView.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/9/26.
//

import SwiftUI

struct ContentView: View {
    @State private var vpnManager = VPNManager()
    @State private var profileStore = ProfileStore()
    @State private var profileServer = ProfileServer()
    @State private var showingUpload = false
    @State private var showingProfiles = false

    var body: some View {
        VStack(spacing: 50) {
            Spacer()

            statusIcon
            statusLabel
            connectionDetails
            activeProfileLabel

            Spacer()

            connectButton

            HStack(spacing: 40) {
                if !profileStore.profiles.isEmpty {
                    Button {
                        showingProfiles = true
                    } label: {
                        Label("Profiles (\(profileStore.profiles.count))", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    showingUpload = true
                    profileServer.onProfileReceived = { name, config in
                        let error = profileStore.addProfile(name: name, configString: config)
                        if error == nil, let profile = profileStore.profiles.last {
                            profileStore.selectProfile(profile)
                            applySelectedProfile()
                        }
                    }
                    profileServer.start()
                } label: {
                    Label("Upload Profile", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            applySelectedProfile()
        }
        .alert("Error", isPresented: .init(
            get: { vpnManager.errorMessage != nil },
            set: { if !$0 { vpnManager.errorMessage = nil } }
        )) {
            Button("OK") {
                vpnManager.errorMessage = nil
            }
        } message: {
            Text(vpnManager.errorMessage ?? "")
        }
        .sheet(isPresented: $showingUpload, onDismiss: {
            profileServer.stop()
        }) {
            uploadSheet
        }
        .sheet(isPresented: $showingProfiles) {
            profileListSheet
        }
    }

    // MARK: - Apply Profile

    private func applySelectedProfile() {
        guard let profile = profileStore.selectedProfile else { return }
        Task {
            await vpnManager.configure(with: profile.configString)
        }
    }

    // MARK: - Upload Sheet

    @ViewBuilder
    private var uploadSheet: some View {
        NavigationStack {
            VStack {
                if let url = profileServer.localURL {
                    QRCodeView(url: url)
                } else {
                    ProgressView("Starting server...")
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showingUpload = false
                    }
                }
            }
        }
    }

    // MARK: - Profile List Sheet

    @ViewBuilder
    private var profileListSheet: some View {
        NavigationStack {
            List {
                ForEach(profileStore.profiles) { profile in
                    Button {
                        profileStore.selectProfile(profile)
                        applySelectedProfile()
                        showingProfiles = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(.headline)
                                if let endpoint = profile.endpoint {
                                    Text(endpoint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let address = profile.address {
                                    Text(address)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if profile.id == profileStore.selectedProfileID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        profileStore.removeProfile(profileStore.profiles[index])
                    }
                }
            }
            .navigationTitle("VPN Profiles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showingProfiles = false
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusIcon: some View {
        let (iconName, iconColor) = statusIconInfo
        Image(systemName: iconName)
            .font(.system(size: 120))
            .foregroundStyle(iconColor)
            .symbolEffect(.pulse, isActive: isPulsing)
    }

    private var statusIconInfo: (String, Color) {
        switch vpnManager.connectionState {
        case .connected:
            return ("lock.shield.fill", .green)
        case .connecting, .reasserting:
            return ("shield.fill", .orange)
        case .disconnecting:
            return ("shield.fill", .orange)
        case .disconnected:
            return ("shield.slash.fill", .secondary)
        case .invalid:
            return ("shield.slash.fill", .secondary)
        }
    }

    private var isPulsing: Bool {
        switch vpnManager.connectionState {
        case .connecting, .disconnecting, .reasserting:
            return true
        default:
            return false
        }
    }

    private var statusLabel: some View {
        Text(vpnManager.connectionState.rawValue)
            .font(.title)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var connectionDetails: some View {
        if vpnManager.connectionState == .connected, let date = vpnManager.connectedDate {
            Text("Connected since \(date, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var activeProfileLabel: some View {
        if let profile = profileStore.selectedProfile {
            Text(profile.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var connectButton: some View {
        Button {
            vpnManager.toggleConnection()
        } label: {
            Text(connectButtonTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .frame(width: 400)
        }
        .buttonStyle(.borderedProminent)
        .tint(connectButtonTint)
        .disabled(vpnManager.connectionState == .disconnecting)
    }

    private var connectButtonTitle: String {
        switch vpnManager.connectionState {
        case .disconnected, .invalid:
            return "Connect"
        case .connecting:
            return "Cancel"
        case .connected, .reasserting:
            return "Disconnect"
        case .disconnecting:
            return "Disconnecting..."
        }
    }

    private var connectButtonTint: Color {
        switch vpnManager.connectionState {
        case .connected, .connecting, .reasserting:
            return .red
        default:
            return .accentColor
        }
    }
}

#Preview {
    ContentView()
}
