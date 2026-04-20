import Foundation
import CloudKit

/// CloudKit同期の状態を保持・問い合わせするシングルトン
@Observable
@MainActor
final class CloudSyncStatus {
    static let shared = CloudSyncStatus()

    enum Status: Equatable {
        case available           // サインイン済み、同期可能
        case noAccount           // iCloudサインインなし
        case restricted          // ペアレンタルコントロール等で制限
        case temporarilyUnavailable
        case couldNotDetermine
        case localOnly           // ModelContainer初期化失敗、CloudKit利用不可
        case unknown             // 起動直後でまだチェックしていない

        var label: String {
            switch self {
            case .available: return "有効"
            case .noAccount: return "iCloud未サインイン"
            case .restricted: return "制限あり"
            case .temporarilyUnavailable: return "一時的に利用不可"
            case .couldNotDetermine: return "確認できません"
            case .localOnly: return "ローカルのみ"
            case .unknown: return "確認中..."
            }
        }

        var description: String {
            switch self {
            case .available:
                return "お気に入り・既読・ソース設定などをiCloud経由で他のデバイスと同期します。"
            case .noAccount:
                return "iCloudにサインインすると、他のデバイスとデータを同期できます。設定アプリのApple IDからサインインしてください。"
            case .restricted:
                return "ペアレンタルコントロールやMDMによってiCloudが制限されています。"
            case .temporarilyUnavailable:
                return "iCloudが一時的に利用できません。サインイン状態と通信環境を確認してください。"
            case .couldNotDetermine:
                return "iCloudの状態を確認できませんでした。通信環境を確認してください。"
            case .localOnly:
                return "iCloud同期に失敗しています。データはこの端末にのみ保存されます。"
            case .unknown:
                return "iCloudの状態を確認しています。"
            }
        }
    }

    private(set) var status: Status = .unknown
    private var containerInitOK = false

    private init() {}

    /// ModelContainer初期化結果を記録
    func setContainerInitialized(cloudKitEnabled: Bool) {
        containerInitOK = cloudKitEnabled
        if !cloudKitEnabled {
            status = .localOnly
        }
    }

    /// CKContainerのアカウント状態を取得して反映
    func refresh() async {
        guard containerInitOK else {
            status = .localOnly
            return
        }
        do {
            let accountStatus = try await CKContainer.default().accountStatus()
            switch accountStatus {
            case .available:
                status = .available
            case .noAccount:
                status = .noAccount
            case .restricted:
                status = .restricted
            case .temporarilyUnavailable:
                status = .temporarilyUnavailable
            case .couldNotDetermine:
                status = .couldNotDetermine
            @unknown default:
                status = .couldNotDetermine
            }
        } catch {
            status = .couldNotDetermine
        }
    }
}
