import Foundation
import GoogleSignIn
import Observation
import UIKit

/// Login state. Two ways in:
///  1. Claude: the user's Anthropic (Claude Console) API key, checked against the API.
///  2. Google: Google Sign-In; Claude calls then use the key baked in at build time
///     (or one the user enters once).
@MainActor
@Observable
final class AuthStore {
    enum Method: String { case claude, google }

    var apiKey: String?
    var userLabel = ""
    var isWorking = false
    var errorMessage: String?
    /// Google login worked but no Claude key is available yet.
    var googleNeedsKey = false

    private let defaults = UserDefaults.standard

    var isLoggedIn: Bool { apiKey != nil }

    /// "Ghi nhớ đăng nhập": keep the key so next launch goes straight in (like the Windows app).
    var remember: Bool = UserDefaults.standard.object(forKey: "remember") as? Bool ?? true {
        didSet { defaults.set(remember, forKey: "remember") }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Remembered login: check in the background that the saved key still works; if the key is
    /// rejected, go back to the login screen. Network problems keep the user signed in.
    func revalidateSavedLogin() async {
        guard let key = apiKey else { return }
        do {
            try await ClaudeClient(apiKey: key).validate()
        } catch let e as ClaudeClient.ClaudeError where e.isAuthError {
            logout()
            errorMessage = "Phiên đăng nhập đã lưu không còn dùng được. Hãy đăng nhập lại."
        } catch {}
    }

    static var bundledKey: String? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "ClaudeAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty || key.hasPrefix("$(") ? nil : key
    }

    init() {
        if let key = defaults.string(forKey: "apiKey") {
            apiKey = key
            userLabel = defaults.string(forKey: "userLabel") ?? ""
        }
    }

    // MARK: Claude

    func loginWithClaude(key raw: String, label: String = "Claude") async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Vui lòng nhập Claude API key."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await ClaudeClient(apiKey: key).validate()
            finish(key: key, label: label)
        } catch {
            errorMessage = "Đăng nhập thất bại: \(error.localizedDescription)"
        }
    }

    // MARK: Google

    func loginWithGoogle() async {
        errorMessage = nil
        let clientID = (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String) ?? ""
        guard !clientID.isEmpty, !clientID.hasPrefix("$(") else {
            errorMessage = "Chưa cấu hình Google Client ID cho bản build này."
            return
        }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else { return }

        isWorking = true
        defer { isWorking = false }
        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: root)
            let email = result.user.profile?.email ?? "Google"
            if let key = Self.bundledKey {
                isWorking = false
                await loginWithClaude(key: key, label: email)
            } else {
                userLabel = email
                googleNeedsKey = true
            }
        } catch {
            if let e = error as? GIDSignInError, e.code == .canceled { return }
            errorMessage = "Đăng nhập Google thất bại: \(error.localizedDescription)"
        }
    }

    // MARK: Common

    private func finish(key: String, label: String) {
        apiKey = key
        userLabel = label
        googleNeedsKey = false
        if remember {
            defaults.set(key, forKey: "apiKey")
            defaults.set(label, forKey: "userLabel")
        } else {
            defaults.removeObject(forKey: "apiKey")
            defaults.removeObject(forKey: "userLabel")
        }
    }

    func logout() {
        GIDSignIn.sharedInstance.signOut()
        apiKey = nil
        userLabel = ""
        googleNeedsKey = false
        defaults.removeObject(forKey: "apiKey")
        defaults.removeObject(forKey: "userLabel")
    }
}
