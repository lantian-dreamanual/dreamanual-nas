import Foundation
import Security

/// 口令只进系统钥匙串，不落配置文件、不落日志、不落 UserDefaults。
///
/// 与实验室脚本共用同一个 service（`dreamanual-nas`），所以用户在终端里
/// 存过一次 `security add-generic-password -a <账号> -s dreamanual-nas -U -w`
/// 之后，App 也能直接读到 —— 探测脚本与 App 看同一份凭据。
///
/// account 用「QuickConnect ID|用户名」拼：同一台机器可能连过多个 NAS，
/// 单用用户名会让两个 NAS 的同名账号互相覆盖。
enum KeychainStore {
    static let service = "dreamanual-nas"

    static func accountKey(endpointID: String, username: String) -> String {
        "\(endpointID)|\(username)"
    }

    /// 写入（存在则覆盖）。
    @discardableResult
    static func save(password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        // 先删再加：SecItemUpdate 与 SecItemAdd 两条路在「无 ACL 例外」时
        // 行为不一致，删除+新增是唯一两向都能预期的做法。
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// 取口令：先查「端点|账号」那条，再退回**裸账号**。
    ///
    /// 退回这一步是必须的 —— 用户照上面那句 `security add-generic-password`
    /// 存进去的条目，`acct` 只有账号名，拼出来的键查不到。少了退回，App 会
    /// 以为「没存过口令」，让用户把已经存好的口令再敲一遍。
    static func password(endpointID: String, username: String) -> String? {
        password(account: accountKey(endpointID: endpointID, username: username))
            ?? password(account: username)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
