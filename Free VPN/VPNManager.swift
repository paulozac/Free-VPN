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
    private(set) var serverAddress: String?
    private(set) var serverCity: String?
    private(set) var serverIP: String?
    var errorMessage: String?

    private let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "VPNManager")
    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private let tunnelBundleIdentifier = "com.zacvpn.zacvpn.PacketTunnel"

    init() {
        Task {
            await loadExistingManager()
            if tunnelManager == nil {
                await loadBundledProfile()
            }
        }
    }

    // MARK: - Public API

    func configure(with configString: String, splitTunnel: Bool = true) async {
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

        // Store endpoint for display
        if let endpoint = config.peers.first?.endpoint {
            serverAddress = endpoint
        }

        await saveTunnelConfiguration(config, splitTunnel: splitTunnel)
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

    func reconfigure(with configString: String, splitTunnel: Bool) async {
        let wasConnected = connectionState == .connected || connectionState == .connecting || connectionState == .reasserting
        if wasConnected {
            disconnect()
            // Wait briefly for disconnect to register
            try? await Task.sleep(for: .milliseconds(500))
        }
        await configure(with: configString, splitTunnel: splitTunnel)
        if wasConnected {
            connect()
        }
    }

    var isConfigured: Bool {
        tunnelManager != nil && connectionState != .invalid
    }

    // MARK: - Tunnel Manager Lifecycle

    private func loadExistingManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            log.info("Found \(managers.count) existing VPN manager(s)")

            for manager in managers {
                if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                    log.info("Existing manager bundle ID: \(proto.providerBundleIdentifier ?? "nil")")

                    if proto.providerBundleIdentifier != tunnelBundleIdentifier {
                        log.info("Removing stale VPN config with old bundle ID")
                        try? await manager.removeFromPreferences()
                        continue
                    }

                    // Restore server address from saved config
                    serverAddress = proto.serverAddress
                }
                tunnelManager = manager
                observeStatus()
                updateConnectionState()
                break
            }
        } catch {
            log.error("Failed to load VPN configuration: \(error.localizedDescription)")
            errorMessage = "Failed to load VPN configuration: \(error.localizedDescription)"
        }
    }

    private func saveTunnelConfiguration(_ config: WireGuardConfig, splitTunnel: Bool) async {
        let manager = tunnelManager ?? NETunnelProviderManager()

        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = tunnelBundleIdentifier
        protocolConfig.serverAddress = config.peers.first?.endpoint ?? "Unknown"

        // Build the config string, modifying AllowedIPs for split tunnel
        var configToSave = config
        if splitTunnel {
            // Exclude local networks from VPN routing
            for i in configToSave.peers.indices {
                let allowedIPs = configToSave.peers[i].allowedIPs
                if allowedIPs.contains("0.0.0.0/0") {
                    configToSave.peers[i].allowedIPs = [
                        "0.0.0.0/1", "128.0.0.0/1"  // Route all except local
                    ]
                    // Keep IPv6 if present
                    if allowedIPs.contains("::/0") {
                        configToSave.peers[i].allowedIPs.append("::/0")
                    }
                }
            }
        }

        protocolConfig.providerConfiguration = [
            "wgQuickConfig": configToSave.toWgQuickConfig()
        ]

        manager.protocolConfiguration = protocolConfig
        manager.localizedDescription = "ZacVPN"
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            log.info("VPN configuration saved to preferences")
            try await manager.loadFromPreferences()
            tunnelManager = manager
            observeStatus()
            updateConnectionState()
            log.info("VPN configured successfully, state: \(self.connectionState.rawValue)")
            errorMessage = nil
        } catch let nsError as NSError {
            log.error("Failed to save VPN config: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            errorMessage = "Failed to save VPN: \(nsError.localizedDescription) (code \(nsError.code))"
        }
    }

    private func loadBundledProfile() async {
        log.info("Loading bundled VPN profile...")

        let url = Bundle.main.url(forResource: "vpntest", withExtension: "conf", subdirectory: "profiles")
            ?? Bundle.main.url(forResource: "vpntest", withExtension: "conf")

        if let url, let contents = try? String(contentsOf: url) {
            log.info("Found bundled profile at: \(url.path)")
            await configure(with: contents)
            return
        }

        log.warning("Bundled profile not found in bundle, using embedded default config")
        await configure(with: Self.defaultConfig)
    }

    private static let defaultConfig = """
[Interface]
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
            serverAddress = nil
            serverCity = nil
        } catch {
            errorMessage = "Failed to remove VPN configuration: \(error.localizedDescription)"
        }
    }

    // MARK: - Server City Lookup

    private func lookupServerLocation() {
        Task.detached {
            // Use HTTPS endpoint (ip-api HTTP is blocked by ATS on tvOS)
            guard let url = URL(string: "https://ipinfo.io/json") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ip = json["ip"] as? String
                    let city = json["city"] as? String
                    let region = json["region"] as? String
                    let country = json["country"] as? String

                    var locationParts: [String] = []
                    if let city, !city.isEmpty { locationParts.append(city) }
                    if let region, !region.isEmpty { locationParts.append(region) }
                    if let country, !country.isEmpty { locationParts.append(country) }

                    await MainActor.run {
                        self.serverIP = ip
                        self.serverCity = locationParts.joined(separator: ", ")
                    }
                }
            } catch {
                // Location lookup is best-effort
            }
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
            serverCity = nil
            serverIP = nil
        case .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = .connected
            connectedDate = tunnelManager?.connection.connectedDate
            lookupServerLocation()
        case .reasserting:
            connectionState = .reasserting
        case .disconnecting:
            connectionState = .disconnecting
        @unknown default:
            connectionState = .disconnected
        }
    }
}
