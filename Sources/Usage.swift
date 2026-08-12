import Foundation

/// SuperGrok weekly pool, same number grok.com / `/usage` shows.
enum GrokUsage {

    private static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static var cached: Int?
    private static var fetchedAt: Date?
    private static var inFlight = false

    static var percentUsed: Int? { cached }

    static func refresh(token: String, force: Bool = false, completion: ((Int?) -> Void)? = nil) {
        if !force, let at = fetchedAt, Date().timeIntervalSince(at) < 45, let cached {
            completion?(cached)
            return
        }
        if inFlight {
            completion?(cached)
            return
        }
        inFlight = true

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, _ in
            defer {
                inFlight = false
            }
            var value: Int?
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let config = root["config"] as? [String: Any] {
                if let n = config["creditUsagePercent"] as? Double {
                    value = Int(n.rounded())
                } else if let n = config["creditUsagePercent"] as? Int {
                    value = n
                }
            }
            if let value {
                cached = max(0, min(100, value))
                fetchedAt = Date()
                Log.write("usage \(cached!)%")
            }
            DispatchQueue.main.async { completion?(cached) }
        }.resume()
    }
}
