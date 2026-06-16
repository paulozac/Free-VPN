//
//  SpeedTestManager.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 6/14/26.
//

import Foundation
import os.log

@MainActor
@Observable
final class SpeedTestManager {

    enum TestState: Equatable {
        case idle
        case testingLatency
        case testingDownload
        case testingUpload
        case done
        case error(String)
    }

    private(set) var state: TestState = .idle
    private(set) var latencyMs: Double?
    private(set) var minLatencyMs: Double?
    private(set) var downloadMbps: Double?
    private(set) var uploadMbps: Double?
    private(set) var peakDownloadMbps: Double?
    private(set) var peakUploadMbps: Double?
    private(set) var progress: Double = 0
    private(set) var testServerHostname: String?
    private(set) var testServerIP: String?

    var isRunning: Bool {
        switch state {
        case .testingLatency, .testingDownload, .testingUpload: true
        default: false
        }
    }

    private let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "SpeedTest")
    private var testTask: Task<Void, Never>?

    func startTest() {
        testTask?.cancel()
        clearResults()

        testTask = Task {
            do {
                state = .testingLatency
                progress = 0

                let ip = Self.resolveHost("speed.cloudflare.com")
                testServerIP = ip
                if let ip { testServerHostname = Self.reverseDNS(ip) }

                let latencyResult = try await measureLatency()
                latencyMs = latencyResult.average
                minLatencyMs = latencyResult.min
                if Task.isCancelled { return }

                state = .testingDownload
                progress = 0.33
                let downResult = try await measureThroughput(
                    url: URL(string: "https://speed.cloudflare.com/__down?bytes=20000000")!,
                    method: .download, chunkSize: 20_000_000, iterations: 4,
                    progressRange: (0.33, 0.66)
                )
                downloadMbps = downResult.average
                peakDownloadMbps = downResult.peak
                if Task.isCancelled { return }

                state = .testingUpload
                progress = 0.66
                let upResult = try await measureThroughput(
                    url: URL(string: "https://speed.cloudflare.com/__up")!,
                    method: .upload, chunkSize: 3_000_000, iterations: 5,
                    progressRange: (0.66, 1.0)
                )
                uploadMbps = upResult.average
                peakUploadMbps = upResult.peak

                progress = 1.0
                state = .done
            } catch is CancellationError {
                state = .idle
            } catch {
                log.error("Speed test failed: \(error.localizedDescription)")
                state = .error(error.localizedDescription)
            }
        }
    }

    func cancel() {
        testTask?.cancel()
        testTask = nil
        state = .idle
    }

    func reset() {
        cancel()
        clearResults()
    }

    private func clearResults() {
        latencyMs = nil
        minLatencyMs = nil
        downloadMbps = nil
        uploadMbps = nil
        peakDownloadMbps = nil
        peakUploadMbps = nil
        testServerHostname = nil
        testServerIP = nil
        progress = 0
    }

    // MARK: - DNS Resolution

    private nonisolated static func resolveHost(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let addrInfo = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var addr = addrInfo.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private nonisolated static func reverseDNS(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }

        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &sa) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &hostBuf, socklen_t(hostBuf.count),
                            nil, 0, 0)
            }
        }
        guard result == 0 else { return nil }
        let hostname = String(cString: hostBuf)
        if hostname == ip { return nil }
        return hostname
    }

    // MARK: - Latency

    private func measureLatency() async throws -> (average: Double, min: Double) {
        let url = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        var measurements: [Double] = []
        for i in 0..<8 {
            try Task.checkCancellation()
            let start = CFAbsoluteTimeGetCurrent()
            let (data, _) = try await session.data(from: url)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            measurements.append(elapsed)

            if i == 0, testServerHostname == nil, let body = String(data: data, encoding: .utf8) {
                let fields = Self.parseTrace(body)
                testServerHostname = fields["colo"]
            }
        }

        measurements.sort()
        let best = measurements.first ?? 0
        let trimmed = Array(measurements.dropFirst().dropLast())
        let avg = trimmed.reduce(0, +) / Double(trimmed.count)
        return (avg, best)
    }

    private nonisolated static func parseTrace(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in body.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            }
        }
        return result
    }

    // MARK: - Throughput

    private enum TransferMethod { case download, upload }

    private func measureThroughput(
        url: URL,
        method: TransferMethod,
        chunkSize: Int,
        iterations: Int,
        progressRange: (start: Double, end: Double)
    ) async throws -> (average: Double, peak: Double) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)

        let payload: Data? = method == .upload ? Data(repeating: 0, count: chunkSize) : nil

        var speeds: [Double] = []
        var totalBytes: Int = 0
        let overallStart = CFAbsoluteTimeGetCurrent()
        let progressSpan = progressRange.end - progressRange.start

        for i in 0..<iterations {
            try Task.checkCancellation()
            let chunkStart = CFAbsoluteTimeGetCurrent()

            let bytesTransferred: Int
            switch method {
            case .download:
                let (data, _) = try await session.data(from: url)
                bytesTransferred = data.count
            case .upload:
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (_, _) = try await session.upload(for: request, from: payload!)
                bytesTransferred = chunkSize
            }

            let chunkElapsed = CFAbsoluteTimeGetCurrent() - chunkStart
            speeds.append(Double(bytesTransferred) * 8.0 / 1_000_000.0 / chunkElapsed)
            totalBytes += bytesTransferred
            progress = progressRange.start + (Double(i + 1) / Double(iterations)) * progressSpan
        }

        let overallElapsed = CFAbsoluteTimeGetCurrent() - overallStart
        let avg = Double(totalBytes) * 8.0 / 1_000_000.0 / overallElapsed
        return (avg, speeds.max() ?? avg)
    }
}
