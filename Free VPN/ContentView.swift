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

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
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
    @State private var speedTest = SpeedTestManager()
    @FocusState private var focusedProfileID: UUID?
    @Namespace private var focusNamespace
    @State private var profileContentHeight: CGFloat = 0
    @State private var profileScrollHeight: CGFloat = 0

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

                    // Speed Test Results
                    if speedTest.state != .idle {
                        VStack(spacing: 6) {
                            if speedTest.isRunning {
                                ProgressView(value: speedTest.progress)
                                    .tint(Theme.accent)
                                Text(speedTestPhaseText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if let ip = speedTest.testServerIP {
                                HStack {
                                    Image(systemName: "globe")
                                        .foregroundStyle(.green)
                                    Text("Test Server")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if let hostname = speedTest.testServerHostname {
                                            Text(hostname)
                                                .fontWeight(.semibold)
                                        }
                                        Text(ip)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .font(.caption)
                            }
                            speedTestRow("Latency", icon: "clock.fill", color: .cyan,
                                         primary: speedTest.minLatencyMs, average: speedTest.latencyMs,
                                         unit: "ms", decimals: 0)
                            speedTestRow("Download", icon: "arrow.down.circle.fill", color: .blue,
                                         primary: speedTest.peakDownloadMbps, average: speedTest.downloadMbps,
                                         unit: "Mbps", decimals: 1)
                            speedTestRow("Upload", icon: "arrow.up.circle.fill", color: .purple,
                                         primary: speedTest.peakUploadMbps, average: speedTest.uploadMbps,
                                         unit: "Mbps", decimals: 1)
                            if case .error(let msg) = speedTest.state {
                                Text(msg)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 8)
                    }

                    if !vpnManager.connectionLog.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Logs")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(vpnManager.connectionLog, id: \.self) { line in
                                        Text(line)
                                            .font(.caption2)
                                            .fontDesign(.monospaced)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                            .padding(10)
                            .background(Color(red: 0.96, green: 0.97, blue: 1.0))
                            .cornerRadius(12)
                        }
                    }

                    Spacer().frame(height: 8)

                    Button {
                        if speedTest.isRunning {
                            speedTest.cancel()
                        } else {
                            speedTest.startTest()
                        }
                    } label: {
                        Label(speedTest.isRunning ? "Cancel" : "Speed Test", systemImage: speedTest.isRunning ? "xmark.circle" : "speedometer")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                    Text("Powered by Cloudflare \u{2601}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

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
                        VStack(spacing: 8) {
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
                                                    .foregroundStyle(.secondary)
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
                                    .background {
                                        if isActive {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Theme.accent)
                                        }
                                    }
                                }
                                .disabled(vpnManager.connectionState == .disconnecting)
                                .focused($focusedProfileID, equals: profile.id)
                                .prefersDefaultFocus(profile.id == defaultFocusProfileID, in: focusNamespace)
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
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: ScrollContentHeightKey.self, value: proxy.size.height)
                            }
                        )
                    }
                    .onPreferenceChange(ScrollContentHeightKey.self) { profileContentHeight = $0 }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onAppear { profileScrollHeight = proxy.size.height }
                        }
                    )

                    if showMoreIndicator {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                            Text("\(profileStore.profiles.count) profiles")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                    }
                }
                .focusSection()
                .prefersDefaultFocus(in: focusNamespace)
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

    private var showMoreIndicator: Bool {
        guard profileContentHeight > profileScrollHeight + 1 else { return false }
        if let focusedID = focusedProfileID,
           let index = profileStore.profiles.firstIndex(where: { $0.id == focusedID }),
           index >= profileStore.profiles.count - 2 {
            return false
        }
        return true
    }

    private var defaultFocusProfileID: UUID? {
        if vpnManager.isActiveOrTransitioning, let selectedID = profileStore.selectedProfileID {
            return selectedID
        }
        return profileStore.profiles.first?.id
    }

    private func isProfileActive(_ profile: SavedProfile) -> Bool {
        profile.id == profileStore.selectedProfileID && vpnManager.connectionState == .connected
    }

    private func isProfileTransitioning(_ profile: SavedProfile) -> Bool {
        profile.id == profileStore.selectedProfileID && (vpnManager.connectionState == .connecting || vpnManager.connectionState == .reasserting)
    }

    private func handleProfileTap(_ profile: SavedProfile) {
        if isProfileActive(profile) || isProfileTransitioning(profile) {
            vpnManager.disconnect()
            speedTest.reset()
        } else {
            profileStore.selectProfile(profile)
            speedTest.reset()
            connectToProfile(profile)
        }
    }

    private func connectToProfile(_ profile: SavedProfile) {
        Task {
            if vpnManager.isActiveOrTransitioning {
                await vpnManager.disconnectAndWait()
            }
            await vpnManager.configure(with: profile.configString, protocolType: profile.vpnProtocol, username: profile.username, password: profile.password)
            vpnManager.connect()
        }
    }

    @ViewBuilder
    private func speedTestRow(_ label: String, icon: String, color: Color,
                              primary: Double?, average: Double?,
                              unit: String, decimals: Int) -> some View {
        if let value = primary {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.\(decimals)f \(unit)", value))
                        .fontWeight(.semibold)
                    if let avg = average {
                        Text(String(format: "Avg: %.\(decimals)f \(unit)", avg))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.caption)
        }
    }

    private var statusIconName: String {
        switch vpnManager.connectionState {
        case .connected: "lock.shield.fill"
        case .connecting, .reasserting, .disconnecting: "shield.fill"
        case .disconnected, .invalid: "shield.slash.fill"
        }
    }

    private var speedTestPhaseText: String {
        switch speedTest.state {
        case .testingLatency: "Measuring latency..."
        case .testingDownload: "Testing download speed..."
        case .testingUpload: "Testing upload speed..."
        default: ""
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
