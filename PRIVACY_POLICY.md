# ZacVPN Privacy Policy

**Last Updated: April 18, 2026**

## Overview

ZacVPN is a VPN client application for Apple TV. It connects to VPN servers that you configure using your own WireGuard (.conf) or OpenVPN (.ovpn) configuration files. ZacVPN does not provide VPN servers or services.

## Data Collection

**ZacVPN does not collect, store, transmit, or share any personal data.** Specifically:

- **No analytics or tracking** — We do not use any analytics frameworks, crash reporters, or tracking tools.
- **No accounts or registration** — ZacVPN does not require you to create an account, sign in, or provide any personal information.
- **No server-side infrastructure** — ZacVPN has no backend servers. All data stays on your device.
- **No advertising** — ZacVPN contains no ads and no ad-related SDKs.
- **No third-party services** — ZacVPN does not integrate with any third-party data collection services.

## Data Stored on Your Device

ZacVPN stores the following data **locally on your Apple TV only**:

- **VPN configuration profiles** — The WireGuard or OpenVPN configuration files you upload, including server addresses, keys, and certificates. These are stored in the app's sandboxed storage and are never transmitted to us or any third party.
- **Selected profile preference** — Which VPN profile you have selected as active.

This data never leaves your device except when establishing a VPN connection to the server specified in your configuration.

## Network Connections

ZacVPN makes the following network connections:

1. **VPN tunnel** — Connects to the VPN server specified in your configuration file. All traffic is encrypted using WireGuard or OpenVPN protocols.
2. **IP location lookup** — When connected, ZacVPN makes a single request to `ipinfo.io/json` to display your current public IP address and approximate location. This is optional status information and no personally identifiable data is sent.
3. **Profile upload server** — When you use the "Upload Profile" feature, ZacVPN runs a temporary local HTTP server on your home network to receive configuration files from your phone or computer. This server only accepts connections from your local network and stops when you close the upload screen.

## VPN Traffic

ZacVPN is a client only. Your VPN traffic is routed to servers that **you** configure. We have no access to, control over, or visibility into your VPN traffic. The privacy of your VPN connection depends on the VPN server you choose to use.

## Children's Privacy

ZacVPN does not collect any data from anyone, including children under 13.

## Changes to This Policy

If we update this privacy policy, we will post the revised version here with an updated date.

## Contact

If you have questions about this privacy policy, please contact us at:

**Email:** zacvpn@proton.me
