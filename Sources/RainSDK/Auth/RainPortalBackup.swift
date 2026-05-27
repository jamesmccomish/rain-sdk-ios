import Foundation
import PortalSwift

/// Backup mechanism used to recover a Portal wallet. Pass to `recoverPortalWallet(...)`.
/// The raw values match the backend wire format (also used by `BackupMethods` in PortalSwift),
/// so host apps can send `method.rawValue` directly to APIs that expect this code.
public enum RainPortalBackupMethod: String, Sendable, Equatable, Codable {
  case iCloud = "ICLOUD"
  case password = "PASSWORD"
  case googleDrive = "GDRIVE"
  /// Portal's passkey-protected backup blob. Unrelated to the Turnkey passkey credential used
  /// for authentication — this enum drives Portal wallet recovery, not Turnkey login.
  case passkeyBackup = "PASSKEY"
  case local = "CUSTOM"

  internal var portalEquivalent: BackupMethods {
    switch self {
    case .iCloud:         return .iCloud
    case .password:       return .Password
    case .googleDrive:    return .GoogleDrive
    case .passkeyBackup:  return .Passkey
    case .local:          return .local
    }
  }
}

extension RainSDKManager {
  /// Recover a Portal wallet from a previously stored backup.
  ///
  /// - Parameters:
  ///   - method: How the backup was stored.
  ///   - cipherText: The encrypted backup payload (typically fetched from your backend).
  ///   - password: Required when `method == .password`; ignored otherwise.
  /// - Throws: `RainSDKError.sdkNotInitialized` if Portal wasn't initialized,
  ///           `RainSDKError.invalidArgument` if `method == .password` and `password` is `nil`,
  ///           `RainSDKError.providerError(underlying:)` for unmapped Portal failures.
  public func recoverPortalWallet(
    method: RainPortalBackupMethod,
    cipherText: String,
    password: String? = nil
  ) async throws {
    guard let portal = _portal as? Portal else {
      throw RainSDKError.sdkNotInitialized
    }

    if method == .password {
      guard let password else {
        throw RainSDKError.invalidArgument(details: "password is required when method == .password")
      }
      do {
        try portal.setPassword(password)
      } catch {
        throw RainSDKError.from(underlying: error)
      }
    }

    do {
      _ = try await portal.recoverWallet(
        method.portalEquivalent,
        withCipherText: cipherText,
        usingProgressCallback: { status in
          RainLogger.debug("Rain SDK: Portal recover status \(status)")
        }
      )
      RainLogger.info("Rain SDK: Portal wallet recovered")
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }
}
