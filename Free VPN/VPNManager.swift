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
    private(set) var bytesIn: UInt64 = 0
    private(set) var bytesOut: UInt64 = 0
    var errorMessage: String?

    private let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "VPNManager")
    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var statsTask: Task<Void, Never>?

    private let tunnelBundleIdentifier = "com.zacvpn.zacvpn.PacketTunnel"

    init() {
        Task {
            await loadExistingManager()
        }
    }

    // MARK: - Public API

    func configure(with configString: String, protocolType: VPNProtocolType = .wireGuard, username: String? = nil, password: String? = nil) async {
        errorMessage = nil
        log.info("Configuring VPN (\(protocolType.displayName)) with config (\(configString.count) chars)")

        switch protocolType {
        case .wireGuard:
            await configureWireGuard(configString: configString)
        case .openVPN:
            await configureOpenVPN(configString: configString, username: username, password: password)
        }
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

    /// Disconnects and waits until the tunnel is fully disconnected before returning.
    func disconnectAndWait() async {
        guard isActiveOrTransitioning else { return }
        disconnect()
        // Wait for disconnected state (up to 5 seconds)
        for _ in 0..<50 {
            if connectionState == .disconnected || connectionState == .invalid {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    func toggleConnection() {
        switch connectionState {
        case .invalid:
            errorMessage = "VPN not configured. Upload a profile first."
        case .disconnected:
            connect()
        case .connected, .connecting, .reasserting:
            disconnect()
        case .disconnecting:
            break
        }
    }

    func reconfigure(with configString: String, protocolType: VPNProtocolType = .wireGuard, username: String? = nil, password: String? = nil) async {
        let wasConnected = isActiveOrTransitioning
        if wasConnected {
            disconnect()
        }
        await configure(with: configString, protocolType: protocolType, username: username, password: password)
        if wasConnected {
            connect()
        }
    }

    var isConfigured: Bool {
        tunnelManager != nil && connectionState != .invalid
    }

    var isActiveOrTransitioning: Bool {
        connectionState == .connected || connectionState == .connecting || connectionState == .reasserting
    }

    // MARK: - WireGuard Configuration

    private func configureWireGuard(configString: String) async {
        let config: WireGuardConfig
        do {
            config = try WireGuardConfig.parse(from: configString)
            log.info("Parsed WireGuard config: interface address=\(config.interface.address), peers=\(config.peers.count)")
        } catch {
            log.error("Failed to parse WireGuard config: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return
        }

        if let endpoint = config.peers.first?.endpoint {
            serverAddress = endpoint
        }

        let providerConfig: [String: Any] = [
            "protocolType": VPNProtocolType.wireGuard.rawValue,
            "wgQuickConfig": config.toWgQuickConfig()
        ]

        await saveTunnelConfiguration(
            serverAddress: config.peers.first?.endpoint ?? "Unknown",
            providerConfig: providerConfig
        )
    }

    // MARK: - OpenVPN Configuration

    private func configureOpenVPN(configString: String, username: String? = nil, password: String? = nil) async {
        let endpoint = OpenVPNConfig.extractEndpoint(from: configString)
        serverAddress = endpoint

        let providerConfig: [String: Any] = [
            "protocolType": VPNProtocolType.openVPN.rawValue,
            "ovpnConfig": configString
        ]

        await saveTunnelConfiguration(
            serverAddress: endpoint ?? "Unknown",
            providerConfig: providerConfig,
            username: username,
            password: password
        )
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

    private func saveTunnelConfiguration(serverAddress: String, providerConfig: [String: Any], username: String? = nil, password: String? = nil) async {
        let manager = tunnelManager ?? NETunnelProviderManager()

        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = tunnelBundleIdentifier
        protocolConfig.serverAddress = serverAddress
        protocolConfig.providerConfiguration = providerConfig

        // Store credentials using Apple's standard NEVPNProtocol properties
        if let username, !username.isEmpty {
            protocolConfig.username = username
            log.info("Set NEVPNProtocol.username: \(!username.isEmpty)")
        }
        if let password, !password.isEmpty {
            let ref = Self.savePasswordToKeychain(password)
            protocolConfig.passwordReference = ref
            log.info("Set NEVPNProtocol.passwordReference: \(ref != nil ? "set (\(ref!.count) bytes)" : "FAILED")")
        }

        manager.protocolConfiguration = protocolConfig
        manager.localizedDescription = "Zac VPN Connect"
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

    // MARK: - Keychain

    private nonisolated static let keychainService = "com.zacvpn.zacvpn.vpnpassword"
    private nonisolated static let keychainAccount = "vpn-credentials"
    private nonisolated static let keychainAccessGroup = "group.com.zacvpn.zacvpn"

    /// Saves the password to the Keychain and returns a persistent reference for NEVPNProtocol.passwordReference.
    private nonisolated static func savePasswordToKeychain(_ password: String) -> Data? {
        let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "Keychain")
        guard let passwordData = password.data(using: .utf8) else { return nil }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: keychainAccessGroup
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item and request persistent reference
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecValueData as String: passwordData,
            kSecReturnPersistentRef as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var result: AnyObject?
        let status = SecItemAdd(addQuery as CFDictionary, &result)
        guard status == errSecSuccess, let persistentRef = result as? Data else {
            log.error("Failed to save password to Keychain: \(status)")
            return nil
        }
        log.info("Password saved to Keychain, persistentRef size: \(persistentRef.count) bytes")
        return persistentRef
    }


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
        Task {
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

                    self.serverIP = ip
                    self.serverCity = locationParts.joined(separator: ", ")
                }
            } catch {
                // Location lookup is best-effort
            }
        }
    }

    // MARK: - Traffic Stats

    private var baselineIn: UInt64 = 0
    private var baselineOut: UInt64 = 0

    private func startStatsPolling() {
        stopStatsPolling()
        let baseline = Self.readTunnelInterfaceStats()
        baselineIn = baseline.bytesIn
        baselineOut = baseline.bytesOut
        bytesIn = 0
        bytesOut = 0
        statsTask = Task {
            while !Task.isCancelled {
                let stats = Self.readTunnelInterfaceStats()
                bytesIn = stats.bytesIn >= baselineIn ? stats.bytesIn - baselineIn : stats.bytesIn
                bytesOut = stats.bytesOut >= baselineOut ? stats.bytesOut - baselineOut : stats.bytesOut
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopStatsPolling() {
        statsTask?.cancel()
        statsTask = nil
    }

    /// Reads byte counters from utun interfaces via getifaddrs.
    private nonisolated static func readTunnelInterfaceStats() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return (0, 0)
        }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = cursor {
            let name = String(cString: addr.pointee.ifa_name)
            if name.hasPrefix("utun"), addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                if let data = addr.pointee.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                    totalIn += UInt64(networkData.ifi_ibytes)
                    totalOut += UInt64(networkData.ifi_obytes)
                }
            }
            cursor = addr.pointee.ifa_next
        }

        return (totalIn, totalOut)
    }

    /// Formats bytes into a human-readable string (KB, MB, GB).
    static func formattedBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1_024
        let mb = kb / 1_024
        let gb = mb / 1_024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", max(kb, 0))
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
            guard let self else { return }
            Task { @MainActor [weak self] in
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
            bytesIn = 0
            bytesOut = 0
            stopStatsPolling()
        case .connecting:
            connectionState = .connecting
        case .connected:
            connectionState = .connected
            connectedDate = tunnelManager?.connection.connectedDate
            lookupServerLocation()
            startStatsPolling()
        case .reasserting:
            connectionState = .reasserting
            bytesIn = 0
            bytesOut = 0
            stopStatsPolling()
        case .disconnecting:
            connectionState = .disconnecting
        @unknown default:
            connectionState = .disconnected
        }
    }
}
