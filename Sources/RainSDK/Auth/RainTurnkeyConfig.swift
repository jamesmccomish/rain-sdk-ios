import Foundation

/// Bootstrap configuration for Turnkey-backed authentication.
///
/// Passed to `RainSDKManager.initializeTurnkey(config:networkConfigs:)`. The SDK calls
/// `TurnkeyContext.configure(_:)` exactly once per process from these values, so a second
/// `initializeTurnkey` call with a different config will throw.
public struct RainTurnkeyConfig: Sendable {
  public struct AuthProxy: Sendable {
    /// Auth Proxy base URL. Defaults to Turnkey's hosted Auth Proxy.
    public var url: String
    /// Auth Proxy configuration id (from the Turnkey dashboard).
    public var configId: String

    public init(url: String, configId: String) {
      self.url = url
      self.configId = configId
    }
  }

  public struct Passkey: Sendable {
    /// Relying-party identifier — must match an `webcredentials:` Associated Domain in the host app.
    public var rpId: String
    /// Optional human-readable relying-party name shown by the system passkey UI.
    public var rpName: String?

    public init(rpId: String, rpName: String? = nil) {
      self.rpId = rpId
      self.rpName = rpName
    }
  }

  public struct OAuth: Sendable {
    /// Host app URL scheme used for OAuth redirect callbacks (e.g. `"myapp"`).
    public var appScheme: String

    public init(appScheme: String) {
      self.appScheme = appScheme
    }
  }

  public var organizationId: String
  public var apiUrl: String
  public var authProxy: AuthProxy?
  public var passkey: Passkey
  public var oauth: OAuth?
  public var autoRefreshManagedState: Bool
  public var defaultSessionExpirationSeconds: Int?

  public init(
    organizationId: String,
    apiUrl: String,
    authProxy: AuthProxy? = nil,
    passkey: Passkey,
    oauth: OAuth? = nil,
    autoRefreshManagedState: Bool = true,
    defaultSessionExpirationSeconds: Int? = nil
  ) {
    self.organizationId = organizationId
    self.apiUrl = apiUrl
    self.authProxy = authProxy
    self.passkey = passkey
    self.oauth = oauth
    self.autoRefreshManagedState = autoRefreshManagedState
    self.defaultSessionExpirationSeconds = defaultSessionExpirationSeconds
  }
}

extension RainTurnkeyConfig: Equatable {
  public static func == (lhs: RainTurnkeyConfig, rhs: RainTurnkeyConfig) -> Bool {
    lhs.organizationId == rhs.organizationId
      && lhs.apiUrl == rhs.apiUrl
      && lhs.authProxy?.url == rhs.authProxy?.url
      && lhs.authProxy?.configId == rhs.authProxy?.configId
      && lhs.passkey.rpId == rhs.passkey.rpId
      && lhs.passkey.rpName == rhs.passkey.rpName
      && lhs.oauth?.appScheme == rhs.oauth?.appScheme
      && lhs.autoRefreshManagedState == rhs.autoRefreshManagedState
      && lhs.defaultSessionExpirationSeconds == rhs.defaultSessionExpirationSeconds
  }
}
