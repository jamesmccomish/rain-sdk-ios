import AuthenticationServices
import Combine
import Foundation
import TurnkeyHttp
import TurnkeySwift
import TurnkeyTypes

internal protocol TurnkeyClientProtocol {
  func getWalletAddressBalances(
    _ input: TGetWalletAddressBalancesBody
  ) async throws -> TGetWalletAddressBalancesResponse

  func ethSendTransaction(
    _ input: TEthSendTransactionBody
  ) async throws -> TEthSendTransactionResponse

  func getSendTransactionStatus(
    _ input: TGetSendTransactionStatusBody
  ) async throws -> TGetSendTransactionStatusResponse

  func getActivities(
    _ input: TGetActivitiesBody
  ) async throws -> TGetActivitiesResponse
}

extension TurnkeyClient: TurnkeyClientProtocol {}

internal protocol TurnkeyContextProtocol: AnyObject {
  var wallets: [Wallet] { get }
  var session: Session? { get }
  var turnkeyClient: (any TurnkeyClientProtocol)? { get }

  var authState: AuthState { get }
  var authStatePublisher: AnyPublisher<AuthState, Never> { get }

  func refreshWallets() async throws

  func signRawPayload(
    signWith: String,
    payload: String,
    encoding: PayloadEncoding,
    hashFunction: HashFunction
  ) async throws -> SignRawPayloadResult

  @discardableResult
  func loginWithPasskey(
    anchor: ASPresentationAnchor,
    expirationSeconds: String?
  ) async throws -> PasskeyAuthResult

  @discardableResult
  func signUpWithPasskey(
    anchor: ASPresentationAnchor,
    passkeyDisplayName: String?,
    expirationSeconds: String?
  ) async throws -> PasskeyAuthResult

  func initOtp(
    contact: String,
    otpType: OtpType
  ) async throws -> InitOtpResult

  @discardableResult
  func completeOtp(
    otpId: String,
    otpCode: String,
    otpEncryptionTargetBundle: String,
    contact: String,
    otpType: OtpType
  ) async throws -> CompleteOtpResult

  func handleGoogleOAuth(anchor: ASPresentationAnchor) async throws
  func handleAppleOAuth() async throws
  func handleDiscordOAuth(anchor: ASPresentationAnchor) async throws
  func handleXOauth(anchor: ASPresentationAnchor) async throws

  func clearSession(for sessionKey: String?)
}

extension TurnkeyContext: TurnkeyContextProtocol {
  internal var turnkeyClient: (any TurnkeyClientProtocol)? {
    client
  }

  internal var authStatePublisher: AnyPublisher<AuthState, Never> {
    $authState.eraseToAnyPublisher()
  }

  @discardableResult
  internal func loginWithPasskey(
    anchor: ASPresentationAnchor,
    expirationSeconds: String?
  ) async throws -> PasskeyAuthResult {
    try await loginWithPasskey(
      anchor: anchor,
      publicKey: nil,
      organizationId: nil,
      expirationSeconds: expirationSeconds,
      sessionKey: nil
    )
  }

  @discardableResult
  internal func signUpWithPasskey(
    anchor: ASPresentationAnchor,
    passkeyDisplayName: String?,
    expirationSeconds: String?
  ) async throws -> PasskeyAuthResult {
    try await signUpWithPasskey(
      anchor: anchor,
      passkeyDisplayName: passkeyDisplayName,
      challenge: nil,
      expirationSeconds: expirationSeconds,
      createSubOrgParams: nil,
      sessionKey: nil
    )
  }

  @discardableResult
  internal func completeOtp(
    otpId: String,
    otpCode: String,
    otpEncryptionTargetBundle: String,
    contact: String,
    otpType: OtpType
  ) async throws -> CompleteOtpResult {
    try await completeOtp(
      otpId: otpId,
      otpCode: otpCode,
      otpEncryptionTargetBundle: otpEncryptionTargetBundle,
      contact: contact,
      otpType: otpType,
      publicKey: nil,
      createSubOrgParams: nil,
      invalidateExisting: false,
      sessionKey: nil
    )
  }

  internal func handleGoogleOAuth(anchor: ASPresentationAnchor) async throws {
    try await handleGoogleOAuth(
      anchor: anchor,
      clientId: nil,
      secondaryClientIds: nil,
      sessionKey: nil,
      additionalState: nil,
      onOAuthSuccess: nil
    )
  }

  internal func handleAppleOAuth() async throws {
    try await handleAppleOAuth(
      secondaryClientIds: nil,
      sessionKey: nil,
      onOAuthSuccess: nil
    )
  }

  internal func handleDiscordOAuth(anchor: ASPresentationAnchor) async throws {
    try await handleDiscordOAuth(
      anchor: anchor,
      clientId: nil,
      secondaryClientIds: nil,
      sessionKey: nil,
      additionalState: nil,
      onOAuthSuccess: nil
    )
  }

  internal func handleXOauth(anchor: ASPresentationAnchor) async throws {
    try await handleXOauth(
      anchor: anchor,
      clientId: nil,
      secondaryClientIds: nil,
      sessionKey: nil,
      additionalState: nil,
      onOAuthSuccess: nil
    )
  }

}
