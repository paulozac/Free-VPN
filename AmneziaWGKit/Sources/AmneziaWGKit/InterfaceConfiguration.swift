// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network

public struct InterfaceConfiguration {
    public var privateKey: PrivateKey
    public var addresses = [IPAddressRange]()
    public var junkPacketCount: UInt16?
    public var junkPacketMinSize: UInt16?
    public var junkPacketMaxSize: UInt16?
    public var initPacketJunkSize: UInt16?
    public var responsePacketJunkSize: UInt16?
    public var cookiePacketJunkSize: UInt16?       // S3 (AWG v2)
    public var transportPacketJunkSize: UInt16?    // S4 (AWG v2)
    public var initPacketMagicHeader: String?      // H1 - String to support AWG v2 ranges ("min-max")
    public var responsePacketMagicHeader: String?   // H2
    public var underloadPacketMagicHeader: String?  // H3
    public var transportPacketMagicHeader: String?  // H4
    public var initPacketData1: String?             // I1 (AWG v2 concealment)
    public var initPacketData2: String?             // I2
    public var initPacketData3: String?             // I3
    public var initPacketData4: String?             // I4
    public var initPacketData5: String?             // I5
    public var listenPort: UInt16?
    public var mtu: UInt16?
    public var dns = [DNSServer]()
    public var dnsSearch = [String]()

    public init(privateKey: PrivateKey) {
        self.privateKey = privateKey
    }
}

extension InterfaceConfiguration: Equatable {
    public static func == (lhs: InterfaceConfiguration, rhs: InterfaceConfiguration) -> Bool {
        let lhsAddresses = lhs.addresses.filter { $0.address is IPv4Address } + lhs.addresses.filter { $0.address is IPv6Address }
        let rhsAddresses = rhs.addresses.filter { $0.address is IPv4Address } + rhs.addresses.filter { $0.address is IPv6Address }

        return lhs.privateKey == rhs.privateKey &&
            lhsAddresses == rhsAddresses &&
            lhs.listenPort == rhs.listenPort &&
            lhs.mtu == rhs.mtu &&
            lhs.dns == rhs.dns &&
            lhs.dnsSearch == rhs.dnsSearch &&
            lhs.junkPacketCount == rhs.junkPacketCount &&
            lhs.junkPacketMinSize == rhs.junkPacketMinSize &&
            lhs.junkPacketMaxSize == rhs.junkPacketMaxSize &&
            lhs.initPacketJunkSize == rhs.initPacketJunkSize &&
            lhs.responsePacketJunkSize == rhs.responsePacketJunkSize &&
            lhs.cookiePacketJunkSize == rhs.cookiePacketJunkSize &&
            lhs.transportPacketJunkSize == rhs.transportPacketJunkSize &&
            lhs.initPacketMagicHeader == rhs.initPacketMagicHeader &&
            lhs.responsePacketMagicHeader == rhs.responsePacketMagicHeader &&
            lhs.underloadPacketMagicHeader == rhs.underloadPacketMagicHeader &&
            lhs.transportPacketMagicHeader == rhs.transportPacketMagicHeader &&
            lhs.initPacketData1 == rhs.initPacketData1 &&
            lhs.initPacketData2 == rhs.initPacketData2 &&
            lhs.initPacketData3 == rhs.initPacketData3 &&
            lhs.initPacketData4 == rhs.initPacketData4 &&
            lhs.initPacketData5 == rhs.initPacketData5
    }
}
