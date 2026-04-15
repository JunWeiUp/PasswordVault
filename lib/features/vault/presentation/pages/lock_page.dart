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
          localizedReason: '请使用指纹或面容登录密码保险箱',
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
      setState(() => _errorText = '密码不能为空');
      return;
    }

    if (password != confirmPassword) {
      setState(() => _errorText = '两次输入的密码不一致');
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
          _errorText = '设置失败，请重试';
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
      setState(() => _errorText = '密码错误');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(masterPasswordProvider);
    final isFirstTime = !state.hasMasterPassword;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, size: 80, color: Colors.blue),
              const SizedBox(height: 32),
              Text(
                isFirstTime ? '设置主密码' : '解锁密码库',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isFirstTime ? '主密码用于加密您的所有数据，请务必牢记' : '请输入您的主密码以继续',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: isFirstTime ? '设置新密码' : '输入密码',
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
                  decoration: const InputDecoration(
                    labelText: '确认新密码',
                    border: OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.check_circle_outline),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : (isFirstTime ? _handleSetPassword : _handleLogin),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _isLoading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(isFirstTime ? '开始使用' : '解锁'),
              ),
              if (!isFirstTime && state.isBiometricEnabled) ...[
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: _checkBiometric,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('使用指纹登录'),
                ),
              ],
            ],
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
