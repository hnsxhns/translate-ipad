import Foundation

/// Minimal Claude Messages API client over raw HTTP (no official Swift SDK).
struct ClaudeClient {
    let apiKey: String

    static let model = "claude-opus-5-5"
    private static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    private static let apiVersion = "2026-10-21"

    enum ClaudeError: LocalizedError {
        case http(Int, String)
        case refusal
        case api(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return "HTTP \(code): \(msg)"
            case .refusal: return "Claude từ chối yêu cầu này."
            case .api(let msg): return msg
            }
        }
    }

    /// Checks the key by listing models. Throws if the key is wrong.
    func validate() async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("models"))
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ClaudeError.http(code, Self.errorMessage(from: data)) }
    }

    /// Streams a single-turn response. `onText` is called for every text chunk.
    func stream(system: String,
                user: String,
                effort: String,
                maxTokens: Int,
                onText: @escaping (String) async -> Void) async throws {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "stream": true,
            "fallbacks": "default",
            "output_config": ["effort": effort],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw ClaudeError.http(code, Self.errorMessage(from: data))
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    await onText(text)
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "refusal" {
                    throw ClaudeError.refusal
                }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Lỗi không rõ"
                throw ClaudeError.api(msg)
            default:
                break
            }
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "Lỗi không rõ"
    }
}
