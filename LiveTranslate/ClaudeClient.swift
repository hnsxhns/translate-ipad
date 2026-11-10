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

        /// 401 / 403: the key or account itself is the problem.
        var isAuthError: Bool {
            if case .http(let code, _) = self { return code == 401 || code == 403 }
            return false
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

    /// Single-turn convenience wrapper.
    @discardableResult
    func stream(system: String,
                user: String,
                effort: String,
                maxTokens: Int,
                onText: @escaping (String) async -> Void) async throws -> String {
        try await stream(system: system, messages: [["role": "user", "content": user]],
                         effort: effort, maxTokens: maxTokens, onText: onText)
    }

    /// Streams a reply to a (possibly multi-turn) conversation and returns the full text.
    /// Tries with the server-side refusal fallback first; if the API rejects that option, retries without it.
    @discardableResult
    func stream(system: String,
                messages: [[String: String]],
                effort: String,
                maxTokens: Int,
                onText: @escaping (String) async -> Void) async throws -> String {
        do {
            return try await streamOnce(system: system, messages: messages, effort: effort,
                                        maxTokens: maxTokens, useFallback: true, onText: onText)
        } catch ClaudeError.http(400, let msg) where msg.lowercased().contains("fallback") {
            return try await streamOnce(system: system, messages: messages, effort: effort,
                                        maxTokens: maxTokens, useFallback: false, onText: onText)
        }
    }

    private func streamOnce(system: String,
                            messages: [[String: String]],
                            effort: String,
                            maxTokens: Int,
                            useFallback: Bool,
                            onText: @escaping (String) async -> Void) async throws -> String {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "stream": true,
            "output_config": ["effort": effort],
            "system": system,
            "messages": messages,
        ]
        if useFallback {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw ClaudeError.http(code, Self.errorMessage(from: data))
        }

        var out = ""
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
                    out += text
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
        return out
    }

    /// Short Vietnamese explanation of an API error (same wording as the Windows app).
    static func friendlyError(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("credit balance") {
            return "Tài khoản API hết credit ($0). Gói Ultra có $200/tháng: vào claude.ai → Settings → Billing → "
                + "API credits → Link organization, rồi dùng API key của đúng tổ chức đó."
        }
        if let e = error as? ClaudeError {
            switch e {
            case .http(401, _): return "Phiên đăng nhập/API key không còn hợp lệ. Hãy đăng nhập lại."
            case .http(403, _): return "Tài khoản không có quyền dùng model này."
            case .http(429, _): return "Đang gửi quá nhiều yêu cầu (rate limit). Hãy thử lại sau ít phút."
            case .refusal: return "Claude từ chối đoạn này."
            default: break
            }
        }
        if error is URLError { return "Mất kết nối tới Claude. Kiểm tra mạng." }
        return "Lỗi Claude: \(String(error.localizedDescription.prefix(160)))"
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
