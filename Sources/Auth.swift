import Foundation

/// Reads the Grok Build (grok CLI) OIDC credential.
///
/// This is the whole trick: `grok` writes a subscription-backed OIDC token to
/// ~/.grok/auth.json and refreshes it on its own schedule. The same token is what
/// its Ctrl+Space /voice mode presents to the xAI streaming STT endpoint. We read
/// it fresh on every recording — never cache it, never copy it anywhere.
enum Auth {

    enum Source {
        case grokBuild      // the subscription login the grok CLI stores
        case apiKey         // the user's own xAI key, from the Keychain

        var label: String {
            switch self {
            case .grokBuild: return "Grok subscription"
            case .apiKey:    return "xAI API key"
            }
        }
    }

    struct Creds {
        let token: String
        let expiresAt: Date?
        let email: String?
        var source: Source = .grokBuild

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }
    }

    static let path = NSHomeDirectory() + "/.grok/auth.json"

    /// What Quill should authenticate with right now.
    ///
    /// A key the user entered themselves wins over the subscription login: they
    /// went out of their way to provide it, and it is the only option for anyone
    /// without a Grok subscription. Falls back to the CLI session otherwise, so
    /// existing users notice no change.
    static func current() -> Creds? {
        if let key = Keychain.load() {
            return Creds(token: key, expiresAt: nil, email: nil, source: .apiKey)
        }
        return load()
    }

    /// True when there is any usable credential at all.
    static var isConfigured: Bool { current() != nil }

    static func load() -> Creds? {
        guard let entry = newestEntry()?.entry, let key = entry["key"] as? String, !key.isEmpty
        else { return nil }
        return Creds(token: key,
                     expiresAt: (entry["expires_at"] as? String).flatMap(parseDate),
                     email: entry["email"] as? String)
    }

    /// Fresh subscription token: refresh from auth.x.ai if the one on disk is
    /// expired or about to be. The grok CLI does this itself; Quill does not
    /// launch grok, so without this a 6-hour OIDC token silently 403s translate.
    static func refreshIfNeeded(force: Bool = false, completion: @escaping (Creds?) -> Void) {
        if let key = Keychain.load() {
            DispatchQueue.main.async {
                completion(Creds(token: key, expiresAt: nil, email: nil, source: .apiKey))
            }
            return
        }
        queue.async {
            guard let loaded = load() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let stale: Bool
            if force {
                stale = true
            } else if let exp = loaded.expiresAt {
                stale = exp < Date().addingTimeInterval(5 * 60)
            } else {
                stale = false
            }
            guard stale else {
                DispatchQueue.main.async { completion(loaded) }
                return
            }
            refreshLocked { creds in
                DispatchQueue.main.async { completion(creds) }
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.freeze.quill.auth")
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    private static func newestEntry() -> (id: String, entry: [String: Any])? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var newest: (String, [String: Any])?
        var newestTime = Date.distantPast
        for (id, value) in root {
            guard let entry = value as? [String: Any], entry["key"] is String else { continue }
            let created = (entry["create_time"] as? String).flatMap(parseDate) ?? Date.distantPast
            if created >= newestTime {
                newestTime = created
                newest = (id, entry)
            }
        }
        return newest
    }

    private static func refreshLocked(completion: @escaping (Creds?) -> Void) {
        guard let pair = newestEntry() else { return completion(nil) }
        let id = pair.id
        let entry = pair.entry
        guard let refresh = entry["refresh_token"] as? String, !refresh.isEmpty else {
            Log.write("auth: no refresh_token — open Grok once to sign in")
            return completion(load())
        }
        let clientId = (entry["oidc_client_id"] as? String)
            ?? id.split(separator: ":").last.map(String.init)
            ?? ""

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        request.httpBody = body.query?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            queue.async {
                if let error {
                    Log.write("auth: refresh failed — \(error.localizedDescription)")
                    return completion(load())
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let access = json["access_token"] as? String, !access.isEmpty
                else {
                    let snippet = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    Log.write("auth: refresh HTTP \(status) \(snippet.prefix(80))")
                    return completion(nil)
                }
                let newRefresh = json["refresh_token"] as? String
                let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 6 * 3600
                let expiresAt = Date().addingTimeInterval(expiresIn)
                persist(entryId: id, access: access, refresh: newRefresh, expiresAt: expiresAt)
                Log.write("auth: refreshed subscription token")
                completion(Creds(token: access, expiresAt: expiresAt,
                                 email: entry["email"] as? String, source: .grokBuild))
            }
        }.resume()
    }

    private static func persist(entryId: String, access: String, refresh: String?, expiresAt: Date) {
        guard let data = FileManager.default.contents(atPath: path),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[entryId] as? [String: Any]
        else { return }
        entry["key"] = access
        if let refresh, !refresh.isEmpty { entry["refresh_token"] = refresh }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["expires_at"] = fmt.string(from: expiresAt)
        root[entryId] = entry
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        else { return }
        do {
            try out.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            Log.write("auth: could not write refreshed token — \(error.localizedDescription)")
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
