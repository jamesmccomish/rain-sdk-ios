import Foundation
import RainSDK

/// ViewModel for the recover wallet popup. Portal-only; requires Rain API access token from Collateral Withdraw entry.
@MainActor
class RecoverViewModel: ObservableObject {
  private let sdkService: RainSDKService
  private let backupRepository: PortalBackupRepository

  @Published var showRecoverChoiceSheet: Bool = false
  @Published var selectedRecoverMethod: RainPortalBackupMethod?
  @Published var recoverPassword: String = ""
  @Published var recoverError: Error?
  @Published var isRecovering: Bool = false

  init(
    sdkService: RainSDKService = .shared,
    backupRepository: PortalBackupRepository = PortalBackupRepository()
  ) {
    self.sdkService = sdkService
    self.backupRepository = backupRepository
  }

  func showRecoverSheet() {
    recoverError = nil
    selectedRecoverMethod = .password
    recoverPassword = ""
    showRecoverChoiceSheet = true
  }

  func dismissRecoverSheet() {
    showRecoverChoiceSheet = false
    selectedRecoverMethod = nil
    recoverPassword = ""
    recoverError = nil
  }

  func selectRecoverMethod(_ method: RainPortalBackupMethod) {
    selectedRecoverMethod = method
    recoverError = nil
  }

  func performRecover() async {
    guard let method = selectedRecoverMethod else { return }

    if method == .password && recoverPassword.isEmpty {
      recoverError = NSError(domain: "Recover", code: -1, userInfo: [NSLocalizedDescriptionKey: "Password is required."])
      return
    }

    guard let token = AuthTokenStorage.getToken(), !token.isEmpty else {
      recoverError = NSError(
        domain: "Recover",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Access token is required for recovery. Enter your access token on the Collateral Withdraw entry screen first, then try Recover again."]
      )
      return
    }

    isRecovering = true
    recoverError = nil

    do {
      let backup = try await backupRepository.fetchBackup(backupMethod: method.rawValue)
      try await sdkService.recover(
        method: method,
        password: method == .password ? recoverPassword : nil,
        cipherText: backup.cipherText
      )

      dismissRecoverSheet()
    } catch {
      recoverError = error
    }
    isRecovering = false
  }
}
