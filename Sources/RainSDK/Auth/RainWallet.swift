import Foundation

/// A single usable Ethereum wallet account exposed by the wallet provider.
///
/// One `RainWallet` corresponds to one `ADDRESS_FORMAT_ETHEREUM` account inside a Turnkey
/// wallet. A Turnkey wallet that contains multiple ETH accounts surfaces multiple `RainWallet`
/// entries (one per address).
public struct RainWallet: Sendable, Equatable, Identifiable {
  /// The wallet's Ethereum address (e.g. `0xabc…`). Stable per account.
  public let address: String
  /// The underlying Turnkey wallet id (shared across all accounts in the same wallet).
  public let walletId: String
  /// Human-readable name set when the wallet was created.
  public let walletName: String

  /// Use the address as the stable identity — addresses are unique per process.
  public var id: String { address }

  public init(address: String, walletId: String, walletName: String) {
    self.address = address
    self.walletId = walletId
    self.walletName = walletName
  }
}
