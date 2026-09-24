import Foundation

enum ErrorContext { case general, unlock, save, backup, changePassword }

extension AppStore {
  func errorMessage(_ error: Error, context: ErrorContext = .general) -> String {
    // Never display raw SQL, local paths, credentials, or server response bodies.
    if let failure = error as? WebDAVFailure {
      switch failure {
      case .invalidConfiguration:
        return t(
          "WebDAV 地址或目录无效。远程地址需要 HTTPS，目录不要使用 .. 或以 / 开头。",
          "The WebDAV address or folder is invalid. Remote addresses require HTTPS; folders cannot start with / or contain .."
        )
      case .invalidListing:
        return t(
          "服务器返回的备份列表无法识别。请确认地址支持 WebDAV 后重试。",
          "The server returned an unreadable backup list. Confirm that this address supports WebDAV and retry."
        )
      case .authentication:
        return t(
          "服务器账号或密码不正确。请检查 WebDAV 登录信息后重试。",
          "The server rejected your login. Check your WebDAV username and password.")
      case .permission:
        return t(
          "没有访问此备份目录的权限。请检查服务器授权。",
          "Access to this backup folder was denied. Check server permissions.")
      case .notFound:
        return t(
          "找不到备份目录或文件。请检查地址和目录，或刷新列表。",
          "The backup folder or file was not found. Check the address/folder or refresh the list.")
      case .server:
        return t(
          "备份服务器暂时无法完成请求，请稍后重试。",
          "The backup server could not complete the request. Please retry shortly.")
      }
    }
    if let network = error as? URLError {
      switch network.code {
      case .timedOut:
        return t("连接超时。请检查网络后重试。", "The connection timed out. Check your network and retry.")
      case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
        return t(
          "无法连接服务器。请检查网络和 WebDAV 地址。",
          "Cannot reach the server. Check your network and WebDAV address.")
      case .cancelled: return t("操作已取消，可以重新尝试。", "The operation was cancelled. You can try again.")
      default:
        return t(
          "连接未完成。请检查服务器地址和证书后重试。",
          "The connection failed. Check the server address and certificate, then retry.")
      }
    }
    if let failure = error as? VaultError {
      switch failure {
      case .Authentication:
        switch context {
        case .unlock:
          return t(
            "主密码不正确，或资料库无法解密。请重新输入主密码。",
            "The master password is incorrect or the vault cannot be decrypted. Enter your master password again."
          )
        case .backup:
          return t(
            "备份密码不正确，或文件已损坏。请确认备份文件密码后重试。",
            "The backup passphrase is incorrect or the file is damaged. Check the backup passphrase and retry."
          )
        case .changePassword:
          return t("当前主密码不正确，请重新输入。", "The current master password is incorrect. Try again.")
        default:
          return t(
            "没有执行此操作的权限。共享条目需要编辑权限。",
            "This action is not permitted. Shared entries require edit permission.")
        }
      case .Storage:
        return t(
          "无法写入或读取本地资料库。请检查磁盘空间和文件权限后重试；未保存的修改仍需保存。",
          "Cannot read or write the local vault. Check disk space and file permissions, then retry saving pending edits."
        )
      case .InvalidData:
        return context == .backup
          ? t(
            "无法识别此备份。请选择支持的 JSON、CSV 或加密备份文件。",
            "This backup could not be read. Select a supported JSON, CSV, or encrypted backup.")
          : t("内容格式无效。请检查输入后重试。", "The input format is invalid. Check it and retry.")
      case .Unsupported:
        return t(
          "此格式或操作尚不支持。请使用兼容的备份或客户端。",
          "This format or operation is not supported. Use a compatible backup or client.")
      case .Locked: return t("资料库已锁定，请解锁后重试。", "The vault is locked. Unlock it and retry.")
      case .AlreadyExists:
        return t("同名内容已存在，请换一个名称。", "This name already exists. Choose a different name.")
      case .InUse:
        return t(
          "资料库正在另一应用实例中打开。关闭该实例后重试。",
          "Another app instance is using this vault. Close it and retry.")
      }
    }
    return t(
      "操作未完成，请重试。原有资料会保留。", "The operation could not complete. Retry; existing data is retained.")
  }
}

enum WebDAVFailure: Error {
  case authentication, permission, notFound, server, invalidConfiguration, invalidListing
}
