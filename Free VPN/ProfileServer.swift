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
/// serving a web page where users can upload a WireGuard or OpenVPN profile.
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
            Task { @MainActor [weak self] in
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

        if configValue.isEmpty {
            sendErrorPage(message: "No configuration provided.", on: connection)
            return
        }

        // Detect protocol type and validate accordingly
        let lower = configValue.lowercased()
        let isWireGuard = lower.contains("[interface]") && lower.contains("[peer]") && lower.contains("privatekey")
        let hasClient = lower.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == "client" }
        let isOpenVPN = !isWireGuard && (lower.contains("remote ") || lower.contains("<ca>") || hasClient)

        if isWireGuard {
            if let validationError = WireGuardConfig.validate(configValue) {
                sendErrorPage(message: validationError, on: connection)
                return
            }
        } else if isOpenVPN {
            if let validationError = OpenVPNConfig.validate(configValue) {
                sendErrorPage(message: validationError, on: connection)
                return
            }
        }

        let protocolName = isOpenVPN ? "OpenVPN" : "WireGuard"

        Task { @MainActor in
            self.onProfileReceived?(profileName, configValue)
        }

        sendSuccessPage(profileName: profileName.isEmpty ? "Unnamed" : profileName, protocolName: protocolName, on: connection)
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

    private nonisolated func sendSuccessPage(profileName: String, protocolName: String, on connection: NWConnection) {
        let html = Self.responsePage(
            icon: "&#10003;",
            iconColor: "#34c759",
            title: "\(protocolName) Profile Uploaded",
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
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
        *{box-sizing:border-box}
        body{font-family:-apple-system,system-ui,'Roboto',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:16px;background:#f5f5f5;color:#212121}
        .card{text-align:center;padding:32px 24px;border-radius:16px;background:#fff;max-width:440px;width:100%;box-shadow:0 2px 8px rgba(0,0,0,0.08),0 1px 2px rgba(0,0,0,0.04)}
        @media(min-width:480px){.card{padding:48px 40px}}
        .icon{font-size:64px;margin-bottom:20px;color:\(iconColor)}
        h1{margin:0 0 12px;font-size:22px;font-weight:600;color:#1a1a1a}
        p{color:#666;font-size:16px;line-height:1.6;margin:0 0 28px}
        a{display:inline-flex;align-items:center;gap:6px;color:#fff;background:#1a73e8;text-decoration:none;font-weight:600;font-size:15px;padding:12px 24px;border-radius:24px;transition:background 0.2s}
        a:hover{background:#1557b0}
        a:active{background:#12489e}
        </style></head><body>
        <div class="card">
        <div class="icon">\(icon)</div>
        <h1>\(title)</h1>
        <p>\(message)</p>
        \(showBackLink ? "<a href=\"/\">&#8592; Upload another</a>" : "")
        </div></body></html>
        """
    }

    private nonisolated static let uploadPageHTML = """
    <!DOCTYPE html>
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
    <meta name="theme-color" content="#f5f5f5">
    <style>
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    body{font-family:-apple-system,system-ui,'Roboto',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:16px;background:#f5f5f5;color:#212121}
    .card{max-width:520px;width:100%;padding:28px 20px;border-radius:16px;background:#fff;box-shadow:0 2px 8px rgba(0,0,0,0.08),0 1px 2px rgba(0,0,0,0.04)}
    @media(min-width:480px){.card{padding:40px}}
    h1{margin:0 0 4px;font-size:26px;text-align:center;font-weight:700;color:#1a1a1a}
    .sub{color:#757575;margin:0 0 28px;font-size:15px;text-align:center}
    label.field{display:block;color:#757575;font-size:12px;font-weight:600;margin-bottom:8px;text-transform:uppercase;letter-spacing:0.8px}
    input[type=text]{width:100%;padding:16px;background:#fafafa;color:#212121;border:1.5px solid #e0e0e0;border-radius:12px;font-size:17px;margin-bottom:20px;transition:border-color 0.2s}
    input[type=text]:focus{outline:none;border-color:#1a73e8;background:#fff;box-shadow:0 0 0 3px rgba(26,115,232,0.1)}
    input[type=text]::placeholder{color:#bdbdbd}
    input[type=file]{display:none}
    .file-label{display:flex;align-items:center;justify-content:center;gap:10px;padding:22px;border:2px dashed #d0d0d0;border-radius:12px;cursor:pointer;color:#757575;font-size:17px;font-weight:500;transition:all 0.2s;min-height:72px;text-align:center;background:#fafafa}
    .file-label:hover,.file-label:active{border-color:#1a73e8;color:#1a73e8;background:#e8f0fe}
    .file-label.active{border-color:#34a853;color:#34a853;border-style:solid;background:#e6f4ea}
    .file-name{color:#1a73e8;margin-top:8px;font-size:14px;text-align:center;min-height:20px}
    .detected{text-align:center;margin-top:10px;font-size:15px;font-weight:600;min-height:22px}
    .detected.wg{color:#34a853}
    .detected.ovpn{color:#e8710a}
    .paste-toggle{display:flex;align-items:center;justify-content:center;gap:6px;color:#9e9e9e;font-size:14px;margin:20px 0 8px;cursor:pointer;-webkit-user-select:none;user-select:none;transition:color 0.2s}
    .paste-toggle:hover{color:#616161}
    .paste-toggle .arrow{transition:transform 0.2s;display:inline-block;font-size:10px}
    .paste-toggle .arrow.open{transform:rotate(90deg)}
    .paste-section{display:none;margin-top:8px}
    .paste-section.open{display:block}
    textarea{width:100%;height:180px;background:#fafafa;color:#333;border:1.5px solid #e0e0e0;border-radius:12px;padding:14px;font-family:'SF Mono',Menlo,monospace;font-size:14px;resize:vertical;transition:border-color 0.2s}
    textarea:focus{outline:none;border-color:#1a73e8;background:#fff;box-shadow:0 0 0 3px rgba(26,115,232,0.1)}
    textarea::placeholder{color:#bdbdbd}
    button{width:100%;padding:18px;background:#1a73e8;color:#fff;border:none;border-radius:24px;font-size:18px;font-weight:600;cursor:pointer;margin-top:24px;transition:all 0.2s;min-height:56px;box-shadow:0 2px 6px rgba(26,115,232,0.3)}
    button:hover{background:#1557b0;box-shadow:0 4px 12px rgba(26,115,232,0.4)}
    button:active{background:#12489e;transform:scale(0.98)}
    button:disabled{background:#e0e0e0;color:#9e9e9e;cursor:not-allowed;box-shadow:none}
    .hint{color:#9e9e9e;font-size:13px;margin-top:20px;text-align:center;line-height:1.6}
    .error{background:#fce8e6;border:1px solid #f5c6cb;color:#c62828;padding:14px;border-radius:12px;font-size:15px;margin-bottom:16px;display:none;line-height:1.4}
    </style></head><body>
    <div class="card">
    <h1>ZacVPN</h1>
    <p class="sub">Upload a WireGuard or OpenVPN profile to your Apple TV</p>
    <div class="error" id="error"></div>
    <form method="POST" id="form">
    <label class="field" for="name">Profile Name (optional)</label>
    <input type="text" name="name" id="name" placeholder="e.g. Home Server, US East, Work VPN">
    <label class="file-label" for="file" id="fileLabel">&#128193; Choose VPN config file</label>
    <input type="file" id="file">
    <div class="file-name" id="fileName"></div>
    <div class="detected" id="detected"></div>
    <div class="paste-toggle" id="pasteToggle"><span class="arrow" id="arrow">&#9654;</span> Or paste config manually</div>
    <div class="paste-section" id="pasteSection">
    <textarea name="config" id="config" placeholder="Paste WireGuard (.conf) or OpenVPN (.ovpn) config here..."></textarea>
    </div>
    <input type="hidden" name="config" id="configHidden" disabled>
    <button type="submit" id="btn" disabled>Upload Profile</button>
    </form>
    <p class="hint">Supports WireGuard and OpenVPN profiles.<br>Any file type accepted &mdash; content is validated automatically.</p>
    </div>
    <script>
    const config=document.getElementById('config'),file=document.getElementById('file'),
    btn=document.getElementById('btn'),fileName=document.getElementById('fileName'),
    nameField=document.getElementById('name'),errorDiv=document.getElementById('error'),
    fileLabel=document.getElementById('fileLabel'),form=document.getElementById('form'),
    detected=document.getElementById('detected'),pasteToggle=document.getElementById('pasteToggle'),
    pasteSection=document.getElementById('pasteSection'),arrow=document.getElementById('arrow'),
    configHidden=document.getElementById('configHidden');

    pasteToggle.addEventListener('click',function(){
      const open=pasteSection.classList.toggle('open');
      arrow.classList.toggle('open',open);
      if(open){config.disabled=false;configHidden.disabled=true;config.name='config';configHidden.name=''}
    });

    config.name='';configHidden.name='config';configHidden.disabled=false;

    function detectProtocol(c){
      const l=c.toLowerCase();
      if(l.includes('[interface]')&&l.includes('[peer]')&&l.includes('privatekey'))return'wireguard';
      if(l.includes('remote ')||l.includes('<ca>')||/^client\\s*$/m.test(l))return'openvpn';
      return null;
    }

    function getConfigValue(){
      if(pasteSection.classList.contains('open'))return config.value.trim();
      return configHidden.value.trim();
    }

    function validate(){
      const c=getConfigValue();
      errorDiv.style.display='none';
      detected.textContent='';detected.className='detected';
      if(!c){btn.disabled=true;return}

      const proto=detectProtocol(c);
      if(proto==='wireguard'){
        detected.textContent='Detected: WireGuard';detected.className='detected wg';
        if(!c.match(/PrivateKey\\s*=/i)){showError("Missing PrivateKey in [Interface] section.");btn.disabled=true;return}
        if(!c.match(/PublicKey\\s*=/i)){showError("Missing PublicKey in [Peer] section.");btn.disabled=true;return}
      }else if(proto==='openvpn'){
        detected.textContent='Detected: OpenVPN';detected.className='detected ovpn';
        if(!c.match(/remote\\s+/im)){showError("Missing 'remote' directive.");btn.disabled=true;return}
        if(!c.includes('<ca>')&&!/^ca\\s+/m.test(c)){showError("Missing CA certificate (<ca> block or ca directive).");btn.disabled=true;return}
      }else{
        showError("This doesn't look like a valid WireGuard or OpenVPN config file. Please check your file and try again.");
        btn.disabled=true;return;
      }
      errorDiv.style.display='none';
      btn.disabled=false;
    }

    function showError(msg){errorDiv.textContent=msg;errorDiv.style.display='block'}

    config.addEventListener('input',function(){
      configHidden.value=config.value;
      validate();
    });

    file.addEventListener('change',function(){
      if(this.files[0]){
        const f=this.files[0];
        fileName.textContent=f.name;
        fileLabel.classList.add('active');
        fileLabel.innerHTML='&#10003; '+f.name;
        if(!nameField.value.trim()){
          nameField.value=f.name.replace(/\\.[^.]+$/,'');
        }
        const r=new FileReader();
        r.onload=function(e){
          const content=e.target.result;
          configHidden.value=content;
          config.value=content;
          validate();
        };
        r.readAsText(f);
      }
    });

    form.addEventListener('submit',function(){
      if(pasteSection.classList.contains('open')){
        configHidden.disabled=true;config.name='config';
      }else{
        config.name='';configHidden.name='config';configHidden.disabled=false;
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
