//
//  ContentView.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/9/26.
//

import SwiftUI

// MARK: - Theme

private enum Theme {
    static let accent = Color(red: 0.13, green: 0.69, blue: 0.34)
}

// MARK: - Main View

struct ContentView: View {
    @State private var vpnManager = VPNManager()
    @State private var profileStore = ProfileStore()
    @State private var profileServer = ProfileServer()
    @State private var showingUpload = false
    @State private var renamingProfile: SavedProfile?
    @State private var renameText = ""
    @State private var deletingProfile: SavedProfile?

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                // Left: Status + Controls
                VStack(spacing: 20) {
                    Image(systemName: statusIconName)
                        .font(.system(size: 80))
                        .foregroundStyle(statusIconColor)
                        .symbolEffect(.pulse, isActive: vpnManager.connectionState == .connecting || vpnManager.connectionState == .disconnecting || vpnManager.connectionState == .reasserting)
                        .padding(.top, 40)

                    Text(vpnManager.connectionState.rawValue)
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    if vpnManager.connectionState == .connected {
                        VStack(spacing: 4) {
                            if let date = vpnManager.connectedDate {
                                Text("Connected \(date, style: .relative) ago")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let ip = vpnManager.serverIP {
                                Text("IP: \(ip)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let location = vpnManager.serverCity {
                                Text(location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Button {
                        vpnManager.toggleConnection()
                    } label: {
                        Text(connectButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(vpnManager.connectionState == .disconnecting)

                    Button {
                        profileServer.onProfileReceived = { name, config in
                            let error = profileStore.addProfile(name: name, configString: config)
                            if error == nil, let profile = profileStore.profiles.last {
                                profileStore.selectProfile(profile)
                                applySelectedProfile()
                            }
                        }
                        profileServer.start()
                        showingUpload = true
                    } label: {
                        Label("Upload Profile", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }

                    Spacer().frame(height: 20)
                }
                .focusSection()
                .containerRelativeFrame(.horizontal) { length, _ in length * 0.4 }
                .padding(.horizontal, 40)

                // Right: Profile list
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profiles")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)

                    Text("Long press a profile to rename or delete")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(profileStore.profiles) { profile in
                                Button {
                                    let wasConnected = vpnManager.connectionState == .connected || vpnManager.connectionState == .connecting
                                    profileStore.selectProfile(profile)
                                    if wasConnected {
                                        reconnectWithProfile(profile)
                                    } else {
                                        applySelectedProfile()
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: profile.id == profileStore.selectedProfileID ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(profile.id == profileStore.selectedProfileID ? Theme.accent : .secondary)

                                        VStack(alignment: .leading) {
                                            HStack(spacing: 6) {
                                                Text(profile.name)
                                                    .font(.body)
                                                Text(profile.vpnProtocol.shortName)
                                                    .font(.caption2)
                                                    .fontWeight(.semibold)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(profile.vpnProtocol == .wireGuard ? Theme.accent.opacity(0.2) : Color.orange.opacity(0.2))
                                                    .foregroundStyle(profile.vpnProtocol == .wireGuard ? Theme.accent : .orange)
                                                    .clipShape(Capsule())
                                            }
                                            if let endpoint = profile.endpoint {
                                                Text(endpoint)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        if profile.id == profileStore.selectedProfileID {
                                            Text("ACTIVE")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundStyle(Theme.accent)
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                                .contextMenu {
                                    Button {
                                        renameText = profile.name
                                        renamingProfile = profile
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        deletingProfile = profile
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .focusSection()
                .containerRelativeFrame(.horizontal) { length, _ in length * 0.5 }
                .padding(.trailing, 40)
            }
            .alert("Error", isPresented: .init(
                get: { vpnManager.errorMessage != nil },
                set: { if !$0 { vpnManager.errorMessage = nil } }
            )) {
                Button("OK") { vpnManager.errorMessage = nil }
            } message: {
                Text(vpnManager.errorMessage ?? "")
            }
            .alert("Rename Profile", isPresented: .init(
                get: { renamingProfile != nil },
                set: { if !$0 { renamingProfile = nil } }
            )) {
                TextField("Profile name", text: $renameText)
                Button("Save") {
                    if let profile = renamingProfile {
                        profileStore.renameProfile(profile, to: renameText)
                    }
                    renamingProfile = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingProfile = nil
                }
            }
            .alert("Delete Profile", isPresented: .init(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let profile = deletingProfile {
                        profileStore.removeProfile(profile)
                        applySelectedProfile()
                    }
                    deletingProfile = nil
                }
                Button("Cancel", role: .cancel) {
                    deletingProfile = nil
                }
            } message: {
                Text("Are you sure you want to delete \"\(deletingProfile?.name ?? "")\"?")
            }
            .sheet(isPresented: $showingUpload, onDismiss: {
                profileServer.stop()
            }) {
                NavigationStack {
                    if let url = profileServer.localURL {
                        QRCodeView(url: url) {
                            showingUpload = false
                        }
                    } else {
                        ProgressView("Starting server...")
                    }
                }
            }
        }
        .onAppear {
            applySelectedProfile()
        }
    }

    // MARK: - Helpers

    private func applySelectedProfile() {
        guard let profile = profileStore.selectedProfile else { return }
        Task {
            await vpnManager.configure(with: profile.configString, protocolType: profile.vpnProtocol)
        }
    }

    private func reconnectWithProfile(_ profile: SavedProfile) {
        Task {
            await vpnManager.reconfigure(with: profile.configString, protocolType: profile.vpnProtocol)
        }
    }

    private var statusIconName: String {
        switch vpnManager.connectionState {
        case .connected: "lock.shield.fill"
        case .connecting, .reasserting, .disconnecting: "shield.fill"
        case .disconnected, .invalid: "shield.slash.fill"
        }
    }

    private var statusIconColor: Color {
        switch vpnManager.connectionState {
        case .connected: Theme.accent
        case .connecting, .reasserting, .disconnecting: .orange
        case .disconnected, .invalid: .secondary
        }
    }

    private var connectButtonTitle: String {
        switch vpnManager.connectionState {
        case .disconnected, .invalid: "Connect"
        case .connecting: "Cancel"
        case .connected, .reasserting: "Disconnect"
        case .disconnecting: "Disconnecting..."
        }
    }
}

#Preview {
    ContentView()
}
