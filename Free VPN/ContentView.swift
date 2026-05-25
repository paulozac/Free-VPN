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
    @State private var editingCredentialsProfile: SavedProfile?
    @State private var editUsername = ""
    @State private var editPassword = ""
    @State private var showPassword = false
    @Namespace private var focusNamespace

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
                            if let selectedProfile = profileStore.profiles.first(where: { $0.id == profileStore.selectedProfileID }) {
                                Text(selectedProfile.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(selectedProfile.vpnProtocol.displayName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.accent)
                            }
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
                            HStack(spacing: 12) {
                                Label(VPNManager.formattedBytes(vpnManager.bytesIn), systemImage: "arrow.down.circle.fill")
                                Label(VPNManager.formattedBytes(vpnManager.bytesOut), systemImage: "arrow.up.circle.fill")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        }
                    }

                    Spacer()

                    Button {
                        profileServer.onProfileReceived = { name, config, username, password in
                            let error = profileStore.addProfile(name: name, configString: config, username: username, password: password)
                            if error == nil, let profile = profileStore.profiles.last {
                                profileStore.selectProfile(profile)
                                connectToProfile(profile)
                            }
                        }
                        profileServer.start()
                        showingUpload = true
                    } label: {
                        Label("Upload Profile", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .prefersDefaultFocus(profileStore.profiles.isEmpty, in: focusNamespace)

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

                    Text("Click on a profile to connect \u{2022} Long press to manage")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if profileStore.profiles.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 40))
                                .foregroundStyle(Theme.accent)
                            Text("Upload a VPN Profile to get started")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.accent)
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }

                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(profileStore.profiles) { profile in
                                let isActive = isProfileActive(profile)
                                let isTransitioning = isProfileTransitioning(profile)

                                Button {
                                    handleProfileTap(profile)
                                } label: {
                                    HStack {
                                        Image(systemName: isActive ? "checkmark.shield.fill" : isTransitioning ? "shield.fill" : "shield")
                                            .foregroundStyle(isActive ? .white : isTransitioning ? .orange : .secondary)
                                            .symbolEffect(.pulse, isActive: isTransitioning)

                                        VStack(alignment: .leading) {
                                            HStack(spacing: 6) {
                                                Text(profile.name)
                                                    .font(.body)
                                                    .foregroundStyle(isActive ? .white : .secondary)
                                                Text(profile.vpnProtocol.shortName)
                                                    .font(.caption2)
                                                    .fontWeight(.semibold)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(isActive ? Color.white.opacity(0.25) : profile.vpnProtocol == .wireGuard ? Theme.accent.opacity(0.2) : Color.orange.opacity(0.2))
                                                    .foregroundStyle(isActive ? .white : profile.vpnProtocol == .wireGuard ? Theme.accent : .orange)
                                                    .clipShape(Capsule())
                                            }
                                            if isActive {
                                                Text("Click to disconnect")
                                                    .font(.caption)
                                                    .foregroundStyle(.white.opacity(0.8))
                                            } else if let endpoint = profile.endpoint {
                                                Text(endpoint)
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }

                                        Spacer()

                                        if isActive {
                                            Text("ACTIVE")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.white)
                                        } else if isTransitioning {
                                            ProgressView()
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(isActive ? Theme.accent : .clear)
                                    )
                                }
                                .disabled(vpnManager.connectionState == .disconnecting)
                                .prefersDefaultFocus(profile.id == profileStore.profiles.first?.id, in: focusNamespace)
                                .contextMenu {
                                    Button {
                                        renameText = profile.name
                                        renamingProfile = profile
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    if profile.requiresAuth {
                                        Button {
                                            editUsername = profile.username ?? ""
                                            editPassword = profile.password ?? ""
                                            editingCredentialsProfile = profile
                                        } label: {
                                            Label("Edit Credentials", systemImage: "person.badge.key")
                                        }
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
            .focusScope(focusNamespace)
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
            .sheet(isPresented: .init(
                get: { editingCredentialsProfile != nil },
                set: { if !$0 { editingCredentialsProfile = nil; showPassword = false } }
            )) {
                NavigationStack {
                    VStack(spacing: 24) {
                        Text("Edit credentials for \"\(editingCredentialsProfile?.name ?? "")\"")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 20)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Username")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            TextField("Enter your VPN username", text: $editUsername)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Password")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            HStack {
                                if showPassword {
                                    TextField("Enter your VPN password", text: $editPassword)
                                } else {
                                    SecureField("Enter your VPN password", text: $editPassword)
                                }
                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 20) {
                            Button("Cancel", role: .cancel) {
                                editingCredentialsProfile = nil
                                showPassword = false
                            }
                            Button("Save") {
                                if let profile = editingCredentialsProfile {
                                    profileStore.updateCredentials(profile, username: editUsername, password: editPassword)
                                    if isProfileActive(profile) {
                                        connectToProfile(profileStore.profiles.first(where: { $0.id == profile.id }) ?? profile)
                                    }
                                }
                                editingCredentialsProfile = nil
                                showPassword = false
                            }
                        }
                        .padding(.top, 12)

                        Spacer()
                    }
                    .padding(40)
                }
            }
            .alert("Delete Profile", isPresented: .init(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let profile = deletingProfile {
                        let wasActive = isProfileActive(profile)
                        profileStore.removeProfile(profile)
                        if wasActive {
                            vpnManager.disconnect()
                        }
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
    }

    // MARK: - Helpers

    private func isProfileActive(_ profile: SavedProfile) -> Bool {
        profile.id == profileStore.selectedProfileID && vpnManager.connectionState == .connected
    }

    private func isProfileTransitioning(_ profile: SavedProfile) -> Bool {
        profile.id == profileStore.selectedProfileID && (vpnManager.connectionState == .connecting || vpnManager.connectionState == .reasserting)
    }

    private func handleProfileTap(_ profile: SavedProfile) {
        if isProfileActive(profile) || isProfileTransitioning(profile) {
            // Tapping the connected/connecting profile disconnects it
            vpnManager.disconnect()
        } else {
            // Tapping any other profile: disconnect current, then connect new
            profileStore.selectProfile(profile)
            Task {
                if vpnManager.connectionState == .connected || vpnManager.connectionState == .connecting || vpnManager.connectionState == .reasserting {
                    await vpnManager.disconnectAndWait()
                }
                await vpnManager.configure(with: profile.configString, protocolType: profile.vpnProtocol, username: profile.username, password: profile.password)
                vpnManager.connect()
            }
        }
    }

    private func connectToProfile(_ profile: SavedProfile) {
        Task {
            if vpnManager.connectionState == .connected || vpnManager.connectionState == .connecting || vpnManager.connectionState == .reasserting {
                await vpnManager.disconnectAndWait()
            }
            await vpnManager.configure(with: profile.configString, protocolType: profile.vpnProtocol, username: profile.username, password: profile.password)
            vpnManager.connect()
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
}

#Preview {
    ContentView()
}
