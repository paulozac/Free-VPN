import NetworkExtension
import os.log
import WireGuardKit

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.zacvpn.zacvpn.PacketTunnel", category: "tunnel")
    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log.log(level: logLevel == .error ? .error : .debug, "\(message, privacy: .public)")
        }
    }()

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        log.info("Starting WireGuard tunnel...")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration,
              let wgQuickConfig = providerConfig["wgQuickConfig"] as? String else {
            log.error("Missing WireGuard configuration")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("Config received (\(wgQuickConfig.count) chars)")

        let tunnelConfig: TunnelConfiguration
        do {
            tunnelConfig = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig, called: "ZacVPN")
        } catch {
            log.error("Failed to parse WireGuard config: \(error.localizedDescription)")
            throw NEVPNError(.configurationInvalid)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfig) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        log.info("WireGuard tunnel started successfully")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.info("Stopping WireGuard tunnel, reason: \(String(describing: reason))")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in
                continuation.resume()
            }
        }
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        return nil
    }
}
