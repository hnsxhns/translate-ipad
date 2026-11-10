import GoogleSignIn
import SwiftUI

@main
struct LiveTranslateApp: App {
    @State private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if let key = auth.apiKey {
                    MainView(auth: auth, session: LiveSession(apiKey: key))
                } else {
                    LoginView(auth: auth)
                }
            }
            .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}
