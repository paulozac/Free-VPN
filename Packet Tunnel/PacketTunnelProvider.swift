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

    private lazy var openVPNAdapter: OpenVPNAdapter = {
        let adapter = OpenVPNAdapter()
        adapter.delegate = self
        return adapter
    }()

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
            openVPNAdapter.disconnect()
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

    // MARK: - OpenVPN

    private func startOpenVPNTunnel(providerConfig: [String: Any]) async throws {
        guard let ovpnConfig = providerConfig["ovpnConfig"] as? String else {
            log.error("Missing OpenVPN configuration")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("OpenVPN config received (\(ovpnConfig.count) chars)")
        log.info("OpenVPN config preview: \(String(ovpnConfig.prefix(200)), privacy: .public)")

        let configuration = OpenVPNConfiguration()
        configuration.fileContent = ovpnConfig.data(using: .utf8)
        configuration.tunPersist = true

        let evaluation: OpenVPNConfigurationEvaluation
        do {
            evaluation = try openVPNAdapter.apply(configuration: configuration)
        } catch {
            log.error("Failed to apply OpenVPN config: \(error.localizedDescription)")
            log.error("OpenVPN apply error details: \((error as NSError).userInfo)")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("OpenVPN config applied. autologin=\(evaluation.autologin)")

        // Provide credentials if needed
        if !evaluation.autologin {
            let username = providerConfig["username"] as? String ?? ""
            let password = providerConfig["password"] as? String ?? ""
            log.info("OpenVPN requires auth. username provided: \(!username.isEmpty)")
            if !username.isEmpty {
                let credentials = OpenVPNCredentials()
                credentials.username = username
                credentials.password = password
                do {
                    try openVPNAdapter.provide(credentials: credentials)
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.openVPNStartCompletion = { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                    self.openVPNAdapter.connect(using: self.packetFlow)
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 second timeout
                throw NEVPNError(.connectionFailed)
            }

            // Wait for whichever finishes first
            try await group.next()
            group.cancelAll()
        }

        log.info("OpenVPN tunnel started successfully")
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
        log.error("OpenVPN error (fatal=\(isFatal)): \(error.localizedDescription, privacy: .public)")
        log.error("OpenVPN error details: \(nsError.domain) code=\(nsError.code) \(nsError.userInfo)")

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
