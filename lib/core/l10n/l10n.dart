import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';

export '../../l10n/app_localizations.dart';

// Non-widget services use the app's selected locale for error messages.
// Widget build methods also depend on Localizations so they refresh on changes.
Locale _messageLocale = const Locale('en');
AppLocalizations get tr => lookupAppLocalizations(_messageLocale);

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>(
  (ref) => LocaleNotifier(),
);

class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier() : super(const Locale('en')) {
    _messageLocale = state;
    ready = _load();
  }

  late final Future<void> ready;
  static const preferenceKey = 'app_language';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final language = prefs.getString(preferenceKey);
    if (mounted && language == 'zh') {
      _messageLocale = const Locale('zh');
      state = _messageLocale;
    }
  }

  Future<void> setLanguage(String language) async {
    if (!['en', 'zh'].contains(language)) return;
    await ready;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, language);
    if (!mounted) return;
    _messageLocale = Locale(language);
    state = _messageLocale;
  }
}

/// Display built-in legacy categories without changing stored values or filters.
String localizedCategory(String category) => switch (category) {
  '未分类' => tr.uncategorized,
  '社交媒体' => tr.social,
  '财务' => tr.finance,
  '工作' => tr.work,
  '购物' => tr.shopping,
  '娱乐' => tr.entertainment,
  '加密资产' => tr.cryptoAssets,
  '笔记' => tr.notes,
  _ => category,
};

class LanguageSelector extends ConsumerWidget {
  const LanguageSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context)!;
    return DropdownButton<String>(
      value: ref.watch(localeProvider).languageCode,
      onChanged: (value) {
        if (value != null) ref.read(localeProvider.notifier).setLanguage(value);
      },
      items: [
        DropdownMenuItem(value: 'en', child: Text(strings.english)),
        DropdownMenuItem(value: 'zh', child: Text(strings.simplifiedChinese)),
      ],
    );
  }
}
