import Foundation
import LocalAuthentication
import ReckonCore

/// macOS offers Touch ID, Apple Watch, or the Mac login password for each new session.
@MainActor
final class ReckonLocalAuthentication: ReckonAuthenticating {
    private var context: LAContext?

    func authenticate() async throws {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        self.context = context
        defer { if self.context === context { self.context = nil }; context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw authenticationError(error)
        }
        do {
            let authenticated: Bool = try await withCheckedThrowingContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication,
                                       localizedReason: "show your balances and accounts") { authenticated, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: authenticated) }
                }
            }
            guard authenticated else {
                throw ReckonAuthenticationError(message: "Could not unlock Reckon. Try again.")
            }
        } catch {
            throw authenticationError(error as NSError)
        }
    }

    func cancelAuthentication() {
        context?.invalidate()
        context = nil
    }

    private func authenticationError(_ error: NSError?) -> ReckonAuthenticationError {
        guard let error, error.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: error.code) else {
            return ReckonAuthenticationError(message: "Could not unlock Reckon. Try again.")
        }
        let message: String
        switch code {
        case .passcodeNotSet:
            message = "Set a Mac login password in System Settings, then try again."
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
            message = "Touch ID is unavailable. Try again and choose your Mac login password."
        case .userCancel, .appCancel, .systemCancel:
            message = "Reckon is locked. Unlock it to view your accounts."
        default:
            message = "Could not unlock Reckon. Try again."
        }
        return ReckonAuthenticationError(message: message)
    }
}

private struct ReckonAuthenticationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Demo mode only displays fixtures and never reads Keychain or starts the backend.
@MainActor
final class ReckonDemoAuthentication: ReckonAuthenticating {
    func authenticate() async throws {}
    func cancelAuthentication() {}
}
