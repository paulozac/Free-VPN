//
//  VPNManager.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/9/26.
//

import Foundation
import NetworkExtension
import os.log

@MainActor
@Observable
final class VPNManager {

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting..."
        case connected = "Connected"
        case disconnecting = "Disconnecting..."
        case reasserting = "Reconnecting..."
        case invalid = "Not Configured"
    }

    private(set) var connectionState: ConnectionState = .invalid
    private(set) var connectedDate: Date?
    var errorMessage: String?

    private let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "VPNManager")
    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    /// The bundle identifier of the Packet Tunnel Provider extension.
    /// Update this to match your Network Extension target's bundle ID.
    private let tunnelBundleIdentifier = "com.zacvpn.zacvpn.PacketTunnel"

    init() {
        Task {
            await loadExistingManager()
            // If no existing config, load the bundled default profile
            if tunnelManager == nil {
                await loadBundledProfile()
            }
        }
    }

    // MARK: - Public API

    func configure(with configString: String) async {
        errorMessage = nil
        log.info("Configuring VPN with config (\(configString.count) chars)")

        let config: WireGuardConfig
        do {
            config = try WireGuardConfig.parse(from: configString)
            log.info("Parsed config: interface address=\(config.interface.address), peers=\(config.peers.count)")
        } catch {
            log.error("Failed to parse config: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return
        }

        await saveTunnelConfiguration(config)
    }

    func connect() {
        guard let tunnelManager else {
            errorMessage = "VPN not configured. Add a profile first."
            return
        }

        do {
            try tunnelManager.connection.startVPNTunnel()
        } catch {
            errorMessage = "Failed to start VPN: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        tunnelManager?.connection.stopVPNTunnel()
    }

    func toggleConnection() {
        switch connectionState {
        case .invalid:
            // Profile not loaded yet, load it then connect
            Task {
                await loadBundledProfile()
                connect()
            }
        case .disconnected:
            connect()
        case .connected, .connecting, .reasserting:
            disconnect()
        case .disconnecting:
            break
        }
    }

    var isConfigured: Bool {
        tunnelManager != nil && connectionState != .invalid
    }

    // MARK: - Tunnel Manager Lifecycle

    private func loadExistingManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first {
                tunnelManager = existing
                observeStatus()
                updateConnectionState()
            }
        } catch {
            errorMessage = "Failed to load VPN configuration: \(error.localizedDescription)"
        }
    }

    private func saveTunnelConfiguration(_ config: WireGuardConfig) async {
        let manager = tunnelManager ?? NETunnelProviderManager()

        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = tunnelBundleIdentifier
        protocolConfig.serverAddress = config.peers.first?.endpoint ?? "Unknown"

        // Store the full WireGuard config in providerConfiguration so the
        // Packet Tunnel Provider can read it at connection time.
        protocolConfig.providerConfiguration = [
            "wgQuickConfig": config.toWgQuickConfig()
        ]

        manager.protocolConfiguration = protocolConfig
        manager.localizedDescription = "ZacVPN"
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            log.info("VPN configuration saved to preferences")
            // Reload after save to pick up system-assigned properties
            try await manager.loadFromPreferences()
            tunnelManager = manager
            observeStatus()
            updateConnectionState()
            log.info("VPN configured successfully, state: \(self.connectionState.rawValue)")
            errorMessage = nil
        } catch {
            log.error("Failed to save VPN config: \(error.localizedDescription)")
            errorMessage = "Failed to save VPN configuration: \(error.localizedDescription)"
        }
    }

    /// Loads the bundled vpntest.conf from the app bundle as the default profile.
    private func loadBundledProfile() async {
        log.info("Loading bundled VPN profile...")

        // Try multiple locations since bundle layout may vary
        let url = Bundle.main.url(forResource: "vpntest", withExtension: "conf", subdirectory: "profiles")
            ?? Bundle.main.url(forResource: "vpntest", withExtension: "conf")

        if let url, let contents = try? String(contentsOf: url) {
            log.info("Found bundled profile at: \(url.path)")
            await configure(with: contents)
            return
        }

        log.warning("Bundled profile not found in bundle, using embedded default config")
        // Fallback: use the embedded default config directly
        await configure(with: Self.defaultConfig)
    }

    // No leading whitespace — must be flush left for the WireGuard parser
    private static let defaultConfig = """
[Interface]r
Address = 10.0.0.7/24
PrivateKey = kIdmDoBYI3QZqOHCrtn8Y9si1zSxxN2MJy4KAgaWSHA=
DNS = 64.6.64.6,10.0.0.1
MTU = 1420

[Peer]
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = njd4995.glddns.com:17654
PersistentKeepalive = 25
PublicKey = wwBMNHjRkr6MUhrTIo/Fha2MMiruofEyZ2Yysfbt9Ho=
"""

    func removeConfiguration() async {
        guard let manager = tunnelManager else { return }
        do {
            try await manager.removeFromPreferences()
            tunnelManager = nil
            connectionState = .invalid
            connectedDate = nil
        } catch {
            errorMessage = "Failed to remove VPN configuration: \(error.localizedDescription)"
        }
    }

    // MARK: - Status Observation

    private func observeStatus() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        guard let connection = tunnelManager?.connection else { return }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateConnectionState()
            }
        }
    }

    private func updateConnectionState() {
        guard let status = tunnelManager?.connection.status else {
            connectionState = .invalid
            connectedDate = nil
            return
        }

        switch status {
        case .invalid:
            connectionState = .invalid
        case .disconnected:
            connectionState = .disconnected
            connectedDate = nil
        case .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = .connected
            connectedDate = tunnelManager?.connection.connectedDate
        case .reasserting:
            connectionState = .reasserting
        case .disconnecting:
            connectionState = .disconnecting
        @unknown default:
            connectionState = .disconnected
        }
    }
}
