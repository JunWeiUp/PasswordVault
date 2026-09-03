import 'package:password/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import '../providers/master_key_provider.dart';

class LockPage extends ConsumerStatefulWidget {
  const LockPage({super.key});

  @override
  ConsumerState<LockPage> createState() => _LockPageState();
}

class _LockPageState extends ConsumerState<LockPage> {
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _localAuth = LocalAuthentication();
  String? _errorText;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // 延迟执行生物识别，避免在页面构建过程中弹出
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkBiometric();
    });
  }

  Future<void> _checkBiometric() async {
    if (!mounted) return;
    final state = ref.read(masterPasswordProvider);
    if (state.hasMasterPassword && state.isBiometricEnabled) {
      try {
        final didAuthenticate = await _localAuth.authenticate(
          localizedReason: tr.useYourFingerprintOrFaceToUnlock,
          options: const AuthenticationOptions(
            stickyAuth: true,
            biometricOnly: true,
          ),
        );

        if (!mounted) return;
        if (didAuthenticate) {
          ref.read(masterPasswordProvider.notifier).setAuthenticated(true);
        }
      } catch (e) {
        debugPrint('Biometric auth error: $e');
      }
    }
  }

  Future<void> _handleSetPassword() async {
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (password.isEmpty) {
      setState(() => _errorText = tr.passwordCannotBeEmpty);
      return;
    }

    if (password != confirmPassword) {
      setState(() => _errorText = tr.passwordsDoNotMatch);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      await ref.read(masterPasswordProvider.notifier).setPassword(password);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorText = tr.setupFailedTryAgain;
        });
      }
    }
  }

  Future<void> _handleLogin() async {
    final password = _passwordController.text;
    final state = ref.read(masterPasswordProvider);

    if (password == state.password) {
      setState(() => _isLoading = true);
      await ref.read(masterPasswordProvider.notifier).setAuthenticated(true);
    } else {
      setState(() => _errorText = tr.incorrectPassword);
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    final state = ref.watch(masterPasswordProvider);
    final isFirstTime = !state.hasMasterPassword;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerRight,
                    child: LanguageSelector(),
                  ),
                  const Icon(Icons.lock_outline, size: 80, color: Colors.blue),
                  const SizedBox(height: 32),
                  Text(
                    isFirstTime ? tr.setMasterPassword : tr.unlockVault,
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isFirstTime
                        ? tr.yourMasterPasswordProtectsYourVaultKeep
                        : tr.enterYourMasterPasswordToContinue,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: isFirstTime
                          ? tr.setNewPassword
                          : tr.enterPassword,
                      border: const OutlineInputBorder(),
                      errorText: _errorText,
                      prefixIcon: const Icon(Icons.password),
                    ),
                  ),
                  if (isFirstTime) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmPasswordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: tr.confirmNewPassword,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.check_circle_outline),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _isLoading
                        ? null
                        : (isFirstTime ? _handleSetPassword : _handleLogin),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(isFirstTime ? tr.getStarted : tr.unlock),
                  ),
                  if (!isFirstTime && state.isBiometricEnabled) ...[
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: _checkBiometric,
                      icon: const Icon(Icons.fingerprint),
                      label: Text(tr.useBiometrics),
                    ),
                  ],
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
    super.dispose();
  }
}
