import Combine
import Foundation
import CoreGraphics
import PortalSwift
import QRCode
import TurnkeySwift
import Web3
import Web3Core
import web3swift
import Web3ContractABI

public final class RainSDKManager: RainSDK {
  // MARK: - Properties

  // Provider storage. Typed as protocols so tests can inject mocks.
  internal var _portal: PortalRequestProtocol?
  internal var _turnkey: TurnkeyContextProtocol?

  /// Guards the mutable state below (`_walletProvider`, `_selectedWalletAddress`). Auth-state
  /// transitions arrive on the main queue while wallet methods may read from any executor —
  /// the lock provides happens-before between the writer and the reader.
  private let _stateLock = NSLock()
  private var __walletProvider: (any RainWalletProvider)?
  private var __selectedWalletAddress: String?

  /// Wallet provider for address, balance, signing, and submission.
  /// Set when `initializePortal` or `initializeTurnkey` is used; nil in wallet-agnostic mode.
  internal var _walletProvider: (any RainWalletProvider)? {
    get { _stateLock.lock(); defer { _stateLock.unlock() }; return __walletProvider }
    set { _stateLock.lock(); defer { _stateLock.unlock() }; __walletProvider = newValue }
  }

  private var _transactionBuilder: TransactionBuilderProtocol?

  private var _networkConfigs: [NetworkConfig] = []

  /// Subject mirroring the Turnkey auth state; published to host via `authState`.
  internal let _authStateSubject = CurrentValueSubject<RainAuthState, Never>(.unauthenticated)
  internal var _authStateCancellable: AnyCancellable?

  /// Host-selected wallet address (lowercased on read). `nil` falls back to the first
  /// Ethereum account in the Turnkey context.
  internal var _selectedWalletAddress: String? {
    get { _stateLock.lock(); defer { _stateLock.unlock() }; return __selectedWalletAddress }
    set { _stateLock.lock(); defer { _stateLock.unlock() }; __selectedWalletAddress = newValue }
  }

  /// Snapshot of the Turnkey config used the first time `initializeTurnkey` ran in this process.
  /// `TurnkeyContext.configure(_:)` can only be called once, so a second call with a different
  /// config throws.
  ///
  /// Invariant: all reads and writes must hold `_configureLock`. `nonisolated(unsafe)` suppresses
  /// Swift's concurrency checking, so any future access outside the lock would be a silent race.
  nonisolated(unsafe) private static var _configuredTurnkeySnapshot: RainTurnkeyConfig?
  private static let _configureLock = NSLock()

  /// Fallback Auth Proxy URL used when `RainTurnkeyConfig.authProxy` is `nil`. TurnkeySwift's
  /// `TurnkeyConfig.authProxyUrl` is non-optional, so passkey-only deployments still receive a
  /// concrete URL. Auth Proxy calls only happen for OTP / OAuth flows, so this URL is unused
  /// when the host stays on the passkey path.
  private static let defaultAuthProxyUrl = "https://authproxy.turnkey.com"
  
  /// Internal property for testing - returns PortalRequestProtocol which works with both Portal and MockPortal
  /// Use this property in tests when working with mocks
  internal var portalProtocol: PortalRequestProtocol? {
    return _portal
  }

  internal var turnkeyProtocol: TurnkeyContextProtocol? {
    return _turnkey
  }
  
  /// Internal: use for all Portal requests so that both Portal and MockPortal work in production and tests.
  /// Throws if SDK is not initialized.
  internal var portalForRequest: PortalRequestProtocol {
    get throws {
      guard let portal = _portal else { throw RainSDKError.sdkNotInitialized }
      return portal
    }
  }
  
  // MARK: - Initialization
  public init(
  ) {}
  
  /// Internal initializer for testing - allows injecting a custom transaction builder
  internal init(
    transactionBuilder: TransactionBuilderProtocol?
  ) {
    self._transactionBuilder = transactionBuilder
  }
  
  /// Internal initializer for testing - allows injecting both Portal and transaction builder
  internal init(
    portal: PortalRequestProtocol?,
    transactionBuilder: TransactionBuilderProtocol?
  ) {
    self._portal = portal
    self._turnkey = nil
    self._transactionBuilder = transactionBuilder
    self._walletProvider = portal.map {
      PortalWalletProviderAdapter(
        portal: $0,
        transactionBuilder: transactionBuilder
      )
    }
  }

  /// Internal initializer for testing - allows injecting Turnkey and transaction builder
  internal init(
    turnkey: TurnkeyContextProtocol?,
    transactionBuilder: TransactionBuilderProtocol?,
    networkConfigs: [NetworkConfig] = []
  ) {
    self._portal = nil
    self._turnkey = turnkey
    self._transactionBuilder = transactionBuilder
    self._networkConfigs = networkConfigs
    self._walletProvider = turnkey.map {
      TurnkeyWalletProviderAdapter(
        turnkey: $0,
        transactionBuilder: transactionBuilder,
        networkConfigs: networkConfigs
      )
    }
  }
  
  public func initializePortal(
    portalSessionToken: String,
    networkConfigs: [NetworkConfig]
  ) async throws {
    // Validate inputs
    try validateInputs(portalSessionToken: portalSessionToken, networkConfigs: networkConfigs)
    
    // Store network configs
    _networkConfigs = networkConfigs
    
    // Convert network configs to Portal format
    let eip155RpcEndpointsConfig = try buildRpcConfig(from: networkConfigs)
    
    do {
      // Initialize Portal instance
      let portal = try Portal(
        portalSessionToken,
        withRpcConfig: eip155RpcEndpointsConfig,
        autoApprove: true,
        iCloud: ICloudStorage(),
        keychain: PortalKeychain(),
        passwords: PasswordStorage()
      )
      
      // Store portal instance (Portal conforms to PortalProtocol via extension)
      _portal = portal
      _turnkey = nil
      // Initialize transaction builder service with network configs
      let transactionBuilder = TransactionBuilderService(networkConfigs: networkConfigs)
      _transactionBuilder = transactionBuilder
      _walletProvider = PortalWalletProviderAdapter(
        portal: portal,
        transactionBuilder: transactionBuilder
      )
      
      RainLogger.info("Rain SDK: Registered Portal instance successfully with \(networkConfigs.count) network(s)")
    } catch let error as RainSDKError {
      RainLogger.error("Rain SDK: Initialization error - \(error.localizedDescription)")
      throw error
    } catch {
      RainLogger.error("Rain SDK: Portal SDK error - \(error.localizedDescription)")
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Bootstraps Turnkey-backed authentication. The wallet provider is bound automatically
  /// once a session becomes active (either restored from the Keychain or via a fresh login);
  /// observe `authState` to drive UI.
  ///
  /// `TurnkeyContext.configure(_:)` is single-shot per process. Calling this twice with the
  /// same `config` is a no-op; calling with a different `config` throws.
  public func initializeTurnkey(
    config: RainTurnkeyConfig,
    networkConfigs: [NetworkConfig]
  ) async throws {
    try validateNetworkConfigs(networkConfigs)

    try Self.configureTurnkeyContextOnce(with: config)
    let context = TurnkeyContext.shared

    let transactionBuilder = TransactionBuilderService(networkConfigs: networkConfigs)

    _networkConfigs = networkConfigs
    _portal = nil
    _turnkey = context
    _transactionBuilder = transactionBuilder
    _walletProvider = nil

    bindTurnkeyAuthState(
      context: context,
      transactionBuilder: transactionBuilder,
      networkConfigs: networkConfigs
    )

    RainLogger.info("Rain SDK: Registered Turnkey context with \(networkConfigs.count) network(s); awaiting authentication")
  }

  private static func configureTurnkeyContextOnce(with config: RainTurnkeyConfig) throws {
    _configureLock.lock()
    defer { _configureLock.unlock() }

    if let existing = _configuredTurnkeySnapshot {
      guard existing == config else {
        throw RainSDKError.internalLogicError(
          details: "TurnkeyContext was already configured with a different config; restart the app to change Turnkey settings."
        )
      }
      return
    }

    let tkConfig = TurnkeyConfig(
      organizationId: config.organizationId,
      apiUrl: config.apiUrl,
      authProxyUrl: config.authProxy?.url ?? defaultAuthProxyUrl,
      authProxyConfigId: config.authProxy?.configId,
      rpId: config.passkey.rpId,
      auth: TurnkeyConfig.Auth(
        oauth: config.oauth.map {
          TurnkeyConfig.Auth.Oauth(redirectUri: nil, appScheme: $0.appScheme, providers: nil)
        },
        autoRefreshSession: nil,
        passkey: PasskeyOptionsPartial(
          passkeyName: nil,
          rpId: config.passkey.rpId,
          rpName: config.passkey.rpName
        ),
        createSuborgParams: nil
      ),
      autoRefreshManagedState: config.autoRefreshManagedState
    )

    TurnkeyContext.configure(tkConfig)
    _configuredTurnkeySnapshot = config
  }
  
  public func initialize(
    networkConfigs: [NetworkConfig]
  ) async throws {
    // Validate network configs
    try validateNetworkConfigs(networkConfigs)
    
    // Store network configs; no wallet provider in wallet-agnostic mode
    _networkConfigs = networkConfigs
    _portal = nil
    _turnkey = nil
    _walletProvider = nil
    
    // Initialize transaction builder service with network configs
    _transactionBuilder = TransactionBuilderService(networkConfigs: networkConfigs)
    
    RainLogger.info("Rain SDK: Initialized in wallet-agnostic mode with \(networkConfigs.count) network(s)")
  }

  public func setWalletProvider(_ provider: (any RainWalletProvider)?) {
    _walletProvider = provider
  }

  public func buildEIP712Message(
    chainId: Int,
    walletAddress: String,
    assetAddresses: EIP712AssetAddresses,
    amount: Double,
    decimals: Int,
    nonce: BigUInt?
  ) async throws -> (String, String) {
    // Ensure SDK is initialized with network configs
    guard let transactionBuilder = _transactionBuilder else {
      throw RainSDKError.sdkNotInitialized
    }
    
    // Generate or reuse salt (store internally for later use in transaction building)
    let salt = transactionBuilder.generateSalt()
    // Convert salt to hex string (bytes32 format)
    let saltHex = "0x" + salt.toHexString()
    
    // Get nonce - retrieve from network if not provided
    let finalNonce: BigUInt
    if let providedNonce = nonce {
      finalNonce = providedNonce
    } else {
      // Retrieve nonce from contract
      finalNonce = try await transactionBuilder.getLatestNonce(
        proxyAddress: assetAddresses.proxyAddress,
        chainId: chainId
      )
      RainLogger.debug("Rain SDK: Retrieved nonce \(finalNonce) from contract")
    }
    
    // Amount is already in smallest units (as per protocol documentation)
    // Convert Double to BigUInt
    let amountBaseUnits = try AmountHelpers.toBaseUnits(amount: amount, decimals: decimals)
    
    // Build EIP-712 message using service
    let jsonMessage = try transactionBuilder.buildEIP712Message(
      chainId: chainId,
      collateralProxyAddress: assetAddresses.proxyAddress,
      walletAddress: walletAddress,
      tokenAddress: assetAddresses.tokenAddress,
      amount: amountBaseUnits,
      recipientAddress: assetAddresses.recipientAddress,
      nonce: finalNonce,
      salt: saltHex
    )
    return (jsonMessage, saltHex)
  }
  
  public func buildWithdrawTransactionData(
    chainId: Int,
    assetAddresses: WithdrawAssetAddresses,
    amount: Double,
    decimals: Int,
    expiresAt: String,
    salt: Data,
    signatureData: Data,
    adminSalt: Data,
    adminSignature: Data
  ) async throws -> String {
    // Ensure SDK is initialized with network configs
    guard let transactionBuilder = _transactionBuilder else {
      throw RainSDKError.sdkNotInitialized
    }
    
    // Convert string addresses to Web3Core.EthereumAddress objects
    guard let ethereumContractAddress = Web3Core.EthereumAddress(assetAddresses.contractAddress),
          let ethereumProxyAddress = Web3Core.EthereumAddress(assetAddresses.proxyAddress),
          let ethereumTokenAddress = Web3Core.EthereumAddress(assetAddresses.tokenAddress),
          let ethereumRecipientAddress = Web3Core.EthereumAddress(assetAddresses.recipientAddress)
    else {
      RainLogger.error("Rain SDK: Error building transaction parameters for withdrawal. One of the addresses could not be built")
      throw RainSDKError.internalLogicError(
        details: "Error building transaction parameters for withdrawal. One of the addresses could not be built"
      )
    }
    
    // Convert the amount to base units using decimals of the token
    let amountBaseUnits = try AmountHelpers.toBaseUnits(amount: amount, decimals: decimals)
    
    // Convert the expiration timestamp string from Rain API to Unix Timestamp
    // Expects ISO8601 format or Unix timestamp string
    let unixTimestamp: Int
    if let timestamp = Int(expiresAt) {
      unixTimestamp = timestamp
    } else if let date = ISO8601DateFormatter().date(from: expiresAt) {
      unixTimestamp = Int(date.timeIntervalSince1970)
    } else {
      RainLogger.error("Rain SDK: Error building transaction parameters for withdrawal. Could not parse expiration to UNIX timestamp")
      throw RainSDKError.internalLogicError(
        details: "Invalid expiration timestamp format. Expected ISO8601 or Unix timestamp string"
      )
    }
    
    // Build WithdrawAssetParameter struct
    let withdrawAssetParameter = WithdrawAssetParameter(
      proxyAddress: ethereumProxyAddress,
      tokenAddress: ethereumTokenAddress,
      amount: amountBaseUnits,
      recipientAddress: ethereumRecipientAddress,
      expiryAt: BigUInt(unixTimestamp),
      salt: salt,
      signature: signatureData,
      adminSalt: adminSalt,
      adminSignature: adminSignature
    )
    
    // Build transaction data using service
    return try await transactionBuilder.buildErc20TransactionForWithdrawAsset(
      chainId: chainId,
      ethereumContractAddress: ethereumContractAddress,
      withdrawAssetParameter: withdrawAssetParameter
    )
  }
  
  public func composeTransactionParameters(
    walletAddress: String,
    contractAddress: String,
    transactionData: String
  ) -> ETHTransactionParam {
    return ETHTransactionParam(
      from: walletAddress,
      to: contractAddress,
      value: 0.ethToWei.toHexString,
      data: transactionData
    )
  }
  
  public func withdrawCollateral(
    chainId: Int,
    assetAddresses: WithdrawAssetAddresses,
    amount: Double,
    decimals: Int,
    salt: String,
    signature: String,
    expiresAt: String,
    nonce: BigUInt?
  ) async throws -> String {
    do {
      let (_, transactionParams) = try await buildTransactionParamForWithdrawAsset(
        chainId: chainId,
        assetAddresses: assetAddresses,
        amount: amount,
        decimals: decimals,
        salt: salt,
        signature: signature,
        expiresAt: expiresAt,
        nonce: nil
      )
      
      guard let provider = _walletProvider else {
        throw RainSDKError.sdkNotInitialized
      }

      let txHash = try await provider.sendTransaction(
        chainId: chainId,
        params: transactionParams
      )

      RainLogger.info("Rain SDK: Withdrawal transaction submitted. Hash: \(txHash)")
      return txHash
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }
  
  public func estimateWithdrawalFee(
    chainId: Int,
    addresses: WithdrawAssetAddresses,
    amount: Double,
    decimals: Int,
    salt: String,
    signature: String,
    expiresAt: String
  ) async throws -> Double {
    do {
      let (walletAddress, transactionParams) = try await buildTransactionParamForWithdrawAsset(
        chainId: chainId,
        assetAddresses: addresses,
        amount: amount,
        decimals: decimals,
        salt: salt,
        signature: signature,
        expiresAt: expiresAt,
        nonce: nil
      )
      return try await estimateTransactionFee(
        chainId: chainId,
        address: walletAddress,
        params: transactionParams
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  // MARK: - Wallet information

  /// Returns the current wallet address from the wallet provider.
  public func getWalletAddress(
  ) async throws -> String {
    do {
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }
      
      return try await provider.address()
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Generates a square QR code image (PNG) encoding the current wallet address.
  public func generateWalletAddressQRCode(
    dimension: Int = 256,
    backgroundColor: CGColor? = nil,
    foregroundColor: CGColor? = nil
  ) async throws -> Data {
    let address = try await getWalletAddress()
    let bg = backgroundColor ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    let fg = foregroundColor ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    
    guard let image = try? QRCode.build
      .text(address)
      .foregroundColor(fg)
      .backgroundColor(bg)
      .background.cornerRadius(0)
      .onPixels.shape(QRCode.PixelShape.RoundedPath(cornerRadiusFraction: 0))
      .eye.shape(QRCode.EyeShape.RoundedRect())
      .pupil.shape(QRCode.PupilShape.Square())
      .generate.image(dimension: dimension, representation: .png())
    else {
      throw RainSDKError.internalLogicError(details: "QR code image generation failed")
    }
    
    return image
  }

  // MARK: - Fetch balances

  /// Fetches the native token balance (e.g. ETH) for the current wallet on the given network via the wallet provider.
  public func getNativeBalance(
    chainId: Int
  ) async throws -> Double {
    do {
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }
      
      return try await provider.getNativeBalance(chainId: chainId)
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Fetches the ERC-20 balance for a single token via direct RPC `eth_call` (balanceOf).
  public func getERC20Balance(
    chainId: Int,
    tokenAddress: String,
    decimals: Int? = Constants.ERC20.defaultDecimals
  ) async throws -> Double {
    do {
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }

      return try await provider.getERC20Balance(
        chainId: chainId,
        tokenAddress: tokenAddress,
        decimals: decimals
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }
  
  /// Fetches ERC-20 token balances for the current wallet on the given network via the wallet provider.
  public func getERC20Balances(
    chainId: Int
  ) async throws -> [String: Double] {
    do {
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }
      
      return try await provider.getERC20Balances(chainId: chainId)
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Fetches all balances (native + ERC-20) for the current wallet via the wallet provider. Native balance is stored under key `""`.
  public func getBalances(
    chainId: Int
  ) async throws -> [String: Double] {
    do {
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }
      
      var result = try await provider.getERC20Balances(chainId: chainId)
      result[""] = try await provider.getNativeBalance(chainId: chainId)
      
      return result
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Fetches transaction history for the current wallet on the given network using Portal's `getTransactions` API via the wallet provider.
  public func getTransactions(
    chainId: Int,
    limit: Int? = nil,
    offset: Int? = nil,
    order: WalletTransactionOrder? = nil
  ) async throws -> [WalletTransaction] {
    do {
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }
      
      return try await provider.getTransactions(
        chainId: chainId,
        limit: limit,
        offset: offset,
        order: order
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  // MARK: - Send tokens

  /// Sends native tokens (e.g. ETH, AVAX). Requires a wallet provider (e.g. `initializePortal` or `setWalletProvider`).
  public func sendNativeToken(
    chainId: Int,
    to: String,
    amount: Double
  ) async throws -> String {
    do {
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }
      
      let from = try await provider.address()
      let params = WalletTransactionParams(
        from: from,
        to: to,
        value: amount.ethToWei.toHexString,
        data: .empty
      )
      
      return try await provider.sendTransaction(
        chainId: chainId,
        params: params
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }

  /// Sends ERC-20 tokens. Requires SDK initialized with network configs and a wallet provider.
  public func sendERC20Token(
    chainId: Int,
    contractAddress: String,
    to: String,
    amount: Double,
    decimals: Int
  ) async throws -> String {
    do {
      guard let transactionBuilder = _transactionBuilder else {
        throw RainSDKError.sdkNotInitialized
      }
      
      guard let provider = _walletProvider else {
        throw RainSDKError.walletUnavailable
      }
      
      let from = try await provider.address()
      let amountBaseUnits = try AmountHelpers.toBaseUnits(amount: amount, decimals: decimals)
      let data = try await transactionBuilder.buildERC20TransferData(
        chainId: chainId,
        contractAddress: contractAddress,
        walletAddress: from,
        toAddress: to,
        amount: amountBaseUnits
      )
      
      let params = WalletTransactionParams(
        from: from,
        to: contractAddress,
        value: 0.ethToWei.toHexString,
        data: data
      )
      
      return try await provider.sendTransaction(
        chainId: chainId,
        params: params
      )
    } catch {
      throw RainSDKError.from(underlying: error)
    }
  }
}
