import Foundation

struct DeviceLoginClient {
    let session: URLSession
    let openBrowser: @Sendable (String) -> Void
    let saveProviderToken: @Sendable (String) throws -> Void

    init(session: URLSession = .shared,
         openBrowser: @escaping @Sendable (String) -> Void = Self.openSystemBrowser,
         saveProviderToken: @escaping @Sendable (String) throws -> Void = AuthTokenStore.save) {
        self.session = session
        self.openBrowser = openBrowser
        self.saveProviderToken = saveProviderToken
    }

    static func openSystemBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        _ = try? process.run()
    }

    func login(coordinatorURL: String,
               onDisplayCode: @Sendable (String, String, Int) -> Void,
               onPollTick: (@Sendable () -> Void)? = nil,
               purpose: String? = nil,
               allowLegacyAccountFlow: Bool = false,
               automaticallyOpenBrowser: Bool = true) async throws -> String {
        // Check if already logged in.
        if purpose == nil, let existingToken = AuthTokenStore.load() {
            let prefix = String(existingToken.prefix(min(20, existingToken.count)))
            throw DeviceAuthError.alreadyLoggedIn(tokenPrefix: prefix)
        }

        let baseURL = coordinatorHTTPBase(coordinatorURL)

        // Step 1: Request a device code.
        let codeURL = URL(string: "\(baseURL)/v1/device/code")!
        var codeRequest = URLRequest(url: codeURL)
        codeRequest.httpMethod = "POST"
        codeRequest.timeoutInterval = 10
        if let purpose {
          guard purpose == "desktop_account" else { throw DeviceAuthError.invalidResponse("unsupported authorization purpose") }
          codeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
          codeRequest.httpBody = try JSONSerialization.data(withJSONObject: ["purpose": purpose])
        }

        let codeData: Data
        let codeResponse: URLResponse
        do {
            (codeData, codeResponse) = try await session.data(for: codeRequest)
        } catch {
            throw DeviceAuthError.coordinatorUnreachable(error.localizedDescription)
        }

        guard let httpResponse = codeResponse as? HTTPURLResponse else {
            throw DeviceAuthError.invalidResponse("non-HTTP response")
        }
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            let body = String(data: codeData, encoding: .utf8) ?? ""
            throw DeviceAuthError.deviceCodeRequestFailed(body)
        }

        let dc: DeviceCodeResponse
        do {
            dc = try JSONDecoder().decode(DeviceCodeResponse.self, from: codeData)
        } catch {
            throw DeviceAuthError.invalidResponse("could not decode device code response: \(error)")
        }

        let scope = try DeviceLoginScope.negotiate(purpose: purpose, response: dc, allowLegacyAccountFlow: allowLegacyAccountFlow)
        // Display the code to the user.
        onDisplayCode(dc.user_code, dc.verification_uri, dc.expires_in)

        if automaticallyOpenBrowser { openBrowser(dc.verification_uri) }

        // Step 2: Poll for authorization.
        let tokenURL = URL(string: "\(baseURL)/v1/device/token")!
        let pollInterval = max(dc.interval, 1) // At least 1 second
        let deadline = Date().addingTimeInterval(TimeInterval(dc.expires_in))

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)

            var tokenRequest = URLRequest(url: tokenURL)
            tokenRequest.httpMethod = "POST"
            tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            tokenRequest.timeoutInterval = 10

            let body = try JSONSerialization.data(
                withJSONObject: ["device_code": dc.device_code]
            )
            tokenRequest.httpBody = body

            let tokenData: Data
            do {
                (tokenData, _) = try await session.data(for: tokenRequest)
            } catch {
                // Network error -- retry on next tick.
                onPollTick?()
                continue
            }

            let tokenResp: DeviceTokenResponse
            do {
                tokenResp = try JSONDecoder().decode(DeviceTokenResponse.self, from: tokenData)
            } catch {
                // Malformed response -- retry.
                onPollTick?()
                continue
            }

            switch tokenResp.status ?? "" {
            case "authorization_pending":
                onPollTick?()
                continue

            case "authorized":
                guard let token = tokenResp.token, !token.isEmpty else {
                    throw DeviceAuthError.invalidResponse("authorized but no token in response")
                }
                try scope.validate(token: token, purpose: tokenResp.purpose)
                if scope == .provider { try saveProviderToken(token) }
                return token

            default:
                // expired or error
                let message = tokenResp.error?.message ?? "Device code expired or invalid"
                throw DeviceAuthError.authorizationFailed(message)
            }
        }

        throw DeviceAuthError.deviceCodeExpired
    }
}
