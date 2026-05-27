import Foundation

// MARK: - Notes for future providers
//
// Today the SDK has a single auth-bearing provider (Turnkey). The facade lives directly
// on `RainSDKManager` via the `RainSDKManager+TurnkeyAuth` extension. If a second
// auth-bearing provider lands and starts duplicating shape
// — config struct, state publisher, login/logout methods — extract a `RainAuthProvider`
// strategy protocol and let the manager hold one. Until then, keeping it inline is
// cheaper than abstracting an interface from a single concrete type.

// MARK: - Auth state

/// Authentication state for Turnkey-backed sessions.
///
/// Published via `RainSDKManager.authState` after `initializeTurnkey` has been called.
/// The wallet provider is bound automatically on `.authenticated` and cleared on `.unauthenticated`.
public enum RainAuthState: Sendable, Equatable {
  /// Initial state while the SDK restores any persisted session from the Keychain / Secure Enclave.
  case loading
  /// A valid session is active; wallet operations will succeed.
  case authenticated
  /// No active session; calls to wallet methods will throw `RainSDKError.walletUnavailable`.
  case unauthenticated
}

// MARK: - OTP

/// Contact channel for OTP-based authentication flows.
public enum RainOtpContact: Sendable, Equatable {
  case email(String)
  case sms(String)
}

/// Opaque handle returned by `initOtp` and consumed by `completeOtp`.
///
/// Hold this between the two calls; it carries the state needed to verify the code without
/// exposing Turnkey-internal types to the host.
public struct RainOtpHandle: Sendable {
  internal let otpId: String
  internal let otpEncryptionTargetBundle: String
  internal let contact: RainOtpContact

  internal init(
    otpId: String,
    otpEncryptionTargetBundle: String,
    contact: RainOtpContact
  ) {
    self.otpId = otpId
    self.otpEncryptionTargetBundle = otpEncryptionTargetBundle
    self.contact = contact
  }
}

// MARK: - OAuth

/// OAuth providers supported by Turnkey's Auth Proxy.
public enum RainOAuthProvider: Sendable, Equatable {
  case google
  case apple
  case discord
  case x
}
