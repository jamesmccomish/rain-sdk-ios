import AuthenticationServices
import Testing
import Foundation
import TurnkeySwift
import UIKit
@testable import RainSDK

@Suite("Turnkey Auth Facade Tests", .serialized)
struct TurnkeyAuthFacadeTests {

  // MARK: - Auth-state observation drives wallet provider lifecycle

  @Test("when authState transitions to .authenticated the wallet provider is bound")
  func testBindOnAuthenticated() async throws {
    let turnkey = MockTurnkey(authState: .unAuthenticated)
    let manager = makeManager(turnkey: turnkey)

    await #expect(throws: RainSDKError.walletUnavailable) {
      _ = try await manager.getWalletAddress()
    }

    turnkey.setAuthState(.authenticated)
    try await waitForAuthState(.authenticated, on: manager)

    let address = try await manager.getWalletAddress()
    #expect(address == MockTurnkey.defaultWalletAddress)
  }

  @Test("when authState transitions to .unAuthenticated the wallet provider is cleared")
  func testUnbindOnUnauthenticated() async throws {
    let turnkey = MockTurnkey(authState: .authenticated)
    let manager = makeManager(turnkey: turnkey)
    try await waitForAuthState(.authenticated, on: manager)

    _ = try await manager.getWalletAddress()

    turnkey.setAuthState(.unAuthenticated)
    try await waitForAuthState(.unauthenticated, on: manager)

    await #expect(throws: RainSDKError.walletUnavailable) {
      _ = try await manager.getWalletAddress()
    }
  }

  @Test("currentAuthState mirrors Turnkey authState transitions")
  func testCurrentAuthStateMirrorsTurnkey() async throws {
    let turnkey = MockTurnkey(authState: .loading)
    let manager = makeManager(turnkey: turnkey)
    try await waitForAuthState(.loading, on: manager)
    #expect(manager.currentAuthState == .loading)

    turnkey.setAuthState(.authenticated)
    try await waitForAuthState(.authenticated, on: manager)
    #expect(manager.currentAuthState == .authenticated)

    turnkey.setAuthState(.unAuthenticated)
    try await waitForAuthState(.unauthenticated, on: manager)
    #expect(manager.currentAuthState == .unauthenticated)
  }

  /// Builds a manager wired to a mock Turnkey context via the test-only `installTurnkeyForTesting`
  /// hook. The wallet provider is left unbound; transitions on `MockTurnkey.setAuthState(_:)`
  /// drive the bind / unbind path under test.
  private func makeManager(turnkey: MockTurnkey) -> RainSDKManager {
    let configs = TestFixtures.configs()
    let manager = RainSDKManager()
    manager.installTurnkeyForTesting(
      turnkey,
      transactionBuilder: MockTransactionBuilderService(networkConfigs: configs),
      networkConfigs: configs
    )
    return manager
  }

  // MARK: - Facade auth methods delegate to the context and map errors

  @Test("loginWithPasskey delegates to the Turnkey context")
  func testLoginWithPasskeyDelegates() async throws {
    let turnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey)
    let anchor = await makeAnchor()

    try await manager.loginWithPasskey(anchor: anchor)
    #expect(turnkey.loginWithPasskeyCallCount == 1)
  }

  @Test("loginWithPasskey surfaces invalidSession as .tokenExpired")
  func testLoginWithPasskeyMapsInvalidSession() async throws {
    let turnkey = MockTurnkey()
    turnkey.loginWithPasskeyError = TurnkeySwiftError.invalidSession
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey)
    let anchor = await makeAnchor()

    await #expect(throws: RainSDKError.tokenExpired) {
      try await manager.loginWithPasskey(anchor: anchor)
    }
  }

  @Test("signUpWithPasskey delegates with display name")
  func testSignUpWithPasskeyDelegates() async throws {
    let turnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey)
    let anchor = await makeAnchor()

    try await manager.signUpWithPasskey(anchor: anchor, displayName: "Alice")
    #expect(turnkey.signUpWithPasskeyCallCount == 1)
  }

  @Test("initOtp returns an opaque handle and records the contact")
  func testInitOtp() async throws {
    let turnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey)

    _ = try await manager.initOtp(contact: .email("a@b.com"))
    #expect(turnkey.initOtpCalls.count == 1)
    #expect(turnkey.initOtpCalls[0].contact == "a@b.com")
    #expect(turnkey.initOtpCalls[0].otpType == .email)
  }

  @Test("completeOtp delegates with the opaque handle and code")
  func testCompleteOtp() async throws {
    let turnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey)

    let handle = try await manager.initOtp(contact: .sms("+15551234567"))
    try await manager.completeOtp(handle: handle, code: "123456")

    #expect(turnkey.completeOtpCalls.count == 1)
    #expect(turnkey.completeOtpCalls[0].otpCode == "123456")
    #expect(turnkey.completeOtpCalls[0].contact == "+15551234567")
  }

  @Test("loginWithOAuth routes to the correct provider handler")
  func testLoginWithOAuthRouting() async throws {
    let turnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey)
    let anchor = await makeAnchor()

    try await manager.loginWithOAuth(provider: .google, anchor: anchor)
    try await manager.loginWithOAuth(provider: .apple)
    try await manager.loginWithOAuth(provider: .discord, anchor: anchor)
    try await manager.loginWithOAuth(provider: .x, anchor: anchor)

    #expect(turnkey.oauthProviderCalls == ["google", "apple", "discord", "x"])
  }

  @Test("signOut clears the Turnkey session")
  func testSignOut() {
    let turnkey = MockTurnkey()
    let (manager, _, _) = TestManagers.turnkeyManager(turnkey: turnkey)
    manager.signOut()
    #expect(turnkey.clearSessionCallCount == 1)
  }

  // MARK: - Wallet selection

  @Test("selectWallet honors a known address and address() returns it")
  func testSelectWalletPicksAddress() async throws {
    let secondAddress = "0xfeed000000000000000000000000000000000000"
    let secondAccount = MockTurnkey.ethAccount(address: secondAddress, walletAccountId: "acct-2")
    let wallet = MockTurnkey.wallet(
      walletId: "wallet-1",
      walletName: "wallet",
      accounts: [MockTurnkey.defaultEthAccount(), secondAccount]
    )
    let turnkey = MockTurnkey(wallets: [wallet], authState: .authenticated)
    let manager = makeManager(turnkey: turnkey)
    try await waitForAuthState(.authenticated, on: manager)

    let initial = try await manager.getWalletAddress()
    #expect(initial == MockTurnkey.defaultWalletAddress)

    try await manager.selectWallet(address: secondAddress)
    let after = try await manager.getWalletAddress()
    #expect(after == secondAddress)
  }

  @Test("selectWallet throws walletUnavailable for an unknown address")
  func testSelectWalletRejectsUnknown() async throws {
    let turnkey = MockTurnkey(authState: .authenticated)
    let manager = makeManager(turnkey: turnkey)
    try await waitForAuthState(.authenticated, on: manager)

    await #expect(throws: RainSDKError.walletUnavailable) {
      try await manager.selectWallet(address: "0xbeef000000000000000000000000000000000000")
    }
  }

  @Test("availableTurnkeyWallets surfaces one entry per ETH account")
  func testAvailableWallets() async throws {
    let extra = MockTurnkey.ethAccount(address: "0xabcd000000000000000000000000000000000000", walletAccountId: "acct-2")
    let wallet = MockTurnkey.wallet(
      walletId: "wallet-1",
      walletName: "Demo",
      accounts: [MockTurnkey.defaultEthAccount(), extra]
    )
    let turnkey = MockTurnkey(wallets: [wallet], authState: .authenticated)
    let manager = makeManager(turnkey: turnkey)
    try await waitForAuthState(.authenticated, on: manager)

    let available = try await manager.availableTurnkeyWallets()
    #expect(available.count == 2)
    #expect(available.map(\.walletName) == ["Demo", "Demo"])
  }

  @Test("auth methods throw sdkNotInitialized before initializeTurnkey")
  func testFacadeRequiresInit() async throws {
    let manager = RainSDKManager()
    let anchor = await makeAnchor()

    await #expect(throws: RainSDKError.sdkNotInitialized) {
      try await manager.loginWithPasskey(anchor: anchor)
    }
  }

  private func makeAnchor() async -> ASPresentationAnchor {
    await SharedAnchor.value
  }

  /// Polls `manager.currentAuthState` until it equals `expected` or the deadline elapses.
  /// `handleTurnkeyAuthStateChange` writes the wallet provider before publishing the new
  /// state, so this also gives a happens-after guarantee for the provider binding.
  private func waitForAuthState(
    _ expected: RainAuthState,
    on manager: RainSDKManager,
    timeout: TimeInterval = 1.0
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while manager.currentAuthState != expected {
      if Date() > deadline {
        Issue.record("Timed out waiting for authState \(expected); got \(manager.currentAuthState)")
        return
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}

/// Single shared anchor instance to keep AppKit/UIKit happy under parallel test execution.
@MainActor
private enum SharedAnchor {
  static let value: ASPresentationAnchor = UIWindow()
}
