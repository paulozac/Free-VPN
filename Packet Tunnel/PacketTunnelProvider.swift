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

        let configuration = OpenVPNConfiguration()
        configuration.fileContent = ovpnConfig.data(using: .utf8)
        configuration.tunPersist = true

        let evaluation: OpenVPNConfigurationEvaluation
        do {
            evaluation = try openVPNAdapter.apply(configuration: configuration)
        } catch {
            log.error("Failed to apply OpenVPN config: \(error.localizedDescription)")
            throw NEVPNError(.configurationInvalid)
        }

        // Provide credentials if needed
        if evaluation.autologin == false {
            let username = providerConfig["username"] as? String ?? ""
            let password = providerConfig["password"] as? String ?? ""
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
            }
        }

        // Connect using async/await bridge
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.openVPNStartCompletion = { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            openVPNAdapter.connect(using: packetFlow)
        }

        log.info("OpenVPN tunnel started successfully")
    }
}

// MARK: - OpenVPNAdapterDelegate

extension PacketTunnelProvider: OpenVPNAdapterDelegate {

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, configureTunnelWithNetworkSettings networkSettings: NEPacketTunnelNetworkSettings?, completionHandler: @escaping (Error?) -> Void) {
        if let networkSettings = networkSettings {
            setTunnelNetworkSettings(networkSettings) { error in
                completionHandler(error)
            }
        } else {
            setTunnelNetworkSettings(nil) { error in
                completionHandler(error)
            }
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleEvent event: OpenVPNAdapterEvent, message: String?) {
        switch event {
        case .connected:
            log.info("OpenVPN connected")
            openVPNStartCompletion?(nil)
            openVPNStartCompletion = nil
        case .disconnected:
            log.info("OpenVPN disconnected")
        case .reconnecting:
            log.info("OpenVPN reconnecting")
        default:
            log.info("OpenVPN event: \(event.rawValue), message: \(message ?? "nil")")
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: NSError) {
        log.error("OpenVPN error: \(error.localizedDescription)")

        let isFatal = error.userInfo[OpenVPNAdapterErrorFatalKey] as? Bool ?? false
        if isFatal {
            log.error("Fatal OpenVPN error, stopping tunnel")
            openVPNStartCompletion?(error)
            openVPNStartCompletion = nil
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        log.debug("OpenVPN: \(logMessage, privacy: .public)")
    }
}
