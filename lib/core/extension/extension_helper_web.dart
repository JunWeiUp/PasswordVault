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
  static const Duration _messageTimeout = Duration(seconds: 2);

  static bool get isExtension => kIsWeb && _isChromeExtension();

  static bool _isChromeExtension() {
    try {
      return _hasChromeApi();
    } catch (e) {
      return false;
    }
  }

  static Future<JSAny?> _sendMessage(
    JSObject message, {
    required String debugLabel,
  }) async {
    try {
      return await _chromeSendMessage(message).toDart.timeout(
        _messageTimeout,
        onTimeout: () {
          debugPrint('⚠️ ExtensionHelper.$debugLabel timeout');
          return null;
        },
      );
    } catch (e) {
      debugPrint('❌ ExtensionHelper.$debugLabel error: $e');
      return null;
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

    final message = {'type': 'GET_ACTIVE_CONTEXT'}.jsify() as JSObject;
    final result = await _sendMessage(message, debugLabel: 'getActiveContext');

    if (result != null && result.isA<JSObject>()) {
      final obj = result as JSObject;
      final data = obj.getProperty('data'.toJS);

      Map<String, dynamic>? dataMap;
      if (data != null && data.isA<JSObject>()) {
        final dataObj = data as JSObject;
        dataMap = {
          'url': (dataObj.getProperty('url'.toJS) as JSString?)?.toDart,
          'username': (dataObj.getProperty('username'.toJS) as JSString?)?.toDart,
          'password': (dataObj.getProperty('password'.toJS) as JSString?)?.toDart,
          'reason': (dataObj.getProperty('reason'.toJS) as JSString?)?.toDart,
        };
      }

      final fillRequestedProp = obj.getProperty('fillRequested'.toJS);
      final fillRequested = fillRequestedProp != null && fillRequestedProp.isA<JSBoolean>()
          ? (fillRequestedProp as JSBoolean).toDart
          : false;

      final autoCloseProp = obj.getProperty('autoClose'.toJS);
      final autoClose = autoCloseProp != null && autoCloseProp.isA<JSBoolean>()
          ? (autoCloseProp as JSBoolean).toDart
          : false;

      final fillTargetProp = obj.getProperty('fillTarget'.toJS);
      final fillTarget = fillTargetProp != null && fillTargetProp.isA<JSString>()
          ? (fillTargetProp as JSString).toDart
          : null;

      return {
        'url': (obj.getProperty('url'.toJS) as JSString?)?.toDart,
        'origin': (obj.getProperty('origin'.toJS) as JSString?)?.toDart,
        'username': (obj.getProperty('username'.toJS) as JSString?)?.toDart,
        'type': (obj.getProperty('type'.toJS) as JSString?)?.toDart,
        'data': dataMap,
        'fillRequested': fillRequested,
        'autoClose': autoClose,
        'fillTarget': fillTarget,
      };
    }
    return null;
  }

  static Future<void> clearActiveContext() async {
    if (!isExtension) return;
    final message = {'type': 'CLEAR_ACTIVE_CONTEXT'}.jsify() as JSObject;
    await _sendMessage(message, debugLabel: 'clearActiveContext');
  }

  static Future<void> fillCredentials(String username, String password) async {
    if (!isExtension) return;

    final message = {
      'type': 'DO_FILL',
      'data': {
        'username': username,
        'password': password,
      }
    }.jsify() as JSObject;

    await _sendMessage(message, debugLabel: 'fillCredentials');
  }

  static Future<Map<String, dynamic>?> getLastDetected() async {
    if (!isExtension) return null;

    final message = {
      'type': 'GET_LAST_DETECTED',
    }.jsify() as JSObject;

    final response = await _sendMessage(message, debugLabel: 'getLastDetected');
    if (response != null && response.isA<JSObject>()) {
      final saveItem = PendingSaveItem(response as JSObject);
      return {
        'username': saveItem.username?.toDart ?? '',
        'password': saveItem.password?.toDart ?? '',
        'url': saveItem.url?.toDart ?? '',
      };
    }
    return null;
  }

  static Future<void> cacheMasterKey(String base64Key) async {
    if (!isExtension) return;
    final message = {
      'type': 'SET_MASTER_KEY',
      'data': {'key': base64Key},
    }.jsify() as JSObject;
    await _sendMessage(message, debugLabel: 'cacheMasterKey');
  }

  static Future<String?> getCachedMasterKey() async {
    if (!isExtension) return null;
    final message = {'type': 'GET_MASTER_KEY'}.jsify() as JSObject;
    final response = await _sendMessage(message, debugLabel: 'getCachedMasterKey');
    if (response != null && response.isA<JSObject>()) {
      final obj = response as JSObject;
      final key = obj.getProperty('key'.toJS);
      return key?.isA<JSString>() == true ? (key as JSString).toDart : null;
    }
    return null;
  }

  static Future<void> clearCachedMasterKey() async {
    if (!isExtension) return;
    final message = {'type': 'CLEAR_MASTER_KEY'}.jsify() as JSObject;
    await _sendMessage(message, debugLabel: 'clearCachedMasterKey');
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

  static Future<void> syncKnownAccounts(Map<String, List<Map<String, String>>> accounts) async {
    if (!isExtension) return;
    try {
      final jsAccounts = accounts.jsify();
      await _chromeStorageSet('known_accounts'.toJS, jsAccounts).toDart;
      debugPrint('✅ ExtensionHelper.syncKnownAccounts synced');
    } catch (e) {
      debugPrint('❌ ExtensionHelper.syncKnownAccounts error: $e');
    }
  }

  static void closeWindow() {
    if (!isExtension) return;
    try {
      globalContext.callMethod('close'.toJS);
    } catch (e) {
      debugPrint('❌ ExtensionHelper.closeWindow error: $e');
    }
  }

  static Future<void> setAutoFillEnabled(bool enabled) async {
    if (!isExtension) return;
    final message = {
      'type': 'SET_AUTOFILL_ENABLED',
      'data': {'enabled': enabled},
    }.jsify() as JSObject;
    await _sendMessage(message, debugLabel: 'setAutoFillEnabled');
  }

  static Future<bool> getAutoFillEnabled() async {
    if (!isExtension) return false;
    final message = {'type': 'GET_AUTOFILL_ENABLED'}.jsify() as JSObject;
    final response = await _sendMessage(message, debugLabel: 'getAutoFillEnabled');
    if (response != null && response.isA<JSObject>()) {
      final obj = response as JSObject;
      final enabled = obj.getProperty('enabled'.toJS);
      return enabled != null && enabled.isA<JSBoolean>() && (enabled as JSBoolean).toDart;
    }
    return false;
  }

  static Future<String?> getCurrentTabUrl() async {
    if (!isExtension) return null;
    final message = {'type': 'GET_CURRENT_TAB_URL'}.jsify() as JSObject;
    final response = await _sendMessage(message, debugLabel: 'getCurrentTabUrl');

    if (response != null && response.isA<JSObject>()) {
      final obj = response as JSObject;
      if (obj.hasProperty('url'.toJS).toDart) {
        final url = obj.getProperty('url'.toJS);
        if (url != null && url.isA<JSString>()) {
          return (url as JSString).toDart;
        }
      }
    }
    return null;
  }
}
