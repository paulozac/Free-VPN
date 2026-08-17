import NetworkExtension
import os.log
import WireGuardKit
import AmneziaWGKit
import OpenVPNAdapter

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.zacvpn.zacvpn.PacketTunnel", category: "tunnel")
    private lazy var wireGuardAdapter: WireGuardKit.WireGuardAdapter = {
        return WireGuardKit.WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log.log(level: logLevel == .error ? .error : .debug, "\(message, privacy: .public)")
            self?.appendTunnelLog("WG: \(message)")
        }
    }()

    private lazy var amneziaWGAdapter: AmneziaWGKit.WireGuardAdapter = {
        return AmneziaWGKit.WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log.log(level: logLevel == .error ? .error : .debug, "AWG: \(message, privacy: .public)")
            self?.appendTunnelLog("AWG: \(message)")
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
    private var tunnelLog: [String] = []
    private static let sharedDefaults = UserDefaults(suiteName: "group.com.zacvpn.zacvpn")
    private let logQueue = DispatchQueue(label: "com.zacvpn.tunnelLog")
    private let tunnelLogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func appendTunnelLog(_ message: String) {
        logQueue.async { [weak self] in
            guard let self else { return }
            let ts = self.tunnelLogDateFormatter.string(from: Date())
            let entry = "[\(ts)] \(message)"
            self.tunnelLog.append(entry)
            // Keep at most 500 entries
            if self.tunnelLog.count > 500 {
                self.tunnelLog.removeFirst(self.tunnelLog.count - 500)
            }
            // Persist to shared UserDefaults so app can read even after extension terminates
            Self.sharedDefaults?.set(self.tunnelLog, forKey: "tunnelLog")
        }
    }

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        logQueue.sync { tunnelLog.removeAll() }
        appendTunnelLog("Tunnel extension starting")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration else {
            log.error("Missing provider configuration")
            appendTunnelLog("ERROR: Missing provider configuration")
            throw NEVPNError(.configurationInvalid)
        }

        let protocolType = providerConfig["protocolType"] as? String ?? "wireguard"
        activeProtocol = protocolType
        appendTunnelLog("Protocol: \(protocolType)")
        log.info("Starting tunnel with protocol: \(protocolType)")

        switch protocolType {
        case "openVPN":
            try await startOpenVPNTunnel(providerConfig: providerConfig)
        case "amneziaWG":
            appendTunnelLog("AmneziaWG mode (obfuscated WireGuard)")
            try await startAmneziaWGTunnel(providerConfig: providerConfig)
        default:
            try await startWireGuardTunnel(providerConfig: providerConfig)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        appendTunnelLog("Stopping tunnel, reason: \(reason)")
        log.info("Stopping tunnel, reason: \(String(describing: reason))")

        switch activeProtocol {
        case "openVPN":
            openVPNAdapter?.disconnect()
        case "amneziaWG":
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                amneziaWGAdapter.stop { _ in
                    continuation.resume()
                }
            }
        default:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wireGuardAdapter.stop { _ in
                    continuation.resume()
                }
            }
        }
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        // Return collected tunnel logs as JSON
        return logQueue.sync { try? JSONEncoder().encode(tunnelLog) }
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
        appendTunnelLog("WG config received (\(wgQuickConfig.count) chars)")

        let tunnelConfig: WireGuardKit.TunnelConfiguration
        do {
            tunnelConfig = try WireGuardKit.TunnelConfiguration(fromWgQuickConfig: wgQuickConfig, called: "ZacVPN")
        } catch {
            log.error("Failed to parse WireGuard config: \(error.localizedDescription)")
            appendTunnelLog("WG ERROR: Failed to parse config: \(error.localizedDescription)")
            throw NEVPNError(.configurationInvalid)
        }

        // Log parsed config details for debugging
        let iface = tunnelConfig.interface
        appendTunnelLog("WG interface: addresses=\(iface.addresses.map { $0.stringRepresentation })")
        appendTunnelLog("WG interface: dns=\(iface.dns.map { $0.stringRepresentation })")
        appendTunnelLog("WG interface: mtu=\(iface.mtu.map { String($0) } ?? "auto")")
        for (idx, peer) in tunnelConfig.peers.enumerated() {
            appendTunnelLog("WG peer[\(idx)]: endpoint=\(peer.endpoint?.stringRepresentation ?? "none")")
            appendTunnelLog("WG peer[\(idx)]: allowedIPs=\(peer.allowedIPs.map { $0.stringRepresentation })")
            appendTunnelLog("WG peer[\(idx)]: keepalive=\(peer.persistentKeepAlive.map { String($0) } ?? "none")")
        }

        appendTunnelLog("WG starting adapter...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            wireGuardAdapter.start(tunnelConfiguration: tunnelConfig) { [weak self] error in
                if let error = error {
                    self?.appendTunnelLog("WG ERROR: adapter start failed: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    self?.appendTunnelLog("WG adapter started OK")
                    continuation.resume()
                }
            }
        }

        appendTunnelLog("WG tunnel started successfully")
        log.info("WireGuard tunnel started successfully")
    }

    // MARK: - AmneziaWG

    private func startAmneziaWGTunnel(providerConfig: [String: Any]) async throws {
        guard let wgQuickConfig = providerConfig["wgQuickConfig"] as? String else {
            log.error("Missing AmneziaWG configuration")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("AmneziaWG config received (\(wgQuickConfig.count) chars)")
        appendTunnelLog("AmneziaWG config received (\(wgQuickConfig.count) chars)")

        // Log the raw config lines (excluding private key) for debugging
        for line in wgQuickConfig.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("privatekey") {
                appendTunnelLog("AWG raw: PrivateKey = [REDACTED]")
            } else if !trimmed.isEmpty {
                appendTunnelLog("AWG raw: \(trimmed)")
            }
        }

        let tunnelConfig: AmneziaWGKit.TunnelConfiguration
        do {
            tunnelConfig = try AmneziaWGKit.TunnelConfiguration(fromWgQuickConfig: wgQuickConfig, called: "ZacVPN-AWG")
        } catch {
            log.error("Failed to parse AmneziaWG config: \(error.localizedDescription)")
            appendTunnelLog("ERROR: Failed to parse AmneziaWG config: \(error)")
            throw NEVPNError(.configurationInvalid)
        }

        // Log parsed interface details (same detail as WG)
        let iface = tunnelConfig.interface
        appendTunnelLog("AWG interface: addresses=\(iface.addresses.map { $0.stringRepresentation })")
        appendTunnelLog("AWG interface: dns=\(iface.dns.map { $0.stringRepresentation })")
        appendTunnelLog("AWG interface: mtu=\(iface.mtu.map { String($0) } ?? "auto")")

        // Log obfuscation parameters
        let hasAnyAWGParam = iface.junkPacketCount != nil || iface.initPacketMagicHeader != nil
        appendTunnelLog("AWG obfuscation params present: \(hasAnyAWGParam)")
        if let jc = iface.junkPacketCount { appendTunnelLog("AWG Jc=\(jc)") }
        if let jmin = iface.junkPacketMinSize { appendTunnelLog("AWG Jmin=\(jmin)") }
        if let jmax = iface.junkPacketMaxSize { appendTunnelLog("AWG Jmax=\(jmax)") }
        if let s1 = iface.initPacketJunkSize { appendTunnelLog("AWG S1=\(s1)") }
        if let s2 = iface.responsePacketJunkSize { appendTunnelLog("AWG S2=\(s2)") }
        if let s3 = iface.cookiePacketJunkSize { appendTunnelLog("AWG S3=\(s3)") }
        if let s4 = iface.transportPacketJunkSize { appendTunnelLog("AWG S4=\(s4)") }
        if let h1 = iface.initPacketMagicHeader { appendTunnelLog("AWG H1=\(h1)") }
        if let h2 = iface.responsePacketMagicHeader { appendTunnelLog("AWG H2=\(h2)") }
        if let h3 = iface.underloadPacketMagicHeader { appendTunnelLog("AWG H3=\(h3)") }
        if let h4 = iface.transportPacketMagicHeader { appendTunnelLog("AWG H4=\(h4)") }
        if let i1 = iface.initPacketData1 { appendTunnelLog("AWG I1=\(i1)") }
        if let i2 = iface.initPacketData2 { appendTunnelLog("AWG I2=\(i2)") }
        if let i3 = iface.initPacketData3 { appendTunnelLog("AWG I3=\(i3)") }
        if let i4 = iface.initPacketData4 { appendTunnelLog("AWG I4=\(i4)") }
        if let i5 = iface.initPacketData5 { appendTunnelLog("AWG I5=\(i5)") }

        // Log peer details
        for (idx, peer) in tunnelConfig.peers.enumerated() {
            appendTunnelLog("AWG peer[\(idx)]: endpoint=\(peer.endpoint?.stringRepresentation ?? "none")")
            appendTunnelLog("AWG peer[\(idx)]: allowedIPs=\(peer.allowedIPs.map { $0.stringRepresentation })")
            appendTunnelLog("AWG peer[\(idx)]: keepalive=\(peer.persistentKeepAlive.map { String($0) } ?? "none")")
        }

        appendTunnelLog("AWG starting adapter...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            amneziaWGAdapter.start(tunnelConfiguration: tunnelConfig) { [weak self] error in
                if let error = error {
                    self?.appendTunnelLog("AWG ERROR: adapter start failed: \(error)")
                    self?.log.error("AWG adapter start failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else {
                    self?.appendTunnelLog("AWG adapter started OK")
                    continuation.resume()
                }
            }
        }

        appendTunnelLog("AmneziaWG tunnel started successfully")
        log.info("AmneziaWG tunnel started successfully")
    }

    // MARK: - OpenVPN Config Sanitization

    /// Strips or transforms directives unsupported by OpenVPN3/OpenVPNAdapter.
    private static func sanitizeOpenVPNConfig(_ config: String) -> String {
        let unsupportedPrefixes = [
            // Compression (comp-lzo is legacy; OpenVPN3 handles 'compress' natively)
            "comp-lzo",
            // Performance tuning (not applicable on tvOS)
            "fast-io",
            "float",
            "sndbuf",
            "rcvbuf",
            "tun-mtu-extra",
            "tun-mtu",
            "fragment",
            "link-mtu",
            // Routing (redirect-gateway crashes OpenVPN3 tun_builder; handled at NE level)
            "redirect-gateway",
            "redirect-private",
            "route-method",
            "route-delay",
            // Persistence/daemon (desktop-only, no meaning on tvOS)
            "nobind",
            "persist-key",
            "persist-tun",
            // Timers
            "ping-restart",
            "ping-timer-rem",
            // Connection behavior
            "remote-random",
            "reneg-sec",
            "resolv-retry",
            // Windows/Linux-only directives
            "block-outside-dns",
            "register-dns",
            "ip-win32",
            // Scripts (not supported on iOS/tvOS)
            "script-security",
            "up ",
            "down ",
            "route-up",
            "route-pre-down",
            // Environment/plugin (not supported)
            "setenv",
            "plugin",
            // Logging/management (desktop-only)
            "log ",
            "log-append",
            "suppress-timestamps",
            "machine-readable-output",
            "status",
            "management",
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

        // Prevent server-pushed options from crashing OpenVPN3 tun_builder on tvOS.
        // The server pushes redirect-gateway which triggers tun_builder_reroute_gw,
        // and that callback fails on tvOS. route-nopull prevents ALL server pushes.
        // We handle routing (default route) and DNS (fallback) at the NE level instead.
        lines.append("route-nopull")

        return lines.joined(separator: "\n")
    }

    // MARK: - OpenVPN

    private func startOpenVPNTunnel(providerConfig: [String: Any]) async throws {
        guard let ovpnConfig = providerConfig["ovpnConfig"] as? String else {
            log.error("Missing OpenVPN configuration")
            throw NEVPNError(.configurationInvalid)
        }

        appendTunnelLog("OpenVPN config received (\(ovpnConfig.count) chars)")
        log.info("OpenVPN config received (\(ovpnConfig.count) chars)")
        log.info("OpenVPN config preview: \(String(ovpnConfig.prefix(200)), privacy: .public)")

        let sanitizedConfig = Self.sanitizeOpenVPNConfig(ovpnConfig)
        appendTunnelLog("Sanitized config (\(sanitizedConfig.count) chars)")
        log.info("Sanitized OpenVPN config (\(sanitizedConfig.count) chars):")
        // Log sanitized config directives (excluding inline cert blocks) for debugging
        var inCertBlock = false
        for line in sanitizedConfig.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<") && !trimmed.hasPrefix("</") { inCertBlock = true }
            if trimmed.hasPrefix("</") { inCertBlock = false; continue }
            if inCertBlock { continue }
            if !trimmed.isEmpty {
                appendTunnelLog("  directive: \(trimmed)")
                log.info("  \(trimmed, privacy: .public)")
            }
        }

        try await attemptOpenVPNConnection(config: sanitizedConfig)
        appendTunnelLog("OpenVPN tunnel started successfully")
        log.info("OpenVPN tunnel started successfully")
    }

    /// Attempts a single OpenVPN connection with the given config string.
    private func attemptOpenVPNConnection(config: String) async throws {
        let adapter = createOpenVPNAdapter()
        appendTunnelLog("Creating OpenVPN adapter")

        let configuration = OpenVPNConfiguration()
        configuration.fileContent = config.data(using: .utf8)
        configuration.tunPersist = false
        configuration.compressionMode = .default
        configuration.googleDNSFallback = true
        configuration.connectionTimeout = 60
        // Allow 1024-bit RSA certs signed with SHA1 (legacy routers)
        configuration.tlsCertProfile = .legacy
        // Don't enforce a minimum TLS version (legacy routers may only support TLS 1.0)
        configuration.minTLSVersion = .versionDisabled
        configuration.sslDebugLevel = 1
        let lowerConfig = config.lowercased()

        // Disable client certificate if config doesn't include <cert>/<key> blocks
        if !lowerConfig.contains("<cert>") && !lowerConfig.contains("<key>") {
            configuration.disableClientCert = true
        }

        appendTunnelLog("Applying config (tlsCertProfile=legacy, minTLS=disabled, timeout=60s)")
        let evaluation: OpenVPNConfigurationEvaluation
        do {
            evaluation = try adapter.apply(configuration: configuration)
        } catch {
            let nsErr = error as NSError
            appendTunnelLog("ERROR: Failed to apply config: \(error.localizedDescription)")
            appendTunnelLog("ERROR details: domain=\(nsErr.domain) code=\(nsErr.code)")
            for (key, val) in nsErr.userInfo {
                appendTunnelLog("  \(key): \(val)")
            }
            log.error("Failed to apply OpenVPN config: \(error.localizedDescription)")
            log.error("OpenVPN apply error details: \((error as NSError).userInfo)")
            throw NEVPNError(.configurationInvalid)
        }

        appendTunnelLog("Config applied, autologin=\(evaluation.autologin)")
        log.info("OpenVPN config applied. autologin=\(evaluation.autologin)")

        // Provide credentials if needed
        if !evaluation.autologin {
            let proto = protocolConfiguration as? NETunnelProviderProtocol
            let username = proto?.username ?? ""
            let password = Self.loadPasswordFromKeychain(proto?.passwordReference) ?? ""
            appendTunnelLog("Auth required: user=\(!username.isEmpty), pass=\(!password.isEmpty)")
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

        appendTunnelLog("Starting OpenVPN connection...")
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

            // Timeout after 60 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
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
            appendTunnelLog("Configuring tunnel network settings")
            log.info("OpenVPN configuring tunnel network settings:")
            if let ipv4 = settings.ipv4Settings {
                appendTunnelLog("IPv4: \(ipv4.addresses.joined(separator: ", "))")
                appendTunnelLog("Routes: \(ipv4.includedRoutes?.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }.joined(separator: ", ") ?? "none")")
                log.info("  IPv4: addresses=\(ipv4.addresses) masks=\(ipv4.subnetMasks)")
                log.info("  IPv4 includedRoutes: \(ipv4.includedRoutes?.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" } ?? [])")
            }
            if let dns = settings.dnsSettings {
                appendTunnelLog("DNS: \(dns.servers.joined(separator: ", "))")
                log.info("  DNS servers: \(dns.servers)")
                log.info("  DNS search domains: \(dns.searchDomains ?? [])")
            }
            // Set a safe MTU to prevent "No buffer space available" TUN write errors
            if settings.mtu == nil || settings.mtu == 0 {
                settings.mtu = 1400
                appendTunnelLog("MTU: set to 1400 (default)")
            } else {
                appendTunnelLog("MTU: \(settings.mtu!)")
            }
            log.info("  MTU: \(settings.mtu ?? 0)")

            // Ensure a default route exists so all traffic goes through the VPN
            // (redirect-gateway is stripped from config since OpenVPN3 can't handle it on tvOS)
            if let ipv4 = settings.ipv4Settings {
                let hasDefaultRoute = ipv4.includedRoutes?.contains(where: {
                    $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
                }) ?? false
                if !hasDefaultRoute {
                    let defaultRoute = NEIPv4Route.default()
                    defaultRoute.gatewayAddress = ipv4.addresses.first
                    var routes = ipv4.includedRoutes ?? []
                    routes.append(defaultRoute)
                    ipv4.includedRoutes = routes
                    appendTunnelLog("Added default route (0.0.0.0/0) for full tunnel")
                    log.info("Added default route for redirect-gateway support")
                }
            }

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
        appendTunnelLog("Event: \(event.rawValue)\(message.map { " — \($0)" } ?? "")")
        log.info("OpenVPN event: \(event.rawValue), message: \(message ?? "nil", privacy: .public)")
        switch event {
        case .connected:
            appendTunnelLog("Connected!")
            log.info("OpenVPN connected successfully")
            reasserting = false
            openVPNStartCompletion?(nil)
            openVPNStartCompletion = nil
        case .disconnected:
            appendTunnelLog("Disconnected")
            log.info("OpenVPN disconnected")
            openVPNStartCompletion?(NEVPNError(.connectionFailed))
            openVPNStartCompletion = nil
        case .reconnecting:
            appendTunnelLog("Reconnecting...")
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
        appendTunnelLog("ERROR\(isFatal ? " [FATAL]" : ""): \(error.localizedDescription)")
        appendTunnelLog("  reason: \(reason)")
        appendTunnelLog("  message: \(message)")
        appendTunnelLog("  code: \(nsError.code)")
        log.error("OpenVPN error (fatal=\(isFatal)): \(error.localizedDescription, privacy: .public)")
        log.error("OpenVPN error reason: \(reason, privacy: .public)")
        log.error("OpenVPN error message: \(message, privacy: .public)")
        log.error("OpenVPN error code: \(nsError.code)")

        if isFatal {
            appendTunnelLog("Fatal error — failing connection")
            log.error("Fatal OpenVPN error, failing connection")
            openVPNStartCompletion?(error)
            openVPNStartCompletion = nil
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        appendTunnelLog("OVPN: \(logMessage)")
        log.debug("OpenVPN: \(logMessage, privacy: .public)")
    }
}
