import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/foundation.dart';

@JS('chromeSendMessage')
external JSPromise<JSAny?> _chromeSendMessage(JSObject message);

@JS('chromeStorageGet')
external JSPromise<JSAny?> _chromeStorageGet(JSString key);

@JS('chromeStorageSet')
external JSPromise<JSAny?> _chromeStorageSet(JSString key, JSAny? value);

@JS('chromeStorageRemove')
external JSPromise<JSAny?> _chromeStorageRemove(JSString key);

@JS('hasChromeApi')
external bool _hasChromeApi();

// Extension types for safe JS interop
@JS()
extension type PendingSaveItem(JSObject _) implements JSObject {
  external JSString? get username;
  external JSString? get password;
  external JSString? get url;
}

@JS()
extension type JSArrayHelper(JSArray _) implements JSArray {
  external int get length;
}

class ExtensionHelper {
  static bool get isExtension => kIsWeb && _isChromeExtension();

  static bool _isChromeExtension() {
    try {
      return _hasChromeApi();
    } catch (e) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingSaves() async {
    if (!isExtension) return [];

    try {
      final result = await _chromeStorageGet('pending_saves'.toJS).toDart;
      if (result == null || !result.isA<JSArray>()) return [];
      
      final array = result as JSArray;
      final helper = JSArrayHelper(array);
      final list = <Map<String, dynamic>>[];
      
      for (int i = 0; i < helper.length; i++) {
        final item = (array as JSObject).getProperty(i.toJS);
        if (item != null && item.isA<JSObject>()) {
          final saveItem = PendingSaveItem(item as JSObject);
          list.add({
            'username': saveItem.username?.toDart ?? '',
            'password': saveItem.password?.toDart ?? '',
            'url': saveItem.url?.toDart ?? '',
          });
        }
      }
      return list;
    } catch (e) {
      debugPrint('❌ ExtensionHelper.getPendingSaves error: $e');
      return [];
    }
  }

  static Future<void> clearPendingSaves() async {
    if (!isExtension) return;
    try {
      await _chromeStorageRemove('pending_saves'.toJS).toDart;
    } catch (e) {
      debugPrint('❌ ExtensionHelper.clearPendingSaves error: $e');
    }
  }

  static Future<Map<String, dynamic>?> getActiveContext() async {
    if (!isExtension) return null;

    try {
      final message = {'type': 'GET_ACTIVE_CONTEXT'}.jsify() as JSObject;
      final result = await _chromeSendMessage(message).toDart;
      
      if (result != null && result.isA<JSObject>()) {
        final obj = result as JSObject;
        return {
          'url': (obj.getProperty('url'.toJS) as JSString?)?.toDart,
          'origin': (obj.getProperty('origin'.toJS) as JSString?)?.toDart,
          'username': (obj.getProperty('username'.toJS) as JSString?)?.toDart,
        };
      }
    } catch (e) {
      debugPrint('❌ ExtensionHelper.getActiveContext error: $e');
    }
    return null;
  }

  static Future<void> clearActiveContext() async {
    if (!isExtension) return;
    try {
      final message = {'type': 'CLEAR_ACTIVE_CONTEXT'}.jsify() as JSObject;
      await _chromeSendMessage(message).toDart;
    } catch (e) {
      debugPrint('❌ ExtensionHelper.clearActiveContext error: $e');
    }
  }

  static Future<void> fillCredentials(String username, String password) async {
    if (!isExtension) return;

    try {
      final message = {
        'type': 'DO_FILL',
        'data': {
          'username': username,
          'password': password,
        }
      }.jsify() as JSObject;

      await _chromeSendMessage(message).toDart;
    } catch (e) {
      debugPrint('❌ ExtensionHelper.fillCredentials error: $e');
    }
  }

  static Future<Map<String, dynamic>?> getLastDetected() async {
    if (!isExtension) return null;

    try {
      final message = {
        'type': 'GET_LAST_DETECTED',
      }.jsify() as JSObject;

      final response = await _chromeSendMessage(message).toDart;
      if (response != null && response.isA<JSObject>()) {
        final saveItem = PendingSaveItem(response as JSObject);
        return {
          'username': saveItem.username?.toDart ?? '',
          'password': saveItem.password?.toDart ?? '',
          'url': saveItem.url?.toDart ?? '',
        };
      }
    } catch (e) {
      debugPrint('❌ ExtensionHelper.getLastDetected error: $e');
    }
    return null;
  }

  static Future<void> cacheMasterKey(String base64Key) async {
    if (!isExtension) return;
    try {
      final message = {
        'type': 'SET_MASTER_KEY',
        'data': {'key': base64Key},
      }.jsify() as JSObject;
      await _chromeSendMessage(message).toDart;
    } catch (e) {
      debugPrint('❌ ExtensionHelper.cacheMasterKey error: $e');
    }
  }

  static Future<String?> getCachedMasterKey() async {
    if (!isExtension) return null;
    try {
      final message = {'type': 'GET_MASTER_KEY'}.jsify() as JSObject;
      final response = await _chromeSendMessage(message).toDart;
      if (response != null && response.isA<JSObject>()) {
        final obj = response as JSObject;
        final key = obj.getProperty('key'.toJS);
        return key?.isA<JSString>() == true ? (key as JSString).toDart : null;
      }
    } catch (e) {
      debugPrint('❌ ExtensionHelper.getCachedMasterKey error: $e');
    }
    return null;
  }

  static Future<void> clearCachedMasterKey() async {
    if (!isExtension) return;
    try {
      final message = {'type': 'CLEAR_MASTER_KEY'}.jsify() as JSObject;
      await _chromeSendMessage(message).toDart;
    } catch (e) {
      debugPrint('❌ ExtensionHelper.clearCachedMasterKey error: $e');
    }
  }

  static Future<void> syncKnownDomains(List<String> domains) async {
    if (!isExtension) return;
    try {
      final jsDomains = domains.map((d) => d.toJS).toList().toJS;
      await _chromeStorageSet('known_domains'.toJS, jsDomains).toDart;
      debugPrint('✅ ExtensionHelper.syncKnownDomains: ${domains.length} domains');
    } catch (e) {
      debugPrint('❌ ExtensionHelper.syncKnownDomains error: $e');
    }
  }

  static Future<String?> getCurrentTabUrl() async {
    if (!isExtension) return null;
    try {
      final message = {'type': 'GET_CURRENT_TAB_URL'}.jsify() as JSObject;
      final response = await _chromeSendMessage(message).toDart;
      if (response != null && response.isA<JSObject>()) {
        final obj = response as JSObject;
        final url = obj.getProperty('url'.toJS);
        return url?.isA<JSString>() == true ? (url as JSString).toDart : null;
      }
    } catch (e) {
      debugPrint('❌ ExtensionHelper.getCurrentTabUrl error: $e');
    }
    return null;
  }
}
