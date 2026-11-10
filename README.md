# Live Translate (iPad)

Nghe tiếng Anh qua micro → khung **trái** hiện chữ tiếng Anh liên tục → khung **phải** hiện bản dịch tiếng Việt → khung **dưới** (cao 1/4) tóm tắt ý chính bằng tiếng Việt. Một nút **ON/OFF** ở góc phải thanh trên cùng.

Cửa sổ thay đổi kích thước được (Split View / Stage Manager); bố cục tự co giãn.

## Đăng nhập (2 cách)

| Cách | Hoạt động thế nào |
|---|---|
| **Đăng nhập bằng Claude** | Nhập Claude API key (tạo tại https://console.anthropic.com bằng tài khoản Claude). App gọi thử API: đúng thì vào, sai thì báo lỗi. |
| **Đăng nhập bằng Google** | Đăng nhập Google chuẩn (Google Sign-In). Sau đó app dùng Claude API key được gắn sẵn lúc build (secret `CLAUDE_API_KEY`). Nếu bản build không có key, app hỏi nhập key một lần. |

> Anthropic không cho app bên ngoài đăng nhập bằng tài khoản claude.ai (không có "Sign in with Claude" công khai), nên "đăng nhập bằng Claude" = Claude API key của tài khoản Claude Console.
> Theo yêu cầu bỏ qua bảo mật: key lưu trong UserDefaults và key gắn sẵn nằm trong Info.plist của app. Chỉ dùng cho TestFlight nội bộ.

## Đưa lên TestFlight nhanh (không cần Mac — build trên GitHub Actions)

### Chuẩn bị một lần (~15 phút)

1. **Apple Developer** (tài khoản trả phí):
   - App Store Connect → *Apps* → **+ New App** → nền tảng iOS, chọn Bundle ID mới, ví dụ `com.tencuaban.livetranslate` (nếu chưa có thì tạo ở developer.apple.com → Identifiers).
   - App Store Connect → *Users and Access* → *Integrations* → **App Store Connect API** → tạo key quyền **Admin**. Tải file `AuthKey_XXXX.p8`, ghi lại **Key ID** và **Issuer ID**.
   - Team ID: developer.apple.com → *Membership*.
2. **Google** (chỉ cần nếu dùng đăng nhập Google): Google Cloud Console → *APIs & Services* → *Credentials* → **OAuth client ID** loại **iOS**, nhập Bundle ID ở trên. Ghi lại **Client ID** và **iOS URL scheme** (dạng `com.googleusercontent.apps.xxxx`).
3. **GitHub**: tạo repo, đẩy thư mục này lên nhánh `main`. Vào *Settings → Secrets and variables → Actions*:

   | Loại | Tên | Giá trị |
   |---|---|---|
   | Secret | `ASC_KEY_P8_BASE64` | nội dung file .p8 mã hoá base64 (lệnh bên dưới) |
   | Secret | `ASC_KEY_ID` | Key ID |
   | Secret | `ASC_ISSUER_ID` | Issuer ID |
   | Secret | `TEAM_ID` | Team ID |
   | Secret | `CLAUDE_API_KEY` | Claude API key dùng cho đăng nhập Google (tuỳ chọn) |
   | Variable | `BUNDLE_ID` | ví dụ `com.tencuaban.livetranslate` |
   | Variable | `GOOGLE_CLIENT_ID` | Google Client ID (tuỳ chọn) |
   | Variable | `GOOGLE_REVERSED_CLIENT_ID` | iOS URL scheme của Google (tuỳ chọn) |

   Mã hoá file .p8 trên Windows (PowerShell):

   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXX.p8")) | Set-Clipboard
   ```

### Mỗi lần build

Push lên `main` (hoặc tab *Actions* → **TestFlight** → *Run workflow*). Khoảng 10–15 phút sau bản build xuất hiện trong App Store Connect → TestFlight (Apple xử lý thêm vài phút). Số build tự tăng theo lần chạy. App đã khai báo không dùng mã hoá đặc biệt nên không bị hỏi Export Compliance.

## Build trên Mac (nếu có)

```bash
brew install xcodegen && python3 scripts/make_icon.py LiveTranslate/Assets.xcassets/AppIcon.appiconset/icon-1024.png && xcodegen generate && open LiveTranslate.xcodeproj
```

Chọn Team ở *Signing & Capabilities*, cắm iPad, bấm Run. Nên chạy trên máy thật (Simulator thu micro không ổn định).

## Cấu trúc code

| File | Vai trò |
|---|---|
| `LiveTranslate/SpeechEngine.swift` | Nhận diện tiếng Anh liên tục (Apple Speech, `en-US`, có dấu câu). Cắt đoạn khi ngừng nói 1,3 giây hoặc sau 25 giây, mở ngay đoạn mới nên không mất âm thanh. |
| `LiveTranslate/LiveSession.swift` | Mỗi đoạn tiếng Anh → dịch bằng Claude (kèm 3 đoạn trước làm ngữ cảnh), stream, giữ đúng thứ tự. Tóm tắt ý chính tối đa mỗi 15 giây và lần cuối khi bấm OFF. |
| `LiveTranslate/ClaudeClient.swift` | Gọi Claude Messages API qua HTTP + streaming. Model `claude-opus-5-5` (dịch: effort `low`, tóm tắt: `medium`), tự chuyển model dự phòng nếu bị từ chối. |
| `LiveTranslate/AuthStore.swift`, `LoginView.swift` | Đăng nhập Claude / Google. |
| `LiveTranslate/MainView.swift` | Thanh trên + nút ON/OFF, 2 khung trái/phải (3/4 chiều cao), khung ý chính (1/4). |
| `project.yml` | Cấu hình XcodeGen (sinh file Xcode). |
| `.github/workflows/testflight.yml` | Build + ký + đẩy lên TestFlight. |

Muốn dịch nhanh và rẻ hơn: đổi `ClaudeClient.model` thành `"claude-haiku-5-5"` (chất lượng dịch hơi kém hơn).
