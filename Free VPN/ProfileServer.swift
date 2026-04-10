//
//  ProfileServer.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/11/26.
//

import Foundation
import Network
import os.log

/// A lightweight HTTP server that runs on the Apple TV's local network,
/// serving a web page where users can upload a WireGuard .conf profile.
@MainActor
@Observable
final class ProfileServer {

    private(set) var isRunning = false
    private(set) var localURL: String?

    /// Called with (name, configString) when a valid profile is uploaded.
    var onProfileReceived: ((String, String) -> Void)?

    private let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "ProfileServer")
    private var listener: NWListener?
    private let port: UInt16 = 8080

    func start() {
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            log.error("Failed to create listener: \(error.localizedDescription)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.localURL = "http://\(self.getLocalIPAddress()):\(self.port)"
                    self.log.info("Server ready at \(self.localURL ?? "unknown")")
                case .failed(let error):
                    self.log.error("Listener failed: \(error.localizedDescription)")
                    self.isRunning = false
                    self.localURL = nil
                case .cancelled:
                    self.isRunning = false
                    self.localURL = nil
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        localURL = nil
    }

    // MARK: - Connection Handling

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""

            if request.starts(with: "POST") {
                self.handlePostRequest(request, connection: connection, initialData: data)
            } else {
                self.sendUploadPage(on: connection)
            }
        }
    }

    private nonisolated func handlePostRequest(_ request: String, connection: NWConnection, initialData: Data) {
        let fullRequest = String(data: initialData, encoding: .utf8) ?? ""
        let contentLength = extractContentLength(from: fullRequest)

        if let bodyRange = fullRequest.range(of: "\r\n\r\n") {
            let body = String(fullRequest[bodyRange.upperBound...])
            let bodyBytes = body.utf8.count

            if bodyBytes >= contentLength {
                processUploadBody(body, connection: connection)
            } else {
                let remaining = contentLength - bodyBytes
                readRemainingBody(existingBody: body, remaining: remaining, connection: connection)
            }
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self, let data else {
                    connection.cancel()
                    return
                }
                let combined = String(data: initialData, encoding: .utf8)! + String(data: data, encoding: .utf8)!
                self.handlePostRequest(combined, connection: connection, initialData: initialData + data)
            }
        }
    }

    private nonisolated func readRemainingBody(existingBody: String, remaining: Int, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let chunk = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let combined = existingBody + chunk
            let newRemaining = remaining - data.count
            if newRemaining <= 0 {
                self.processUploadBody(combined, connection: connection)
            } else {
                self.readRemainingBody(existingBody: combined, remaining: newRemaining, connection: connection)
            }
        }
    }

    private nonisolated func processUploadBody(_ body: String, connection: NWConnection) {
        let params = parseFormParams(body)

        let configValue = (params["config"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let profileName = (params["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate the config
        if let validationError = WireGuardConfig.validate(configValue) {
            sendErrorPage(message: validationError, on: connection)
            return
        }

        Task { @MainActor in
            self.log.info("Received valid profile '\(profileName)' via HTTP upload (\(configValue.count) chars)")
            self.onProfileReceived?(profileName, configValue)
        }

        sendSuccessPage(profileName: profileName.isEmpty ? "Unnamed" : profileName, on: connection)
    }

    // MARK: - Form Parsing

    private nonisolated func parseFormParams(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.components(separatedBy: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = String(parts.first ?? "")
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let value = rawValue
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? rawValue
            result[key] = value
        }
        return result
    }

    // MARK: - Response Pages

    private nonisolated func sendSuccessPage(profileName: String, on connection: NWConnection) {
        let html = Self.responsePage(
            icon: "&#10003;",
            iconColor: "#34c759",
            title: "Profile Uploaded",
            message: "\"\(profileName.replacingOccurrences(of: "\"", with: "&quot;"))\" has been added to your Apple TV. You can select it from the profile list.",
            showBackLink: true
        )
        sendHTTPResponse(html, on: connection)
    }

    private nonisolated func sendErrorPage(message: String, on connection: NWConnection) {
        let html = Self.responsePage(
            icon: "&#10007;",
            iconColor: "#ff3b30",
            title: "Invalid Profile",
            message: message.replacingOccurrences(of: "\"", with: "&quot;"),
            showBackLink: true
        )
        sendHTTPResponse(html, on: connection)
    }

    private nonisolated func sendHTTPResponse(_ body: String, status: String = "200 OK", on connection: NWConnection) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private nonisolated func sendUploadPage(on connection: NWConnection) {
        sendHTTPResponse(Self.uploadPageHTML, on: connection)
    }

    // MARK: - HTML Templates

    private nonisolated static func responsePage(icon: String, iconColor: String, title: String, message: String, showBackLink: Bool) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#1a1a1a;color:#fff}
        .card{text-align:center;padding:40px;border-radius:16px;background:#2a2a2a;max-width:440px}
        .icon{font-size:64px;margin-bottom:16px;color:\(iconColor)}
        h1{margin:0 0 12px;font-size:22px}
        p{color:#aaa;font-size:15px;line-height:1.5;margin:0 0 24px}
        a{color:#0a84ff;text-decoration:none;font-weight:600;font-size:15px}
        a:hover{text-decoration:underline}
        </style></head><body>
        <div class="card">
        <div class="icon">\(icon)</div>
        <h1>\(title)</h1>
        <p>\(message)</p>
        \(showBackLink ? "<a href=\"/\">&#8592; Upload another profile</a>" : "")
        </div></body></html>
        """
    }

    private static let uploadPageHTML = """
    <!DOCTYPE html>
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    *{box-sizing:border-box}
    body{font-family:-apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#1a1a1a;color:#fff}
    .card{max-width:480px;width:100%;padding:40px;border-radius:16px;background:#2a2a2a}
    h1{margin:0 0 4px;font-size:24px}
    .sub{color:#888;margin:0 0 24px;font-size:14px}
    label.field{display:block;color:#aaa;font-size:13px;font-weight:600;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px}
    input[type=text]{width:100%;padding:12px;background:#111;color:#fff;border:1px solid #444;border-radius:8px;font-size:15px;margin-bottom:16px}
    input[type=text]:focus{outline:none;border-color:#0a84ff}
    textarea{width:100%;height:180px;background:#111;color:#0f0;border:1px solid #444;border-radius:8px;padding:12px;font-family:monospace;font-size:13px;resize:vertical}
    textarea:focus{outline:none;border-color:#0a84ff}
    .or{text-align:center;color:#666;margin:14px 0;font-size:13px}
    input[type=file]{display:none}
    .file-label{display:block;text-align:center;padding:14px;border:2px dashed #444;border-radius:8px;cursor:pointer;color:#888;font-size:14px;transition:all 0.2s}
    .file-label:hover{border-color:#0a84ff;color:#0a84ff}
    .file-label.active{border-color:#34c759;color:#34c759;border-style:solid}
    .file-name{color:#0a84ff;margin-top:8px;font-size:13px;text-align:center;min-height:20px}
    button{width:100%;padding:14px;background:#0a84ff;color:#fff;border:none;border-radius:8px;font-size:16px;font-weight:600;cursor:pointer;margin-top:20px;transition:background 0.2s}
    button:hover{background:#0070e0}
    button:disabled{background:#333;color:#666;cursor:not-allowed}
    .hint{color:#666;font-size:12px;margin-top:16px;text-align:center;line-height:1.5}
    .error{background:#ff3b3020;border:1px solid #ff3b30;color:#ff6b6b;padding:12px;border-radius:8px;font-size:14px;margin-bottom:16px;display:none}
    </style></head><body>
    <div class="card">
    <h1>ZacVPN</h1>
    <p class="sub">Upload a WireGuard profile to your Apple TV</p>
    <div class="error" id="error"></div>
    <form method="POST" id="form">
    <label class="field" for="name">Profile Name (optional)</label>
    <input type="text" name="name" id="name" placeholder="e.g. Home Server, US East, Work VPN">
    <label class="field" for="config">Configuration</label>
    <textarea name="config" id="config" placeholder="[Interface]&#10;PrivateKey = ...&#10;Address = 10.0.0.2/24&#10;DNS = 1.1.1.1&#10;&#10;[Peer]&#10;PublicKey = ...&#10;Endpoint = vpn.example.com:51820&#10;AllowedIPs = 0.0.0.0/0"></textarea>
    <div class="or">&#8212; or &#8212;</div>
    <label class="file-label" for="file" id="fileLabel">&#128193; Choose .conf file</label>
    <input type="file" id="file" accept=".conf,.txt">
    <div class="file-name" id="fileName"></div>
    <button type="submit" id="btn" disabled>Upload Profile</button>
    </form>
    <p class="hint">Your profile must contain an [Interface] section with PrivateKey and Address,<br>and at least one [Peer] section with a PublicKey.</p>
    </div>
    <script>
    const config=document.getElementById('config'),file=document.getElementById('file'),
    btn=document.getElementById('btn'),fileName=document.getElementById('fileName'),
    nameField=document.getElementById('name'),errorDiv=document.getElementById('error'),
    fileLabel=document.getElementById('fileLabel'),form=document.getElementById('form');

    function validate(){
      const c=config.value.trim();
      errorDiv.style.display='none';
      if(!c){btn.disabled=true;return}
      // Basic client-side checks
      if(!c.match(/\\[Interface\\]/i)){
        showError("Missing [Interface] section. This doesn't look like a WireGuard config.");
        btn.disabled=true;return;
      }
      if(!c.match(/PrivateKey\\s*=/i)){
        showError("Missing PrivateKey in [Interface] section.");
        btn.disabled=true;return;
      }
      if(!c.match(/\\[Peer\\]/i)){
        showError("Missing [Peer] section. At least one peer is required.");
        btn.disabled=true;return;
      }
      if(!c.match(/PublicKey\\s*=/i)){
        showError("Missing PublicKey in [Peer] section.");
        btn.disabled=true;return;
      }
      errorDiv.style.display='none';
      btn.disabled=false;
    }

    function showError(msg){errorDiv.textContent=msg;errorDiv.style.display='block'}

    config.addEventListener('input',validate);

    file.addEventListener('change',function(){
      if(this.files[0]){
        const f=this.files[0];
        if(!f.name.endsWith('.conf')&&!f.name.endsWith('.txt')){
          showError("Please select a .conf or .txt file.");return;
        }
        fileName.textContent=f.name;
        fileLabel.classList.add('active');
        fileLabel.innerHTML='&#10003; '+f.name;
        // Auto-fill name from filename
        if(!nameField.value.trim()){
          nameField.value=f.name.replace(/\\.(conf|txt)$/,'');
        }
        const r=new FileReader();
        r.onload=function(e){config.value=e.target.result;validate()};
        r.readAsText(f);
      }
    });
    </script>
    </div></body></html>
    """

    // MARK: - Helpers

    private nonisolated func extractContentLength(from request: String) -> Int {
        for line in request.components(separatedBy: "\r\n") {
            if line.lowercased().starts(with: "content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    nonisolated func getLocalIPAddress() -> String {
        var address = "0.0.0.0"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            guard addr.sa_family == UInt8(AF_INET),
                  (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
                break
            }
        }
        return address
    }
}
