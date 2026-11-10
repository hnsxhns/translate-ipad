import SwiftUI

struct LoginView: View {
    @Bindable var auth: AuthStore
    @State private var showClaudeForm = false
    @State private var key = ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Live Translate")
                .font(.largeTitle.bold())
            Text("Dịch trực tiếp tiếng Anh → tiếng Việt")
                .foregroundStyle(.secondary)

            VStack(spacing: 14) {
                if auth.googleNeedsKey {
                    Text("Đã đăng nhập Google: \(auth.userLabel)\nNhập Claude API key để tiếp tục.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                    keyForm(label: auth.userLabel)
                } else if showClaudeForm {
                    keyForm(label: "Claude")
                    Button("Quay lại") { showClaudeForm = false }
                        .font(.callout)
                } else {
                    Button {
                        auth.errorMessage = nil
                        showClaudeForm = true
                    } label: {
                        Label("Đăng nhập bằng Claude", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.85, green: 0.47, blue: 0.34))

                    Button {
                        Task { await auth.loginWithGoogle() }
                    } label: {
                        Label("Đăng nhập bằng Google", systemImage: "g.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .frame(maxWidth: 380)
            .disabled(auth.isWorking)

            if auth.isWorking { ProgressView() }

            if let error = auth.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func keyForm(label: String) -> some View {
        SecureField("Claude API key (sk-ant-…)", text: $key)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { submit(label) }
        Button {
            submit(label)
        } label: {
            Text("Đăng nhập").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func submit(_ label: String) {
        Task { await auth.loginWithClaude(key: key, label: label) }
    }
}
