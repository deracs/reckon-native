import Foundation
import LocalAuthentication
import ReckonCore

@MainActor
final class ReckonTouchID: ReckonAuthenticating {
    private var context: LAContext?

    func authenticate() async throws {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        self.context = context
        defer { if self.context === context { self.context = nil }; context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw touchIDError(error)
        }
        do {
            let authenticated = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                                 localizedReason: "show your balances and accounts")
            guard authenticated else {
                throw ReckonTouchIDError(message: "Touch ID could not unlock Reckon. Try again.")
            }
        } catch {
            throw touchIDError(error as NSError)
        }
    }

    func cancelAuthentication() {
        context?.invalidate()
        context = nil
    }

    private func touchIDError(_ error: NSError?) -> ReckonTouchIDError {
        guard let code = error.flatMap({ LAError.Code(rawValue: $0.code) }) else {
            return ReckonTouchIDError(message: "Touch ID could not unlock Reckon. Try again.")
        }
        let message: String
        switch code {
        case .biometryNotAvailable:
            message = "Touch ID is unavailable. Connect your Touch ID keyboard and try again."
        case .biometryNotEnrolled:
            message = "Add a fingerprint in System Settings → Touch ID & Password, then try again."
        case .biometryLockout:
            message = "Touch ID is locked. Unlock your Mac with its password, then try again."
        case .userCancel, .appCancel, .systemCancel:
            message = "Reckon is locked. Use Touch ID to open it."
        default:
            message = "Touch ID could not unlock Reckon. Try again."
        }
        return ReckonTouchIDError(message: message)
    }
}

private struct ReckonTouchIDError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Demo mode only displays fixtures and never reads Keychain or starts the backend.
@MainActor
final class ReckonDemoAuthentication: ReckonAuthenticating {
    func authenticate() async throws {}
    func cancelAuthentication() {}
}
