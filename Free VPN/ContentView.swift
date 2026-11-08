//
//  ContentView.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/9/26.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Theme

private enum Theme {
    static let accent = Color(red: 0.13, green: 0.69, blue: 0.34)
}

/// tvOS button style that makes the focused control unmistakable: the focused
/// button becomes a white, lifted card with dark content, while unfocused buttons
/// stay subtle. "Active" (e.g. the connected profile) is shown with an accent
/// outline rather than a solid fill so it is never confused with focus.
private struct FocusCardButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        FocusCard(configuration: configuration, isActive: isActive)
    }

    private struct FocusCard: View {
        let configuration: Configuration
        let isActive: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background {
                    shape.fill(isFocused ? Color.white : isActive ? Theme.accent.opacity(0.18) : Color.white.opacity(0.08))
                }
                .overlay {
                    if isActive {
                        shape.strokeBorder(Theme.accent, lineWidth: isFocused ? 4 : 2)
                    }
                }
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 10, y: 6)
                .scaleEffect(configuration.isPressed ? 0.97 : isFocused ? 1.04 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.15), value: isFocused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// tvOS has no switch control (its toggles show "On"/"Off" text), so this draws
/// a label with a trailing switch inside the app's focus card.
private struct SwitchCardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 16) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Color.gray.opacity(0.5))
                    .frame(width: 64, height: 36)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .padding(3)
                    }
                    .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
            }
        }
        .buttonStyle(FocusCardButtonStyle())
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Main View

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vpnManager = VPNManager()
    @State private var profileStore = ProfileStore()
    @State private var profileServer = ProfileServer()
    @State private var renamingProfile: SavedProfile?
    @State private var renameText = ""
    @State private var deletingProfile: SavedProfile?
    @State private var editingCredentialsProfile: SavedProfile?
    @State private var editUsername = ""
    @State private var editPassword = ""
    @State private var showPassword = false
    @State private var showingLogs = false
    @State private var speedTest = SpeedTestManager()
    @FocusState private var focusedProfileID: UUID?
    @Namespace private var focusNamespace
    @State private var profileContentHeight: CGFloat = 0
    @State private var profileScrollHeight: CGFloat = 0
    @State private var showUploadingPopup = false
    @State private var uploadProgress: Double = 0
    @State private var uploadedProfileID: UUID?
    @FocusState private var focusedLogIndex: Int?
    /// Read by the tunnel extensions when they apply routes; stored in the app group.
    @AppStorage("excludeLocalNetworks", store: UserDefaults(suiteName: "group.com.zacvpn.zacvpn"))
    private var excludeLocalNetworks = true

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                // Left: Status + Controls
                VStack(spacing: 0) {
                    // Upper area: status + speed test (scrollable to prevent overlap)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            Group {
                                if vpnManager.connectionState == .connected {
                                    ZStack {
                                        Text("Z")
                                            .font(.system(size: 80, weight: .black, design: .rounded))
                                            .foregroundStyle(Theme.accent)
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(8)
                                            .background(Theme.accent)
                                            .clipShape(Circle())
                                            .offset(x: 34, y: -30)
                                    }
                                } else {
                                    Image(systemName: statusIconName)
                                        .font(.system(size: 80))
                                        .foregroundStyle(statusIconColor)
                                        .symbolEffect(.pulse, isActive: vpnManager.connectionState == .connecting || vpnManager.connectionState == .disconnecting || vpnManager.connectionState == .reasserting)
                                }
                            }
                            .frame(height: 90)

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

                            speedTestCard
                                .padding(.top, 12)

                            localNetworkCard

                        }
                        .padding(.top, 40)
                    }

                    // QR code pinned at bottom — never moves
                    if let url = profileServer.localURL {
                        VStack(spacing: 8) {
                            Text("Upload Profile")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            if let image = generateQRCode(from: url) {
                                // A third of full size while connected, so the status panels fit without scrolling.
                                let qrSize: CGFloat = vpnManager.connectionState == .connected ? 100
                                    : speedTest.state != .idle ? 160 : 300
                                Image(uiImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: qrSize, height: qrSize)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .animation(.easeInOut(duration: 0.3), value: qrSize)
                            }

                            Text(url)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        .padding(.bottom, 20)
                    } else {
                        ProgressView("Starting Profile Upload Server...")
                            .font(.caption2)
                            .padding(.bottom, 20)
                    }
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

                    Text("Click on a profile to connect \u{2022} Long press to manage or see logs")
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
                                            .foregroundStyle(isActive ? Theme.accent : isTransitioning ? .orange : .secondary)
                                            .symbolEffect(.pulse, isActive: isTransitioning)

                                        VStack(alignment: .leading) {
                                            HStack(spacing: 6) {
                                                Text(profile.name)
                                                    .font(.body)
                                                    .foregroundStyle(.primary)
                                                Text(profile.vpnProtocol.shortName)
                                                    .font(.caption2)
                                                    .fontWeight(.semibold)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(protocolBadgeColor(profile.vpnProtocol).opacity(0.2))
                                                    .foregroundStyle(protocolBadgeColor(profile.vpnProtocol))
                                                    .clipShape(Capsule())
                                            }
                                            if isActive {
                                                Text("Click to disconnect")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
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
                                                .foregroundStyle(Theme.accent)
                                        } else if isTransitioning {
                                            ProgressView()
                                        }
                                    }
                                }
                                .buttonStyle(FocusCardButtonStyle(isActive: isActive))
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
                                    Button {
                                        showingLogs = true
                                    } label: {
                                        Label("Show Logs", systemImage: "doc.text.magnifyingglass")
                                    }
                                    Button(role: .destructive) {
                                        deletingProfile = profile
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        // Room for the focused card's scale-up and shadow; the ScrollView clips its bounds.
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
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
            .overlay {
                if showUploadingPopup {
                    ZStack {
                        Color.black.opacity(0.6)
                            .ignoresSafeArea()

                        VStack(spacing: 20) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 50))
                                .foregroundStyle(Theme.accent)
                                .symbolEffect(.pulse)

                            Text("Uploading Profile")
                                .font(.title2)
                                .fontWeight(.semibold)

                            ProgressView(value: uploadProgress)
                                .tint(Theme.accent)
                                .frame(width: 240)

                            Text("\(Int(uploadProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(40)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showUploadingPopup)
            .fullScreenCover(isPresented: $showingLogs) {
                VStack(spacing: 0) {
                    // Fixed banner at top
                    HStack {
                        Text("Press Back (\u{276E}) to return")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Connection Logs")
                            .font(.headline)
                        Spacer()
                        // Balance the layout
                        Text("Press Back (\u{276E}) to return")
                            .font(.caption)
                            .foregroundStyle(.clear)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)

                    // Scrollable log content
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 2) {
                                if vpnManager.connectionLog.isEmpty {
                                    Text("No logs yet. Connect to a VPN profile to see activity.")
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 40)
                                } else {
                                    ForEach(Array(vpnManager.connectionLog.enumerated()), id: \.offset) { index, line in
                                        Text(line)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(line.contains("ERROR") ? .red : line.contains("State:") ? .primary : .secondary)
                                            .focusable()
                                            .focused($focusedLogIndex, equals: index)
                                            .id(index)
                                    }
                                }
                            }
                            .padding(.horizontal, 40)
                            .padding(.vertical, 20)
                        }
                        .onChange(of: vpnManager.connectionLog.count) {
                            if let last = vpnManager.connectionLog.indices.last {
                                focusedLogIndex = last
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if let last = vpnManager.connectionLog.indices.last {
                                    focusedLogIndex = last
                                    proxy.scrollTo(last, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .background(Color.black)
                .ignoresSafeArea(edges: .bottom)
            }
            .onAppear {
                startServer()
                focusLastActiveProfile()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    showingLogs = false
                    startServer()
                    focusLastActiveProfile()
                } else {
                    profileServer.stop()
                }
            }
            .onChange(of: speedTest.state) { _, newState in
                if case .done = newState {
                    focusedProfileID = defaultFocusProfileID
                } else if case .error = newState {
                    focusedProfileID = defaultFocusProfileID
                }
            }
        }
    }

    private func startServer() {
        profileServer.onProfileReceived = { name, config, username, password in
            // Show uploading popup
            uploadProgress = 0
            showUploadingPopup = true

            let startTime = Date()

            // Add the profile
            let error = profileStore.addProfile(name: name, configString: config, username: username, password: password)
            let newProfile: SavedProfile? = (error == nil) ? profileStore.profiles.last : nil

            // Animate progress over 3 seconds, then dismiss and focus
            Task {
                let totalDuration: Double = 3.0
                let steps = 30
                let stepDuration = totalDuration / Double(steps)

                for i in 1...steps {
                    try? await Task.sleep(for: .milliseconds(Int(stepDuration * 1000)))
                    uploadProgress = Double(i) / Double(steps)
                }

                // Ensure at least 3 seconds have elapsed
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < totalDuration {
                    try? await Task.sleep(for: .milliseconds(Int((totalDuration - elapsed) * 1000)))
                }

                showUploadingPopup = false
                uploadProgress = 0

                if let profile = newProfile {
                    profileStore.selectProfile(profile)
                    uploadedProfileID = profile.id
                    focusedProfileID = profile.id
                }
            }
        }
        profileServer.start()
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

    /// The last profile the user connected to (persisted by ProfileStore). Don't gate this on
    /// the VPN state: that loads asynchronously and is still `.invalid` at launch.
    private var defaultFocusProfileID: UUID? {
        if let selectedID = profileStore.selectedProfileID,
           profileStore.profiles.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return profileStore.profiles.first?.id
    }

    /// `prefersDefaultFocus` only applies to the very first focus pass, so also set focus
    /// explicitly after launch and when returning to the foreground.
    private func focusLastActiveProfile() {
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            focusedProfileID = defaultFocusProfileID
        }
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

    // MARK: - Local Network

    /// Lets smart home hubs (Matter, Thread, HomeKit) and other local devices keep
    /// working while the VPN is on. Routes are fixed when the tunnel starts, so a
    /// change reconnects the active profile.
    private var localNetworkCard: some View {
        VStack(spacing: 8) {
            Toggle(isOn: $excludeLocalNetworks) {
                Label("Bypass VPN for Smart Home and Local Network", systemImage: "homekit")
                    .font(.caption)
                    .fontWeight(.semibold)
                    // Stay on one line in the narrow status pane; shrink further if needed.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .toggleStyle(SwitchCardToggleStyle())
            Text(excludeLocalNetworks
                 ? "Home devices stay reachable; internet traffic uses the VPN"
                 : "All traffic, including home devices, goes through the VPN")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.05)))
        .onChange(of: excludeLocalNetworks) {
            guard vpnManager.isActiveOrTransitioning,
                  let profile = profileStore.profiles.first(where: { $0.id == profileStore.selectedProfileID }) else { return }
            speedTest.reset()
            connectToProfile(profile)
        }
    }

    // MARK: - Speed Test

    /// Self-contained speed test panel: a header that says *what* is being measured
    /// (through the VPN or the direct connection), one tile per metric that shows
    /// pending / measuring / done, and a single action button whose label always
    /// describes what pressing it will do.
    private var speedTestCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Label("Speed Test", systemImage: "speedometer")
                    .font(.headline)
                Text(speedTestContextText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if speedTest.state != .idle {
                HStack(spacing: 12) {
                    speedTestTile("Ping", icon: "clock.fill", color: .cyan,
                                  value: speedTest.minLatencyMs, average: speedTest.latencyMs,
                                  unit: "ms", decimals: 0,
                                  isMeasuring: speedTest.state == .testingLatency)
                    speedTestTile("Download", icon: "arrow.down.circle.fill", color: .blue,
                                  value: speedTest.peakDownloadMbps, average: speedTest.downloadMbps,
                                  unit: "Mbps", decimals: 1,
                                  isMeasuring: speedTest.state == .testingDownload)
                    speedTestTile("Upload", icon: "arrow.up.circle.fill", color: .purple,
                                  value: speedTest.peakUploadMbps, average: speedTest.uploadMbps,
                                  unit: "Mbps", decimals: 1,
                                  isMeasuring: speedTest.state == .testingUpload)
                }

                if speedTest.isRunning {
                    ProgressView(value: speedTest.progress)
                        .tint(Theme.accent)
                }

                if case .error(let msg) = speedTest.state {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }

            Button {
                if speedTest.isRunning {
                    speedTest.cancel()
                } else {
                    speedTest.startTest()
                }
            } label: {
                Label(speedTestButtonTitle, systemImage: speedTestButtonIcon)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FocusCardButtonStyle())
        }
        // Inner padding leaves room for the focused button's scale-up so it isn't clipped.
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.05)))
        .animation(.easeInOut(duration: 0.25), value: speedTest.state)
    }

    private func speedTestTile(_ title: String, icon: String, color: Color,
                               value: Double?, average: Double?,
                               unit: String, decimals: Int,
                               isMeasuring: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)

            Group {
                if let value {
                    Text(value, format: .number.precision(.fractionLength(decimals)))
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                } else if isMeasuring {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Text("—")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 44)

            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Reserve the line even when empty so tiles don't jump in height.
            Text(average.map { "avg " + $0.formatted(.number.precision(.fractionLength(decimals))) } ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(isMeasuring ? 0.1 : 0.05)))
        .overlay {
            if isMeasuring {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color, lineWidth: 2)
            }
        }
    }

    private var speedTestContextText: String {
        if speedTest.isRunning { return speedTestPhaseText }
        if vpnManager.connectionState == .connected,
           let profile = profileStore.profiles.first(where: { $0.id == profileStore.selectedProfileID }) {
            return "Through VPN \u{2022} \(profile.name)"
        }
        return "Without VPN \u{2022} direct connection"
    }

    private var speedTestButtonTitle: String {
        switch speedTest.state {
        case .idle: "Run Speed Test"
        case .testingLatency, .testingDownload, .testingUpload: "Stop Test"
        case .done, .error: "Test Again"
        }
    }

    private var speedTestButtonIcon: String {
        switch speedTest.state {
        case .idle: "play.fill"
        case .testingLatency, .testingDownload, .testingUpload: "stop.fill"
        case .done, .error: "arrow.clockwise"
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func protocolBadgeColor(_ proto: VPNProtocolType) -> Color {
        switch proto {
        case .wireGuard: Theme.accent
        case .openVPN: .orange
        case .amneziaWG: .purple
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
        case .testingLatency: "Step 1 of 3 \u{2022} Measuring ping…"
        case .testingDownload: "Step 2 of 3 \u{2022} Testing download…"
        case .testingUpload: "Step 3 of 3 \u{2022} Testing upload…"
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
