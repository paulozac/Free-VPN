import NetworkExtension
import os.log
import WireGuardKit
import OpenVPNAdapter

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.zacvpn.zacvpn.PacketTunnel", category: "tunnel")
    private lazy var wireGuardAdapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log.log(level: logLevel == .error ? .error : .debug, "\(message, privacy: .public)")
        }
    }()

    private var openVPNAdapter: OpenVPNAdapter?

    private func createOpenVPNAdapter() -> OpenVPNAdapter {
        let adapter = OpenVPNAdapter()
        adapter.delegate = self
        openVPNAdapter = adapter
        return adapter
    }

    private var activeProtocol: String = "wireguard"
    private var openVPNStartCompletion: ((Error?) -> Void)?

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration else {
            log.error("Missing provider configuration")
            throw NEVPNError(.configurationInvalid)
        }

        let protocolType = providerConfig["protocolType"] as? String ?? "wireguard"
        activeProtocol = protocolType
        log.info("Starting tunnel with protocol: \(protocolType)")

        switch protocolType {
        case "openVPN":
            try await startOpenVPNTunnel(providerConfig: providerConfig)
        default:
            try await startWireGuardTunnel(providerConfig: providerConfig)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.info("Stopping tunnel, reason: \(String(describing: reason))")

        switch activeProtocol {
        case "openVPN":
            openVPNAdapter?.disconnect()
        default:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wireGuardAdapter.stop { _ in
                    continuation.resume()
                }
            }
        }
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        return nil
    }

    /// Resolves a persistent Keychain reference to retrieve the stored password.
    private static func loadPasswordFromKeychain(_ persistentRef: Data?) -> String? {
        let log = Logger(subsystem: "com.zacvpn.zacvpn.PacketTunnel", category: "Keychain")
        guard let persistentRef else {
            log.warning("No passwordReference provided")
            return nil
        }

        log.info("Resolving passwordReference (\(persistentRef.count) bytes)")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: persistentRef,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            log.error("Failed to resolve passwordReference from Keychain: \(status)")
            return nil
        }
        log.info("Password resolved from Keychain (\(data.count) bytes)")
        return String(data: data, encoding: .utf8)
    }

    // MARK: - WireGuard

    private func startWireGuardTunnel(providerConfig: [String: Any]) async throws {
        guard let wgQuickConfig = providerConfig["wgQuickConfig"] as? String else {
            log.error("Missing WireGuard configuration")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("WireGuard config received (\(wgQuickConfig.count) chars)")

        let tunnelConfig: TunnelConfiguration
        do {
            tunnelConfig = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig, called: "ZacVPN")
        } catch {
            log.error("Failed to parse WireGuard config: \(error.localizedDescription)")
            throw NEVPNError(.configurationInvalid)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            wireGuardAdapter.start(tunnelConfiguration: tunnelConfig) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        log.info("WireGuard tunnel started successfully")
    }

    // MARK: - OpenVPN Config Sanitization

    /// Strips or transforms directives unsupported by OpenVPN3/OpenVPNAdapter.
    private static func sanitizeOpenVPNConfig(_ config: String) -> String {
        let unsupportedPrefixes = [
            "comp-lzo",
            "fast-io",
            "tun-mtu-extra",
            "tun-mtu",
            "mssfix",
            "nobind",
            "ping-restart",
            "ping-timer-rem",
            "remote-random",
            "reneg-sec",
            "resolv-retry",
            "verify-x509-name",
        ]

        var lines = config.components(separatedBy: "\n")
        var inBlock = false

        lines = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Keep empty lines and comments
            if trimmed.isEmpty || lower.hasPrefix("#") || lower.hasPrefix(";") {
                return line
            }

            // Don't filter inside inline blocks (<ca>, <tls-crypt>, etc.)
            if lower.hasPrefix("<") && !lower.hasPrefix("</") {
                inBlock = true
                return line
            }
            if lower.hasPrefix("</") {
                inBlock = false
                return line
            }
            if inBlock { return line }

            if unsupportedPrefixes.contains(where: { lower.hasPrefix($0) }) {
                return nil
            }

            return line
        }

        return lines.joined(separator: "\n")
    }

    private static func extractTransportProtocol(from config: String) -> OpenVPNTransportProtocol? {
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            if lower.hasPrefix("proto ") {
                let components = lower.split(separator: " ", maxSplits: 1)
                guard components.count == 2 else { continue }
                let proto = components[1].trimmingCharacters(in: .whitespaces)
                switch proto {
                case "udp": return .UDP
                case "tcp", "tcp-client", "tcp-server": return .TCP
                case "adaptive": return .adaptive
                default: return nil
                }
            }

            if lower.hasPrefix("remote ") {
                let components = lower.split(separator: " ")
                if components.count >= 4 {
                    let protoToken = components[3].trimmingCharacters(in: .whitespaces)
                    switch protoToken {
                    case "udp", "udp4", "udp6": return .UDP
                    case "tcp", "tcp-client", "tcp-server": return .TCP
                    case "adaptive": return .adaptive
                    default: break
                    }
                }
            }
        }
        return nil
    }

    /// Flips the transport protocol between UDP and TCP in an OpenVPN config.
    /// Returns nil if no proto directive was found or it couldn't be flipped.
    private static func flipProtocol(in config: String) -> String? {
        var lines = config.components(separatedBy: "\n")
        var flipped = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("proto ") {
                if trimmed.contains("tcp") {
                    lines[index] = "proto udp"
                    flipped = true
                } else if trimmed.contains("udp") {
                    lines[index] = "proto tcp"
                    flipped = true
                }
                break
            }
        }
        return flipped ? lines.joined(separator: "\n") : nil
    }

    // MARK: - OpenVPN

    private func startOpenVPNTunnel(providerConfig: [String: Any]) async throws {
        guard let ovpnConfig = providerConfig["ovpnConfig"] as? String else {
            log.error("Missing OpenVPN configuration")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("OpenVPN config received (\(ovpnConfig.count) chars)")
        log.info("OpenVPN config preview: \(String(ovpnConfig.prefix(200)), privacy: .public)")

        let sanitizedConfig = Self.sanitizeOpenVPNConfig(ovpnConfig)
        log.info("Sanitized OpenVPN config (\(sanitizedConfig.count) chars):")
        // Log sanitized config (excluding inline cert blocks) for debugging
        for line in sanitizedConfig.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("MI") {
                log.info("  \(trimmed, privacy: .public)")
            }
        }

        do {
            try await attemptOpenVPNConnection(config: sanitizedConfig)
            log.info("OpenVPN tunnel started successfully")
        } catch let error as NEVPNError where error.code == .configurationInvalid {
            // Configuration error — don't retry, just propagate
            throw error
        } catch {
            // Connection failure — try flipping the protocol (UDP ↔ TCP)
            log.warning("OpenVPN connection failed: \(error.localizedDescription)")
            openVPNAdapter?.disconnect()
            if let flippedConfig = Self.flipProtocol(in: sanitizedConfig) {
                log.info("Retrying OpenVPN with flipped protocol (UDP ↔ TCP)...")
                try await attemptOpenVPNConnection(config: flippedConfig)
                log.info("OpenVPN tunnel started with flipped protocol")
            } else {
                throw error
            }
        }
    }

    /// Attempts a single OpenVPN connection with the given config string.
    private func attemptOpenVPNConnection(config: String) async throws {
        let adapter = createOpenVPNAdapter()

        let configuration = OpenVPNConfiguration()
        if let transportProtocol = Self.extractTransportProtocol(from: config) {
            configuration.proto = transportProtocol
            let protoName: String
            switch transportProtocol {
            case .UDP: protoName = "udp"
            case .TCP: protoName = "tcp"
            case .adaptive: protoName = "adaptive"
            default: protoName = "default"
            }
            log.info("OpenVPN transport protocol override: \(protoName, privacy: .public)")
        }
        configuration.fileContent = config.data(using: .utf8)
        configuration.tunPersist = false
        configuration.compressionMode = .disabled
        configuration.googleDNSFallback = true
        configuration.connectionTimeout = 30
        let lowerConfig = config.lowercased()

        // Force AES-CBC ciphersuite only when config explicitly uses CBC cipher
        if lowerConfig.contains("cipher") && lowerConfig.contains("-cbc") {
            configuration.forceCiphersuitesAESCBC = true
        }

        // Disable client certificate if config doesn't include <cert>/<key> blocks
        if !lowerConfig.contains("<cert>") && !lowerConfig.contains("<key>") {
            configuration.disableClientCert = true
        }

        let evaluation: OpenVPNConfigurationEvaluation
        do {
            evaluation = try adapter.apply(configuration: configuration)
        } catch {
            log.error("Failed to apply OpenVPN config: \(error.localizedDescription)")
            log.error("OpenVPN apply error details: \((error as NSError).userInfo)")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("OpenVPN config applied. autologin=\(evaluation.autologin)")

        // Provide credentials if needed
        if !evaluation.autologin {
            let proto = protocolConfiguration as? NETunnelProviderProtocol
            let username = proto?.username ?? ""
            let password = Self.loadPasswordFromKeychain(proto?.passwordReference) ?? ""
            log.info("OpenVPN requires auth. username provided: \(!username.isEmpty), password provided: \(!password.isEmpty)")
            if !username.isEmpty {
                let credentials = OpenVPNCredentials()
                credentials.username = username
                credentials.password = password
                do {
                    try adapter.provide(credentials: credentials)
                } catch {
                    log.error("Failed to provide credentials: \(error.localizedDescription)")
                    throw NEVPNError(.configurationInvalid)
                }
            } else {
                log.warning("OpenVPN requires auth but no credentials provided — connection may fail")
            }
        }

        log.info("Starting OpenVPN connection...")

        // Connect using async/await bridge with timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var hasResumed = false

            self.openVPNStartCompletion = { error in
                guard !hasResumed else { return }
                hasResumed = true
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            adapter.connect(using: self.packetFlow)

            // Timeout after 30 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(throwing: NEVPNError(.connectionFailed))
            }
        }
    }
}

// MARK: - NEPacketTunnelFlow + OpenVPNAdapterPacketFlow

extension NEPacketTunnelFlow: @retroactive OpenVPNAdapterPacketFlow {}

// MARK: - OpenVPNAdapterDelegate

extension PacketTunnelProvider: OpenVPNAdapterDelegate {

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, configureTunnelWithNetworkSettings networkSettings: NEPacketTunnelNetworkSettings?, completionHandler: @escaping ((any Error)?) -> Void) {
        if let settings = networkSettings {
            log.info("OpenVPN configuring tunnel network settings:")
            if let ipv4 = settings.ipv4Settings {
                log.info("  IPv4: addresses=\(ipv4.addresses) masks=\(ipv4.subnetMasks)")
                log.info("  IPv4 includedRoutes: \(ipv4.includedRoutes?.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" } ?? [])")
            }
            if let dns = settings.dnsSettings {
                log.info("  DNS servers: \(dns.servers)")
                log.info("  DNS search domains: \(dns.searchDomains ?? [])")
            }
            log.info("  MTU: \(settings.mtu ?? 0)")

            // Ensure DNS is configured — if OpenVPN server didn't push DNS, add fallback
            if settings.dnsSettings == nil || settings.dnsSettings?.servers.isEmpty == true {
                log.warning("OpenVPN did not provide DNS servers, adding fallback DNS")
                let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
                settings.dnsSettings = dns
            }
        } else {
            log.warning("OpenVPN provided nil network settings")
        }

        setTunnelNetworkSettings(networkSettings) { [weak self] error in
            if let error {
                self?.log.error("Failed to set tunnel network settings: \(error.localizedDescription)")
            } else {
                self?.log.info("Tunnel network settings applied successfully")
            }
            completionHandler(error)
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleEvent event: OpenVPNAdapterEvent, message: String?) {
        log.info("OpenVPN event: \(event.rawValue), message: \(message ?? "nil", privacy: .public)")
        switch event {
        case .connected:
            log.info("OpenVPN connected successfully")
            reasserting = false
            openVPNStartCompletion?(nil)
            openVPNStartCompletion = nil
        case .disconnected:
            log.info("OpenVPN disconnected")
            openVPNStartCompletion?(NEVPNError(.connectionFailed))
            openVPNStartCompletion = nil
        case .reconnecting:
            log.info("OpenVPN reconnecting")
            reasserting = true
        default:
            break
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: any Error) {
        let nsError = error as NSError
        let isFatal = nsError.userInfo[OpenVPNAdapterErrorFatalKey] as? Bool ?? false
        let message = nsError.userInfo[OpenVPNAdapterErrorMessageKey] as? String ?? "none"
        let reason = nsError.localizedFailureReason ?? "none"
        log.error("OpenVPN error (fatal=\(isFatal)): \(error.localizedDescription, privacy: .public)")
        log.error("OpenVPN error reason: \(reason, privacy: .public)")
        log.error("OpenVPN error message: \(message, privacy: .public)")
        log.error("OpenVPN error code: \(nsError.code)")

        if isFatal {
            log.error("Fatal OpenVPN error, failing connection")
            openVPNStartCompletion?(error)
            openVPNStartCompletion = nil
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        log.debug("OpenVPN: \(logMessage, privacy: .public)")
    }
}
