import Foundation
import ReckonCore

enum AkahuCredentialImport {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--import-akahu-credentials") else { return }
        do {
            guard let data = try FileHandle.standardInput.readToEnd(), data.count <= 32_768 else {
                throw AkahuCredentialError.invalidTokens
            }
            let decoded = try JSONDecoder().decode(AkahuCredentials.self, from: data)
            let credentials = try AkahuCredentials(appToken: decoded.appToken, userToken: decoded.userToken)
            try AkahuKeychain.saveCredentials(credentials)
            print("Akahu credentials saved in Keychain.")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Could not import Akahu credentials. Check the input and Keychain access.\n".utf8))
            exit(1)
        }
    }
}
