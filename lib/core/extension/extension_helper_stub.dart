class ExtensionHelper {
  static bool get isExtension => false;

  static Future<List<Map<String, dynamic>>> getPendingSaves() async => [];

  static Future<void> clearPendingSaves() async {}

  static Future<Map<String, dynamic>?> getActiveContext() async => null;

  static Future<void> clearActiveContext() async {}

  static Future<void> fillCredentials(String username, String password) async {}

  static Future<Map<String, dynamic>?> getLastDetected() async => null;

  static Future<void> cacheMasterKey(String base64Key) async {}

  static Future<String?> getCachedMasterKey() async => null;

  static Future<void> clearCachedMasterKey() async {}

  static Future<void> syncKnownDomains(List<String> domains) async {}

  static Future<String?> getCurrentTabUrl() async => null;
}
