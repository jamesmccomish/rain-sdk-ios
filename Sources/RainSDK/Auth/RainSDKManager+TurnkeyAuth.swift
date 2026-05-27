import AuthenticationServices
import Combine
import Foundation
import TurnkeySwift
import TurnkeyTypes

extension RainSDKManager {
  // MARK: - Auth state observation

  /// Current Turnkey authentication state. Mirrors `TurnkeyContext.authState`.
  ///
  /// Returns `.unauthenticated` until `initializeTurnkey` has been called.
  public var currentAuthState: RainAuthState {
    _authStateSubject.value
  }

  /// Publishes Turnkey authentication state transitions. Subscribe to drive UI and
  /// know when wallet operations will succeed.
  public var authState: AnyPublisher<RainAuthState, Never> {
    _authStateSubject.eraseToAnyPublisher()
  }

  /// Test hook: installs a Turnkey context + transaction builder and wires the auth-state
  /// subscription without going through `initializeTurnkey` (which would call
  /// `TurnkeyContext.configure(_:)`). Production code should never call this.
  internal func installTurnkeyForTesting(
    _ context: TurnkeyContextProtocol,
    transactionBuilder: TransactionBuilderProtocol,
    networkConfigs: [NetworkConfig]
  ) {
    _turnkey = context
    _walletProvider = nil
    bindTurnkeyAuthState(
      context: context,
      transactionBuilder: transactionBuilder,
      networkConfigs: networkConfigs
    )
  }

  /// Subscribes to the Turnkey context's `authState` publisher and (a) mirrors transitions onto
  /// `_authStateSubject` and (b) binds / unbinds the wallet provider as the state changes.
  internal func bindTurnkeyAuthState(
    context: TurnkeyContextProtocol,
    transactionBuilder: TransactionBuilderProtocol,
    networkConfigs: [NetworkConfig]
  ) {
    _authStateCancellable?.cancel()

    _authStateCancellable = context.authStatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] turnkeyState in
        guard let self else { return }
        self.handleTurnkeyAuthStateChange(
          turnkeyState,
          context: context,
          transactionBuilder: transactionBuilder,
          networkConfigs: networkConfigs
        )
      }
  }

  private func handleTurnkeyAuthStateChange(
    _ state: AuthState,
    context: TurnkeyContextProtocol,
    transactionBuilder: TransactionBuilderProtocol,
    networkConfigs: [NetworkConfig]
  ) {
    switch state {
    case .authenticated:
      _walletProvider = TurnkeyWalletProviderAdapter(
        turnkey: context,
        transactionBuilder: transactionBuilder,
        networkConfigs: networkConfigs,
        selectedAddressProvider: { [weak self] in self?._selectedWalletAddress }
      )
      _authStateSubject.send(.authenticated)
      RainLogger.info("Rain SDK: Turnkey session authenticated; wallet provider bound")

    case .unAuthenticated:
      _walletProvider = nil
      _authStateSubject.send(.unauthenticated)
      RainLogger.info("Rain SDK: Turnkey session ended; wallet provider cleared")

    case .loading:
      _authStateSubject.send(.loading)
    }
  }

  // MARK: - Auth methods (passkey)

  /// Logs in an existing user using a registered passkey. On success the SDK observes the
  /// resulting `.authenticated` state, binds the wallet provider, and publishes via `authState`.
  ///
  /// - Parameters:
  ///   - anchor: Presentation anchor (typically the active `UIWindow`) for the system passkey UI.
  ///   - expirationSeconds: Optional session lifetime. Defaults to the value supplied at
  ///     `initializeTurnkey` or Turnkey's 900s default.
  public func loginWithPasskey(
    anchor: ASPresentationAnchor,
    expirationSeconds: Int? = nil
  ) async throws {
    let context = try requireTurnkeyContext()
    do {
      _ = try await context.loginWithPasskey(
        anchor: anchor,
        expirationSeconds: resolvedExpirationSeconds(expirationSeconds)
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Signs up a new user with a freshly created passkey. On success the resulting session is
  /// activated, the wallet provider is bound, and `authState` publishes `.authenticated`.
  ///
  /// Sub-organization and wallet provisioning for the new user is performed by the Turnkey
  /// Auth Proxy (`RainTurnkeyConfig.authProxy`); the proxy must be configured to create an
  /// `ADDRESS_FORMAT_ETHEREUM` wallet on signup. Hosts that need a custom sub-org payload
  /// should run the Turnkey sign-up flow directly and bind via `setWalletProvider`.
  public func signUpWithPasskey(
    anchor: ASPresentationAnchor,
    displayName: String? = nil,
    expirationSeconds: Int? = nil
  ) async throws {
    let context = try requireTurnkeyContext()
    do {
      _ = try await context.signUpWithPasskey(
        anchor: anchor,
        passkeyDisplayName: displayName,
        expirationSeconds: resolvedExpirationSeconds(expirationSeconds)
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  // MARK: - Auth methods (OTP)

  /// Initiates an OTP login flow (email or SMS). Hold the returned handle and pass it to
  /// `completeOtp` along with the code the user receives.
  public func initOtp(contact: RainOtpContact) async throws -> RainOtpHandle {
    let context = try requireTurnkeyContext()
    do {
      let (contactString, otpType) = otpInputs(for: contact)
      let result = try await context.initOtp(contact: contactString, otpType: otpType)
      return RainOtpHandle(
        otpId: result.otpId,
        otpEncryptionTargetBundle: result.otpEncryptionTargetBundle,
        contact: contact
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Completes an OTP flow with the code the user entered. On success the session activates
  /// and the wallet provider is bound automatically.
  public func completeOtp(handle: RainOtpHandle, code: String) async throws {
    let context = try requireTurnkeyContext()
    do {
      let (contactString, otpType) = otpInputs(for: handle.contact)
      _ = try await context.completeOtp(
        otpId: handle.otpId,
        otpCode: code,
        otpEncryptionTargetBundle: handle.otpEncryptionTargetBundle,
        contact: contactString,
        otpType: otpType
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  // MARK: - Auth methods (OAuth)

  /// Runs the OAuth flow for the given provider. Apple sign-in uses the system sheet and does
  /// not require an anchor; all other providers do.
  public func loginWithOAuth(
    provider: RainOAuthProvider,
    anchor: ASPresentationAnchor? = nil
  ) async throws {
    let context = try requireTurnkeyContext()
    do {
      switch provider {
      case .google:
        guard let anchor else { throw RainSDKError.invalidArgument(details: "Google OAuth requires a presentation anchor") }
        try await context.handleGoogleOAuth(anchor: anchor)
      case .apple:
        try await context.handleAppleOAuth()
      case .discord:
        guard let anchor else { throw RainSDKError.invalidArgument(details: "Discord OAuth requires a presentation anchor") }
        try await context.handleDiscordOAuth(anchor: anchor)
      case .x:
        guard let anchor else { throw RainSDKError.invalidArgument(details: "X OAuth requires a presentation anchor") }
        try await context.handleXOauth(anchor: anchor)
      }
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  // MARK: - Wallet selection

  /// All usable Ethereum wallets available from the active Turnkey session, one per address.
  ///
  /// Refreshes the Turnkey wallet list first, so call this after `.authenticated` to get the
  /// freshest view. Returns an empty array when no session is active.
  public func availableTurnkeyWallets() async throws -> [RainWallet] {
    let context = try requireTurnkeyContext()
    do {
      try await context.refreshWallets()
    } catch {
      throw RainSDKError.from(underlying: error)
    }

    return context.wallets.flatMap { wallet in
      wallet.accounts
        .filter { $0.addressFormat == .address_format_ethereum }
        .map { RainWallet(address: $0.address, walletId: wallet.walletId, walletName: wallet.walletName) }
    }
  }

  /// The address the SDK will use for wallet operations. `nil` means "first Ethereum
  /// account from the Turnkey context" (the default).
  public var selectedWalletAddress: String? {
    _selectedWalletAddress
  }

  /// Choose which wallet the SDK should sign with. Pass an address from `availableTurnkeyWallets()`
  /// (case-insensitive). Pass `nil` to clear the selection and revert to the default.
  ///
  /// - Throws: `RainSDKError.walletUnavailable` if `address` is not among the available wallets.
  public func selectWallet(address: String?) async throws {
    guard let address else {
      _selectedWalletAddress = nil
      return
    }

    let wallets = try await availableTurnkeyWallets()
    let normalized = address.lowercased()
    guard wallets.contains(where: { $0.address.lowercased() == normalized }) else {
      throw RainSDKError.walletUnavailable
    }
    _selectedWalletAddress = address
  }

  // MARK: - Sign out

  /// Clears the active Turnkey session. The auth state observer publishes `.unauthenticated`
  /// and clears the wallet provider.
  public func signOut() {
    _turnkey?.clearSession(for: nil)
  }

  // MARK: - Helpers

  private func requireTurnkeyContext() throws -> TurnkeyContextProtocol {
    guard let context = _turnkey else {
      throw RainSDKError.sdkNotInitialized
    }
    return context
  }

  private func resolvedExpirationSeconds(_ override: Int?) -> String? {
    override.map(String.init)
  }

  private func otpInputs(for contact: RainOtpContact) -> (String, OtpType) {
    switch contact {
    case .email(let value): return (value, .email)
    case .sms(let value): return (value, .sms)
    }
  }
}
