import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:password/core/l10n/l10n.dart';
import 'package:password/core/widgets/app_components.dart';
import '../../../../core/extension/extension_helper.dart';
import '../../../../core/utils/password_generator.dart';

class PasswordGeneratorPage extends StatefulWidget {
  const PasswordGeneratorPage({super.key});

  @override
  State<PasswordGeneratorPage> createState() => _PasswordGeneratorPageState();
}

class _PasswordGeneratorPageState extends State<PasswordGeneratorPage> {
  double _length = 16;
  bool _useUppercase = true;
  bool _useLowercase = true;
  bool _useNumbers = true;
  bool _useSymbols = true;
  bool _isCopying = false;
  bool _isFilling = false;
  bool _copied = false;
  late String _generatedPassword;

  bool get _hasCharacterType =>
      _useUppercase || _useLowercase || _useNumbers || _useSymbols;

  @override
  void initState() {
    super.initState();
    _generatedPassword = _createPassword();
  }

  String _createPassword() => PasswordGenerator.generate(
    length: _length.toInt(),
    useUppercase: _useUppercase,
    useLowercase: _useLowercase,
    useNumbers: _useNumbers,
    useSymbols: _useSymbols,
  );

  void _generatePassword([VoidCallback? updateOptions]) {
    setState(() {
      updateOptions?.call();
      _generatedPassword = _createPassword();
      _copied = false;
    });
  }

  Future<void> _copyToClipboard() async {
    if (!_hasCharacterType || _isCopying) return;
    final password = _generatedPassword;
    setState(() => _isCopying = true);
    try {
      await Clipboard.setData(ClipboardData(text: password));
      if (!mounted) return;
      setState(() => _copied = password == _generatedPassword);
      _showMessage(tr.copiedToClipboard);
    } catch (_) {
      if (mounted) _showMessage(tr.clipboardWriteFailed);
    } finally {
      if (mounted) setState(() => _isCopying = false);
    }
  }

  Future<void> _fillCurrentPage() async {
    if (!_hasCharacterType || _isFilling || !ExtensionHelper.isExtension)
      return;
    final password = _generatedPassword;
    setState(() => _isFilling = true);
    try {
      final contextData = await ExtensionHelper.getActiveContext();
      final username = contextData?['username'] as String? ?? '';
      await ExtensionHelper.fillCredentials(username, password);
      if (mounted) _showMessage(tr.filledOnTheCurrentPage);
    } catch (_) {
      if (mounted) _showMessage(tr.fillFailedTryAgain);
    } finally {
      if (mounted) setState(() => _isFilling = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.passwordGenerator)),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    tr.generatorDescription,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // Large system text gets a single reading column as well.
                      final isWide =
                          constraints.maxWidth >= 800 &&
                          MediaQuery.textScalerOf(context).scale(16) <= 24;
                      if (isWide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _buildResult(context)),
                            const SizedBox(width: 24),
                            Expanded(child: _buildOptions(context)),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildResult(context),
                          const SizedBox(height: 24),
                          _buildOptions(context),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AppSectionCard(
      title: tr.generatedPassword,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 144),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
            ),
            child: _hasCharacterType
                ? SelectableText(
                    key: const ValueKey('generated-password'),
                    _generatedPassword,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      height: 1.5,
                      letterSpacing: 1,
                      color: colors.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  )
                : Semantics(
                    liveRegion: true,
                    child: Text(
                      tr.selectAtLeastOneCharacterType,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                key: const ValueKey('copy-password'),
                onPressed: _hasCharacterType && !_isCopying
                    ? _copyToClipboard
                    : null,
                icon: _isCopying
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
                label: Text(tr.copy),
              ),
              OutlinedButton.icon(
                key: const ValueKey('regenerate-password'),
                onPressed: _hasCharacterType ? _generatePassword : null,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(tr.regenerate),
              ),
              if (ExtensionHelper.isExtension)
                OutlinedButton.icon(
                  onPressed: _hasCharacterType && !_isFilling
                      ? _fillCurrentPage
                      : null,
                  icon: _isFilling
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.input_rounded),
                  label: Text(tr.fill),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOptions(BuildContext context) {
    final theme = Theme.of(context);
    return AppSectionCard(
      title: tr.options,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr.passwordLength,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _length.toInt().toString(),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          Semantics(
            label: tr.passwordLength,
            child: Slider(
              value: _length,
              min: 4,
              max: 64,
              divisions: 60,
              label: _length.toInt().toString(),
              onChanged: (value) => _generatePassword(() => _length = value),
            ),
          ),
          const Divider(),
          _ConfigSwitch(
            title: tr.uppercaseLetters,
            subtitle: 'A–Z',
            value: _useUppercase,
            onChanged: (value) =>
                _generatePassword(() => _useUppercase = value),
          ),
          const Divider(),
          _ConfigSwitch(
            title: tr.lowercaseLetters,
            subtitle: 'a–z',
            value: _useLowercase,
            onChanged: (value) =>
                _generatePassword(() => _useLowercase = value),
          ),
          const Divider(),
          _ConfigSwitch(
            title: tr.digits,
            subtitle: '0–9',
            value: _useNumbers,
            onChanged: (value) => _generatePassword(() => _useNumbers = value),
          ),
          const Divider(),
          _ConfigSwitch(
            title: tr.symbols,
            subtitle: '!@#\$%^&*',
            value: _useSymbols,
            onChanged: (value) => _generatePassword(() => _useSymbols = value),
          ),
        ],
      ),
    );
  }
}

class _ConfigSwitch extends StatelessWidget {
  const _ConfigSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      title: Text(title, style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
    );
  }
}
