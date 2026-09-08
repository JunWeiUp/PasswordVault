import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:password/core/l10n/l10n.dart';
import 'package:password/core/widgets/app_components.dart';
import '../providers/master_key_provider.dart';

class LockPage extends ConsumerStatefulWidget {
  const LockPage({super.key});

  @override
  ConsumerState<LockPage> createState() => _LockPageState();
}

class _LockPageState extends ConsumerState<LockPage> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _confirmFocus = FocusNode();
  final _localAuth = LocalAuthentication();
  String? _errorText;
  bool _isLoading = false;
  bool _isBiometricLoading = false;
  bool _showPassword = false;
  bool _showConfirmation = false;

  bool get _isBusy => _isLoading || _isBiometricLoading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkBiometric());
  }

  Future<void> _checkBiometric() async {
    if (!mounted || _isBusy) return;
    final state = ref.read(masterPasswordProvider);
    if (!state.hasMasterPassword || !state.isBiometricEnabled) return;

    setState(() {
      _isBiometricLoading = true;
      _errorText = null;
    });
    try {
      final didAuthenticate = await _localAuth.authenticate(
        localizedReason: tr.useYourFingerprintOrFaceToUnlock,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
      if (mounted && didAuthenticate) {
        await ref.read(masterPasswordProvider.notifier).setAuthenticated(true);
      }
    } catch (_) {
      if (mounted) setState(() => _errorText = tr.unlockFailedTryAgain);
    } finally {
      if (mounted) setState(() => _isBiometricLoading = false);
    }
  }

  Future<void> _submit() async {
    if (_isBusy) return;
    final state = ref.read(masterPasswordProvider);
    final isFirstTime = !state.hasMasterPassword;
    final password = _passwordController.text;

    if (password.isEmpty) {
      setState(() => _errorText = tr.passwordCannotBeEmpty);
      return;
    }
    if (isFirstTime && password != _confirmPasswordController.text) {
      setState(() => _errorText = tr.passwordsDoNotMatch);
      _confirmFocus.requestFocus();
      return;
    }
    if (!isFirstTime && password != state.password) {
      setState(() => _errorText = tr.incorrectPassword);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });
    try {
      final notifier = ref.read(masterPasswordProvider.notifier);
      if (isFirstTime) {
        await notifier.setPassword(password);
      } else {
        await notifier.setAuthenticated(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorText = isFirstTime
              ? tr.setupFailedTryAgain
              : tr.unlockFailedTryAgain;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _clearError(String _) {
    if (_errorText != null) setState(() => _errorText = null);
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    final state = ref.watch(masterPasswordProvider);
    final isFirstTime = !state.hasMasterPassword;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerRight,
                    child: LanguageSelector(),
                  ),
                  const SizedBox(height: 20),
                  const Center(child: VaultMark(size: 68)),
                  const SizedBox(height: 18),
                  Text(
                    tr.appName,
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr.localVaultTagline,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  AppSectionCard(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          isFirstTime ? tr.setMasterPassword : tr.unlockVault,
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isFirstTime
                              ? tr.yourMasterPasswordProtectsYourVaultKeep
                              : tr.enterYourMasterPasswordToContinue,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          key: const ValueKey('master-password'),
                          controller: _passwordController,
                          enabled: !_isBusy,
                          obscureText: !_showPassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          textInputAction: isFirstTime
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onSubmitted: (_) {
                            if (isFirstTime) {
                              _confirmFocus.requestFocus();
                            } else {
                              _submit();
                            }
                          },
                          onChanged: _clearError,
                          decoration: InputDecoration(
                            labelText: isFirstTime
                                ? tr.setNewPassword
                                : tr.enterPassword,
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              tooltip: _showPassword
                                  ? tr.hidePassword
                                  : tr.showPassword,
                              onPressed: _isBusy
                                  ? null
                                  : () => setState(
                                      () => _showPassword = !_showPassword,
                                    ),
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (isFirstTime) ...[
                          const SizedBox(height: 16),
                          TextField(
                            key: const ValueKey('confirm-master-password'),
                            controller: _confirmPasswordController,
                            focusNode: _confirmFocus,
                            enabled: !_isBusy,
                            obscureText: !_showConfirmation,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _submit(),
                            onChanged: _clearError,
                            decoration: InputDecoration(
                              labelText: tr.confirmNewPassword,
                              prefixIcon: const Icon(
                                Icons.check_circle_outline,
                              ),
                              suffixIcon: IconButton(
                                tooltip: _showConfirmation
                                    ? tr.hidePassword
                                    : tr.showPassword,
                                onPressed: _isBusy
                                    ? null
                                    : () => setState(
                                        () => _showConfirmation =
                                            !_showConfirmation,
                                      ),
                                icon: Icon(
                                  _showConfirmation
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                          ),
                        ],
                        if (_errorText != null) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _errorText!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.error,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          key: const ValueKey('unlock-submit'),
                          onPressed: _isBusy ? null : _submit,
                          child: _isLoading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(isFirstTime ? tr.getStarted : tr.unlock),
                        ),
                        if (!isFirstTime && state.isBiometricEnabled) ...[
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: _isBusy ? null : _checkBiometric,
                            icon: _isBiometricLoading
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.fingerprint),
                            label: Text(tr.useBiometrics),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    tr.previewNotice,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }
}
