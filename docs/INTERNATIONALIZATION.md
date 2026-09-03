# Internationalization

English is the default application and documentation language. Users can choose English or Simplified Chinese on the lock screen and in Settings → Appearance. The preference is saved locally; the operating-system language does not silently override it.

## Flutter

`lib/l10n/app_en.arb` is the source catalog; `app_zh.arb` is the Chinese translation. `flutter gen-l10n` generates typed accessors beside these files. Generated localization Dart files are ignored and recreated by CI.

Add a meaningful English key, translate it, and preserve every placeholder in both languages. Use ICU plural forms for new count-dependent sentences. Avoid concatenating translated fragments. `tool/check_repository.py` validates matching keys and placeholders.

Widgets depend on `AppLocalizations.of(context)` so changing the locale rebuilds them. The `tr` accessor supplies the selected locale to helper methods and non-widget error messages. Do not use translated text as protocol keys, database identifiers, or authorization state. Legacy built-in category identifiers are translated only for display; user content is retained verbatim.

To add a language, create a new ARB catalog, extend the supported language selector and persisted locale validation, regenerate, and test the lock screen, settings, validation errors, and narrow layouts. Add matching extension messages if the extension supports that language.

## Browser extension

Chrome's `_locales/en/messages.json` and `_locales/zh_CN/messages.json` contain extension labels, menus, prompts, and accessibility text. `default_locale` is `en`; Chrome chooses extension messages from the browser language, independently of the Flutter UI setting.

Keep HTML markup outside translated messages. Escape user-supplied values before inserting them into HTML. Manifest descriptions use `__MSG_name__` references.

## Documentation

`README.md` is English and `README.zh-CN.md` is Simplified Chinese. Keep features, limitations, commands, and platform claims synchronized. Technical guides and commit messages default to English. A translation should not strengthen a security claim beyond the English source.
