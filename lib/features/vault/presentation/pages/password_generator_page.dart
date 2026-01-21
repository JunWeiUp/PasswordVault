import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String _generatedPassword = '';

  @override
  void initState() {
    super.initState();
    _generatePassword();
  }

  void _generatePassword() {
    final password = PasswordGenerator.generate(
      length: _length.toInt(),
      useUppercase: _useUppercase,
      useLowercase: _useLowercase,
      useNumbers: _useNumbers,
      useSymbols: _useSymbols,
    );

    setState(() {
      _generatedPassword = password.isEmpty ? '请至少选择一种字符类型' : password;
    });
  }

  void _copyToClipboard() {
    if (_useUppercase == false && _useLowercase == false && _useNumbers == false && _useSymbols == false) return;
    
    Clipboard.setData(ClipboardData(text: _generatedPassword));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  Future<void> _fillCurrentPage() async {
    if (_useUppercase == false && _useLowercase == false && _useNumbers == false && _useSymbols == false) return;
    if (!ExtensionHelper.isExtension) return;

    final contextData = await ExtensionHelper.getActiveContext();
    final username = contextData?['username'] as String? ?? '';
    await ExtensionHelper.fillCredentials(username, _generatedPassword);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已填充到当前页面')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('密码生成器', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Password Display
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  SelectableText(
                    _generatedPassword,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      color: _generatedPassword == '请至少选择一种字符类型' 
                        ? theme.colorScheme.error 
                        : theme.colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ActionButton(
                        icon: Icons.refresh,
                        label: '重新生成',
                        onPressed: _generatePassword,
                      ),
                      const SizedBox(width: 16),
                      _ActionButton(
                        icon: Icons.copy,
                        label: '复制',
                        onPressed: _copyToClipboard,
                        primary: true,
                      ),
                      if (ExtensionHelper.isExtension) ...[
                        const SizedBox(width: 16),
                        _ActionButton(
                          icon: Icons.input,
                          label: '填充',
                          onPressed: _fillCurrentPage,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          // Configuration
          Text(
            '配置选项',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      const Text('密码长度', style: TextStyle(fontWeight: FontWeight.w500)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _length.toInt().toString(),
                          style: TextStyle(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Slider(
                  value: _length,
                  min: 4,
                  max: 64,
                  divisions: 60,
                  onChanged: (value) {
                    setState(() {
                      _length = value;
                    });
                    _generatePassword();
                  },
                ),
                const Divider(height: 1),
                _ConfigSwitch(
                  title: '大写字母',
                  subtitle: 'A-Z',
                  value: _useUppercase,
                  onChanged: (v) {
                    setState(() => _useUppercase = v);
                    _generatePassword();
                  },
                ),
                const Divider(height: 1),
                _ConfigSwitch(
                  title: '小写字母',
                  subtitle: 'a-z',
                  value: _useLowercase,
                  onChanged: (v) {
                    setState(() => _useLowercase = v);
                    _generatePassword();
                  },
                ),
                const Divider(height: 1),
                _ConfigSwitch(
                  title: '数字',
                  subtitle: '0-9',
                  value: _useNumbers,
                  onChanged: (v) {
                    setState(() => _useNumbers = v);
                    _generatePassword();
                  },
                ),
                const Divider(height: 1),
                _ConfigSwitch(
                  title: '特殊符号',
                  subtitle: '!@#\$%^&*',
                  value: _useSymbols,
                  onChanged: (v) {
                    setState(() => _useSymbols = v);
                    _generatePassword();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool primary;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (primary) {
      return ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _ConfigSwitch extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ConfigSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}
