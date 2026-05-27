import Foundation
import RainSDK
import Combine
import AuthenticationServices

/// Wallet provider option when not in wallet-agnostic mode.
enum WalletProviderOption: String, CaseIterable {
  case portal = "Portal"
  case turnkey = "Turnkey"

  var displayName: String { rawValue }
}

/// ViewModel for SDK Connection View
/// Handles business logic and state management for SDK initialization
@MainActor
class SDKConnectionViewModel: ObservableObject {
  // MARK: - Dependencies

  private let sdkService: RainSDKService

  // MARK: - Published Properties

  /// Portal session token input
  @Published var sessionToken: String = ""

  /// RPC URL input
  @Published var rpcUrl: String = DemoLocalConfig.rpcUrl

  /// Chain ID input
  @Published var chainId: String = DemoLocalConfig.chainId

  /// Initialization mode: true for wallet-agnostic, false for Portal (or other provider)
  @Published var useWalletAgnostic: Bool = false

  /// Selected wallet provider when not wallet-agnostic
  @Published var selectedProvider: WalletProviderOption = .portal

  /// Initialization loading state
  @Published var isInitializing: Bool = false

  /// SDK initialization state (from service)
  @Published var isInitialized: Bool = false

  /// Current error state (from service)
  @Published var error: RainSDKError?

  /// Status message (from service)
  @Published var statusMessage: String = "Not initialized"

  // MARK: - Turnkey Inputs

  @Published var turnkeyOrgId: String = ""
  @Published var turnkeyApiUrl: String = TurnkeyConfigStorage.defaultApiUrl
  @Published var turnkeyAuthProxyUrl: String = TurnkeyConfigStorage.defaultAuthProxyUrl
  @Published var turnkeyAuthProxyConfigId: String = ""
  @Published var turnkeyRpId: String = ""

  /// True while a passkey authentication request is in flight.
  @Published var isAuthenticatingTurnkey: Bool = false

  // MARK: - Computed Properties

  /// Check if initialize button should be enabled
  var canInitialize: Bool {
    guard !isInitializing else { return false }
    guard !rpcUrl.isEmpty, !chainId.isEmpty, Int(chainId) != nil else { return false }

    if useWalletAgnostic { return true }

    switch selectedProvider {
    case .portal:
      return !sessionToken.isEmpty
    case .turnkey:
      // Turnkey has its own auth buttons (Login/Sign up with Passkey); the main
      // Initialize button is hidden in that flow.
      return false
    }
  }

  /// Whether the Login with Passkey button should be enabled.
  var canAuthenticateWithPasskey: Bool {
    !isAuthenticatingTurnkey
      && !isTrimmedEmpty(turnkeyOrgId)
      && !isTrimmedEmpty(turnkeyApiUrl)
      && !isTrimmedEmpty(turnkeyAuthProxyUrl)
      && !isTrimmedEmpty(turnkeyRpId)
      && !isTrimmedEmpty(chainId)
      && Int(chainId) != nil
      && !rpcUrl.isEmpty
  }

  /// Whether the Sign Up with Passkey button should be enabled.
  /// Signup creates a fresh sub-org under the parent org and additionally requires the auth proxy config id.
  var canSignUpWithPasskey: Bool {
    canAuthenticateWithPasskey && !isTrimmedEmpty(turnkeyAuthProxyConfigId)
  }

  // MARK: - Initialization

  init(sdkService: RainSDKService = .shared) {
    self.sdkService = sdkService
    self.sessionToken = PortalTokenStorage.getToken() ?? ""
    self.turnkeyOrgId = TurnkeyConfigStorage.organizationId
    self.turnkeyApiUrl = TurnkeyConfigStorage.apiUrl
    self.turnkeyAuthProxyUrl = TurnkeyConfigStorage.authProxyUrl
    self.turnkeyAuthProxyConfigId = TurnkeyConfigStorage.authProxyConfigId
    self.turnkeyRpId = TurnkeyConfigStorage.rpId

    // Observe service state changes
    observeServiceState()
  }

  // MARK: - Service State Observation

  private func observeServiceState() {
    // Observe isInitialized
    sdkService.$isInitialized
      .assign(to: &$isInitialized)

    // Observe error
    sdkService.$error
      .assign(to: &$error)

    // Observe statusMessage
    sdkService.$statusMessage
      .assign(to: &$statusMessage)
  }

  // MARK: - Actions

  /// Initialize the SDK with current input values (wallet-agnostic or Portal).
  /// Turnkey runs through `loginWithPasskey` / `signUpWithPasskey` instead.
  func initializeSDK() async {
    guard let chainIdInt = Int(chainId) else {
      return
    }

    isInitializing = true

    let networkConfigs = makeNetworkConfigs(chainIdInt: chainIdInt)

    if useWalletAgnostic {
      await sdkService.initializeWalletAgnostic(networkConfigs: networkConfigs)
    } else if selectedProvider == .portal {
      PortalTokenStorage.saveToken(sessionToken)
      await sdkService.initialize(
        portalToken: sessionToken,
        networkConfigs: networkConfigs
      )
    }

    isInitializing = false
  }

  /// Reset the SDK state. Note: `initializeTurnkey` runs `TurnkeyContext.configure(...)`
  /// internally, which is one-shot per process — editing org/rpId/etc. and retrying will
  /// surface an `internalLogicError` until the app is relaunched.
  func resetSDK() {
    sdkService.reset()
  }

  // MARK: - Turnkey Passkey

  /// Sign in to Turnkey with an existing passkey via Rain's facade.
  func loginWithTurnkeyPasskey(anchor: ASPresentationAnchor) async {
    guard canAuthenticateWithPasskey else { return }
    await runTurnkeyPasskeyFlow(anchor: anchor, statusMessage: "Authenticating with passkey...") { service, anchor in
      await service.loginWithPasskey(anchor: anchor)
    }
  }

  /// Create a fresh Turnkey sub-org and register a passkey for it on the device.
  func signUpWithTurnkeyPasskey(anchor: ASPresentationAnchor) async {
    guard canSignUpWithPasskey else { return }
    await runTurnkeyPasskeyFlow(anchor: anchor, statusMessage: "Registering passkey...") { service, anchor in
      await service.signUpWithPasskey(anchor: anchor)
    }
  }

  private func runTurnkeyPasskeyFlow(
    anchor: ASPresentationAnchor,
    statusMessage: String,
    action: (RainSDKService, ASPresentationAnchor) async -> Void
  ) async {
    guard let chainIdInt = Int(chainId) else { return }
    guard let config = makeRainTurnkeyConfig() else {
      sdkService.error = .internalLogicError(details: "Missing Turnkey configuration.")
      return
    }

    persistTurnkeyConfig()
    isAuthenticatingTurnkey = true
    sdkService.statusMessage = statusMessage
    sdkService.error = nil

    await sdkService.initializeTurnkey(
      config: config,
      networkConfigs: makeNetworkConfigs(chainIdInt: chainIdInt)
    )

    if sdkService.error == nil {
      await action(sdkService, anchor)
    }

    isAuthenticatingTurnkey = false
  }

  // MARK: - Turnkey Configuration

  private func makeRainTurnkeyConfig() -> RainTurnkeyConfig? {
    let orgId = turnkeyOrgId.trimmingCharacters(in: .whitespacesAndNewlines)
    let apiUrl = turnkeyApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let authProxyUrl = turnkeyAuthProxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let authProxyConfigId = turnkeyAuthProxyConfigId.trimmingCharacters(in: .whitespacesAndNewlines)
    let rpId = turnkeyRpId.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !orgId.isEmpty, !apiUrl.isEmpty, !authProxyUrl.isEmpty, !rpId.isEmpty else {
      return nil
    }

    let authProxy = authProxyConfigId.isEmpty
      ? nil
      : RainTurnkeyConfig.AuthProxy(url: authProxyUrl, configId: authProxyConfigId)

    return RainTurnkeyConfig(
      organizationId: orgId,
      apiUrl: apiUrl,
      authProxy: authProxy,
      passkey: .init(rpId: rpId)
    )
  }

  private func persistTurnkeyConfig() {
    TurnkeyConfigStorage.organizationId = turnkeyOrgId
    TurnkeyConfigStorage.apiUrl = turnkeyApiUrl
    TurnkeyConfigStorage.authProxyUrl = turnkeyAuthProxyUrl
    TurnkeyConfigStorage.authProxyConfigId = turnkeyAuthProxyConfigId
    TurnkeyConfigStorage.rpId = turnkeyRpId
  }

  private func makeNetworkConfigs(chainIdInt: Int) -> [NetworkConfig] {
    [
      NetworkConfig(
        chainId: chainIdInt,
        rpcUrl: rpcUrl,
        networkName: "Demo Network"
      )
    ]
  }

  private func isTrimmedEmpty(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Future Feature Actions

  /// Handle Portal wallet features action
  /// TODO: Implement Portal wallet features
  func handlePortalWalletFeatures() {
    // Future implementation
  }

  /// Handle collateral withdrawal action
  /// TODO: Implement collateral withdrawal
  func handleCollateralWithdrawal() {
    // Future implementation
  }

  /// Handle fee estimation action
  /// TODO: Implement fee estimation
  func handleFeeEstimation() {
    // Future implementation
  }
}
