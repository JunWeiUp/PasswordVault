import 'package:password/core/l10n/l10n.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/utils/password_generator.dart';
import '../../../../core/utils/bip39_words.dart';
import '../../../../core/utils/crypto_utils.dart';
import '../../domain/models/vault_item.dart';
import '../providers/vault_provider.dart';
import '../widgets/favicon_widget.dart';

class AddAccountPage extends ConsumerStatefulWidget {
  final VaultItem? item;
  const AddAccountPage({this.item, super.key});

  @override
  ConsumerState<AddAccountPage> createState() => _AddAccountPageState();
}

class _AddAccountPageState extends ConsumerState<AddAccountPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final List<_AccountControllerGroup> _extraAccounts;
  late final List<TextEditingController> _mnemonicControllers;
  late final List<FocusNode> _mnemonicFocusNodes;
  late final TextEditingController _privateKeyController;
  late final TextEditingController _addressController;
  late final TextEditingController _categoryController;
  late final TextEditingController _emailController;
  late final TextEditingController _urlController;
  late final TextEditingController _noteController;
  late final TextEditingController _durationController;
  late final TextEditingController _tagInputController;
  String? _selectedSharedVaultId;
  late List<String> _tags;
  String? _totpSecret;
  String? _selectedNetwork;
  bool _obscurePassword = true;
  late bool _obscureMnemonic;
  late bool _isPinned;
  String? _colorLabel;

  @override
  void initState() {
    super.initState();
    _obscureMnemonic = widget.item != null && widget.item!.id.isNotEmpty;
    _titleController = TextEditingController(text: widget.item?.title);
    _usernameController = TextEditingController(text: widget.item?.username);
    _passwordController = TextEditingController(text: widget.item?.password);

    // 初始化额外账号
    _extraAccounts = (widget.item?.accounts ?? []).map((acc) {
      return _AccountControllerGroup(
        id: acc.id,
        username: acc.username,
        password: acc.password,
        label: acc.label,
        passwordHistory: acc.passwordHistory,
        passwordLastChanged: acc.passwordLastChanged,
      );
    }).toList();

    // 初始化助记词控制器
    final mnemonic = widget.item?.mnemonic ?? '';
    final words = mnemonic.split(' ').where((w) => w.isNotEmpty).toList();
    _mnemonicControllers = List.generate(12, (index) {
      return TextEditingController(
        text: index < words.length ? words[index] : '',
      );
    });
    _mnemonicFocusNodes = List.generate(12, (index) => FocusNode());

    _privateKeyController = TextEditingController(
      text: widget.item?.privateKey,
    );
    _addressController = TextEditingController(text: widget.item?.address);
    _categoryController = TextEditingController(
      text:
          widget.item?.category ??
          (widget.item?.type == VaultItemType.crypto
              ? '加密资产'
              : (widget.item?.type == VaultItemType.secureNote
                    ? '笔记'
                    : '社交媒体')),
    );
    _emailController = TextEditingController(text: widget.item?.email);
    _urlController = TextEditingController(text: widget.item?.url);
    _urlController.addListener(() {
      setState(() {});
    });
    _titleController.addListener(() {
      setState(() {});
    });
    _noteController = TextEditingController(text: widget.item?.note);
    _durationController = TextEditingController(
      text: widget.item?.passwordDuration?.toString() ?? '',
    );
    _tagInputController = TextEditingController();
    _tags = List.from(widget.item?.tags ?? []);
    _totpSecret = widget.item?.secret;
    _selectedSharedVaultId = widget.item?.sharedVaultId;
    _selectedNetwork =
        widget.item?.network ??
        (widget.item?.type == VaultItemType.crypto ? 'ETH' : null);
    _isPinned = widget.item?.isPinned ?? false;
    _colorLabel = widget.item?.colorLabel;

    // 添加监听器以自动生成地址
    _privateKeyController.addListener(
      () => _updateAddressFromPrivateKey(showErrors: false),
    );
    for (var controller in _mnemonicControllers) {
      controller.addListener(_onMnemonicChanged);
    }
  }

  bool _isGeneratingAddress = false;
  bool _isUpdatingMnemonicBatch = false;
  Timer? _debounceTimer;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _titleController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    for (var group in _extraAccounts) {
      group.dispose();
    }
    for (var controller in _mnemonicControllers) {
      controller.dispose();
    }
    for (var node in _mnemonicFocusNodes) {
      node.dispose();
    }
    _privateKeyController.dispose();
    _addressController.dispose();
    _categoryController.dispose();
    _emailController.dispose();
    _urlController.dispose();
    _noteController.dispose();
    _durationController.dispose();
    _tagInputController.dispose();
    super.dispose();
  }

  void _onMnemonicChanged() {
    if (_isUpdatingMnemonicBatch) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _updateAddressFromMnemonic(showErrors: false);
    });
  }

  void _updateAddressFromPrivateKey({bool showErrors = true}) {
    final address = CryptoUtils.getEthAddressFromPrivateKey(
      _privateKeyController.text,
    );
    if (address != null) {
      setState(() {
        _addressController.text = address;
      });
    } else if (showErrors && _privateKeyController.text.isNotEmpty) {
      // 如果私钥无效，显示提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr.invalidPrivateKeyEnterHexadecimalCharacters)),
      );
    }
  }

  Future<void> _updateAddressFromMnemonic({bool showErrors = true}) async {
    final mnemonic = _mnemonicControllers
        .map((c) => c.text.trim())
        .where((text) => text.isNotEmpty)
        .join(' ');

    final words = mnemonic.split(' ');
    if (words.length == 12) {
      setState(() => _isGeneratingAddress = true);
      try {
        final result = await CryptoUtils.getAllFromMnemonic(mnemonic);
        final address = result['address'];
        final privateKey = result['privateKey'];

        if (mounted) {
          setState(() {
            if (address != null) _addressController.text = address;
            if (privateKey != null) _privateKeyController.text = privateKey;
          });

          if (address == null && showErrors) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr.invalidRecoveryPhraseCheckTheSpelling)),
            );
          }
        }
      } finally {
        if (mounted) setState(() => _isGeneratingAddress = false);
      }
    } else if (showErrors && mnemonic.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.enterAllRecoveryWords)));
    }
  }

  void _save() {
    if (_titleController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.completeAllRequiredFields)));
      return;
    }

    final mnemonic = _mnemonicControllers
        .map((c) => c.text.trim())
        .where((text) => text.isNotEmpty)
        .join(' ');

    final newItem = VaultItem(
      id: (widget.item?.id == null || widget.item!.id.isEmpty)
          ? const Uuid().v4()
          : widget.item!.id,
      type: widget.item?.type ?? VaultItemType.password,
      title: _titleController.text,
      username: _usernameController.text,
      password: _passwordController.text.isEmpty
          ? null
          : _passwordController.text,
      mnemonic: mnemonic.isEmpty ? null : mnemonic,
      privateKey: _privateKeyController.text.isEmpty
          ? null
          : _privateKeyController.text,
      address: _addressController.text.isEmpty ? null : _addressController.text,
      network: _selectedNetwork,
      category: _categoryController.text,
      email: _emailController.text.isEmpty ? null : _emailController.text,
      url: _urlController.text.isEmpty ? null : _urlController.text,
      note: _noteController.text.isEmpty ? null : _noteController.text,
      secret: _totpSecret,
      period: widget.item?.period ?? 30,
      isFavorite: widget.item?.isFavorite ?? false,
      passwordDuration: int.tryParse(_durationController.text),
      passwordLastChanged: widget.item?.passwordLastChanged ?? DateTime.now(),
      passwordHistory: widget.item?.passwordHistory,
      tags: _tags,
      sharedVaultId: _selectedSharedVaultId,
      isPinned: _isPinned,
      colorLabel: (_colorLabel?.isEmpty ?? true) ? null : _colorLabel,
      accounts: _extraAccounts
          .where((g) => g.usernameController.text.isNotEmpty)
          .map((g) {
            return AccountEntry(
              id: g.id.isEmpty ? const Uuid().v4() : g.id,
              username: g.usernameController.text,
              password: g.passwordController.text,
              label: g.labelController.text.isEmpty
                  ? null
                  : g.labelController.text,
              passwordHistory: g.passwordHistory,
              passwordLastChanged: g.passwordLastChanged,
            );
          })
          .toList(),
    );

    final action = (widget.item == null || widget.item!.id.isEmpty)
        ? ref.read(vaultItemsProvider.notifier).addItem(newItem)
        : ref.read(vaultItemsProvider.notifier).updateItem(newItem);

    action
        .then((_) {
          if (mounted) {
            Navigator.pop(context);
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(tr.saved)));
          }
        })
        .catchError((e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(tr.couldNotSave(e)),
                backgroundColor: Colors.red,
              ),
            );
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    final type = widget.item?.type ?? VaultItemType.password;
    final isCrypto = type == VaultItemType.crypto;
    final isSecureNote = type == VaultItemType.secureNote;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.item?.url != null || _urlController.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FaviconWidget(
                  url: _urlController.text.isNotEmpty
                      ? _urlController.text
                      : widget.item?.url,
                  title: _titleController.text.isNotEmpty
                      ? _titleController.text
                      : (widget.item?.title ?? ''),
                  size: 24,
                ),
              ),
            Text(
              (widget.item == null || widget.item!.id.isEmpty)
                  ? (isCrypto
                        ? tr.addWallet
                        : (isSecureNote ? tr.addNote : tr.addAccount))
                  : (isCrypto
                        ? tr.editWallet
                        : (isSecureNote ? tr.editNote : tr.editAccount)),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _save,
            icon: const Icon(Icons.check),
            tooltip: tr.save,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSection(context, tr.basicInformation, [
              _buildTextField(
                label: isCrypto
                    ? tr.walletName
                    : (isSecureNote ? tr.noteTitle : tr.accountName),
                controller: _titleController,
                isRequired: true,
                hintText: isCrypto
                    ? tr.eGMetamaskTrustWallet
                    : (isSecureNote
                          ? tr.eGCardDetailsReminder
                          : tr.eGGoogleGithub),
              ),
              if (!isCrypto && !isSecureNote)
                _buildTextField(
                  label: tr.username,
                  controller: _usernameController,
                  isRequired: true,
                  hintText: tr.usernameOrEmail,
                  autofillHints: const [
                    AutofillHints.username,
                    AutofillHints.email,
                  ],
                ),
              if (isCrypto)
                _buildTextField(
                  label: tr.walletAddress,
                  controller: _addressController,
                  hintText: '0x...',
                  suffixIcon: _isGeneratingAddress
                      ? const Padding(
                          padding: EdgeInsets.all(12.0),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(
                            Icons.auto_awesome_outlined,
                            size: 20,
                          ),
                          tooltip: tr.generatedFromThePrivateKeyOrRecovery,
                          onPressed: () {
                            _updateAddressFromPrivateKey();
                            _updateAddressFromMnemonic();
                          },
                        ),
                ),
              if (isCrypto)
                ListTile(
                  title: Text(tr.blockchainNetwork),
                  subtitle: Text(_selectedNetwork ?? tr.notSelected),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showNetworkPicker,
                ),
              if (!isCrypto && !isSecureNote)
                _buildTextField(
                  label: tr.password,
                  controller: _passwordController,
                  isPassword: _obscurePassword,
                  hintText: tr.accountPassword,
                  autofillHints: const [AutofillHints.password],
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        tooltip: _obscurePassword
                            ? tr.showPassword
                            : tr.hidePassword,
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy_rounded),
                        tooltip: tr.copyPassword,
                        onPressed: () {
                          if (_passwordController.text.isNotEmpty) {
                            Clipboard.setData(
                              ClipboardData(text: _passwordController.text),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(tr.passwordCopiedToClipboard),
                              ),
                            );
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.casino_outlined),
                        tooltip: tr.generateRandomPassword,
                        onPressed: () {
                          final newPassword = PasswordGenerator.generate(
                            length: 16,
                          );
                          setState(() {
                            _passwordController.text = newPassword;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ListTile(
                title: Text(tr.category),
                subtitle: Text(localizedCategory(_categoryController.text)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showCategoryPicker,
              ),
              _buildSharedVaultPicker(),
            ]),
            if (!isCrypto && !isSecureNote) ...[
              const SizedBox(height: 16),
              _buildSection(context, tr.additionalAccounts, [
                ..._extraAccounts.asMap().entries.map((entry) {
                  final index = entry.key;
                  final group = entry.value;
                  return Column(
                    children: [
                      if (index > 0) const Divider(),
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                          top: 8,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                tr.account(index + 2),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                color: Colors.red,
                              ),
                              onPressed: () => setState(
                                () => _extraAccounts.removeAt(index),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _buildTextField(
                        label: tr.note,
                        controller: group.labelController,
                        hintText: tr.accountPurposeEGWorkPersonal,
                      ),
                      _buildTextField(
                        label: tr.username,
                        controller: group.usernameController,
                        hintText: tr.usernameOrEmail,
                      ),
                      _buildTextField(
                        label: tr.password,
                        controller: group.passwordController,
                        isPassword: group.obscurePassword,
                        hintText: tr.accountPassword,
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                group.obscurePassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              tooltip: group.obscurePassword
                                  ? tr.showPassword
                                  : tr.hidePassword,
                              onPressed: () => setState(
                                () => group.obscurePassword =
                                    !group.obscurePassword,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy_rounded),
                              tooltip: tr.copyPassword,
                              onPressed: () {
                                if (group.passwordController.text.isNotEmpty) {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text: group.passwordController.text,
                                    ),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        tr.passwordCopiedToClipboard,
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.casino_outlined),
                              tooltip: tr.generateRandomPassword,
                              onPressed: () {
                                final newPassword = PasswordGenerator.generate(
                                  length: 16,
                                );
                                setState(
                                  () => group.passwordController.text =
                                      newPassword,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      if (group.passwordHistory != null &&
                          group.passwordHistory!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Row(
                            children: [
                              if (group.passwordLastChanged != null)
                                Expanded(
                                  child: Text(
                                    tr.lastModified(
                                      group.passwordLastChanged!
                                          .toString()
                                          .split('.')[0],
                                    ),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context).hintColor,
                                    ),
                                  ),
                                ),
                              TextButton.icon(
                                onPressed: () {
                                  final label = group.labelController.text;
                                  _showPasswordHistory(
                                    history: group.passwordHistory,
                                    title: tr.passwordHistoryFor(
                                      label.isNotEmpty
                                          ? label
                                          : tr.account(index + 2),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.history, size: 16),
                                label: Text(
                                  tr.history(group.passwordHistory!.length),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                }),
                ListTile(
                  leading: Icon(
                    Icons.add_circle_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(
                    tr.addAnotherAccount,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  onTap: () => setState(
                    () => _extraAccounts.add(_AccountControllerGroup()),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 16),
            if (isCrypto) ...[
              _buildSection(context, tr.privateKeyDetails, [
                _buildTextField(
                  label: tr.privateKey,
                  controller: _privateKeyController,
                  isPassword: _obscureMnemonic,
                  hintText: tr.enterWalletPrivateKey,
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          _obscureMnemonic
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        tooltip: _obscureMnemonic
                            ? tr.showPrivateKey
                            : tr.hidePrivateKey,
                        onPressed: () => setState(
                          () => _obscureMnemonic = !_obscureMnemonic,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy_rounded),
                        tooltip: tr.copyPrivateKey,
                        onPressed: () {
                          if (_privateKeyController.text.isNotEmpty) {
                            Clipboard.setData(
                              ClipboardData(text: _privateKeyController.text),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(tr.privateKeyCopiedToClipboard),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              _buildSection(context, tr.recoveryPhrase, [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                              childAspectRatio: 2.8, // 进一步调大比例以减小高度
                            ),
                        itemCount: 12,
                        itemBuilder: (context, index) {
                          return Container(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).dividerColor.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).dividerColor.withValues(alpha: 0.1),
                              ),
                            ),
                            child: Stack(
                              children: [
                                // 序号放在左上角，不占用 TextField 空间
                                Positioned(
                                  top: 4,
                                  left: 6,
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: 0.4),
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Center(
                                  child: RawAutocomplete<String>(
                                    textEditingController:
                                        _mnemonicControllers[index],
                                    focusNode: _mnemonicFocusNodes[index],
                                    optionsBuilder:
                                        (TextEditingValue textEditingValue) {
                                          if (textEditingValue.text.isEmpty ||
                                              _obscureMnemonic) {
                                            return const Iterable<
                                              String
                                            >.empty();
                                          }
                                          return Bip39Words.wordList.where((
                                            String option,
                                          ) {
                                            return option.startsWith(
                                              textEditingValue.text
                                                  .toLowerCase(),
                                            );
                                          });
                                        },
                                    fieldViewBuilder:
                                        (
                                          context,
                                          controller,
                                          focusNode,
                                          onFieldSubmitted,
                                        ) {
                                          return TextField(
                                            controller: controller,
                                            focusNode: focusNode,
                                            obscureText: _obscureMnemonic,
                                            textAlign:
                                                TextAlign.center, // 确保文字居中
                                            autocorrect: false,
                                            enableSuggestions: false,
                                            textInputAction: index < 11
                                                ? TextInputAction.next
                                                : TextInputAction.done,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.5,
                                            ),
                                            decoration: InputDecoration(
                                              border: InputBorder.none,
                                              isDense: true,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 8,
                                                  ),
                                              hintText: tr.word,
                                              hintStyle: TextStyle(
                                                fontSize: 14,
                                                color: Theme.of(context)
                                                    .hintColor
                                                    .withValues(alpha: 0.3),
                                              ),
                                            ),
                                          );
                                        },
                                    optionsViewBuilder: (context, onSelected, options) {
                                      return Align(
                                        alignment: Alignment.topLeft,
                                        child: Material(
                                          elevation: 4.0,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Container(
                                            width: 150,
                                            constraints: const BoxConstraints(
                                              maxHeight: 200,
                                            ),
                                            child: ListView.builder(
                                              padding: EdgeInsets.zero,
                                              shrinkWrap: true,
                                              itemCount: options.length,
                                              itemBuilder:
                                                  (
                                                    BuildContext context,
                                                    int index,
                                                  ) {
                                                    final String option =
                                                        options.elementAt(
                                                          index,
                                                        );
                                                    return InkWell(
                                                      onTap: () =>
                                                          onSelected(option),
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              12.0,
                                                            ),
                                                        child: Text(
                                                          option,
                                                          textAlign: TextAlign
                                                              .center, // 联想列表项也居中
                                                        ),
                                                      ),
                                                    );
                                                  },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isGeneratingAddress
                                  ? null
                                  : () async {
                                      // 1. 先更新 UI 状态显示加载动画
                                      setState(() {
                                        _isGeneratingAddress = true;
                                        _isUpdatingMnemonicBatch = true;
                                      });

                                      // 2. 稍微延迟一点点，给 UI 线程留出渲染“正在生成...”动画的时间
                                      await Future.delayed(
                                        const Duration(milliseconds: 50),
                                      );

                                      try {
                                        // 3. 在 Isolate 中生成助记词
                                        final randomMnemonic =
                                            await PasswordGenerator.generateMnemonic();
                                        final words = randomMnemonic.split(' ');

                                        if (mounted) {
                                          setState(() {
                                            for (int i = 0; i < 12; i++) {
                                              _mnemonicControllers[i].text =
                                                  words[i];
                                            }
                                            _obscureMnemonic = false;
                                          });
                                        }

                                        // 4. 计算地址 (已经在 Isolate 中)
                                        await _updateAddressFromMnemonic();
                                      } finally {
                                        if (mounted) {
                                          setState(() {
                                            _isUpdatingMnemonicBatch = false;
                                            _isGeneratingAddress = false;
                                          });
                                        }
                                      }
                                    },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: _isGeneratingAddress
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_fix_high, size: 20),
                              label: Text(
                                _isGeneratingAddress
                                    ? tr.generating
                                    : tr.generateRecoveryPhrase,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: IconButton(
                              icon: Icon(
                                _obscureMnemonic
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              onPressed: () => setState(
                                () => _obscureMnemonic = !_obscureMnemonic,
                              ),
                              tooltip: _obscureMnemonic ? tr.show : tr.hide,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
            ],
            if (!isCrypto)
              _buildSection(context, tr.securitySettings, [
                ListTile(
                  leading: const Icon(Icons.security),
                  title: Text(tr.twoFactorAuthenticationFa),
                  subtitle: Text(
                    _totpSecret == null
                        ? tr.notConfigured
                        : tr.configuredTapToEdit,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _show2FAConfig,
                ),
              ]),
            const SizedBox(height: 16),
            _buildSection(
              context,
              isSecureNote ? tr.noteContents : tr.optionalInformation,
              [
                if (!isCrypto && !isSecureNote)
                  _buildTextField(
                    label: tr.email,
                    controller: _emailController,
                    hintText: tr.linkedEmail,
                  ),
                if (!isCrypto && !isSecureNote)
                  _buildTextField(
                    label: tr.websitesDomains,
                    controller: _urlController,
                    hintText: tr.separateMultipleDomainsWithCommasOrSemicolons,
                    maxLines: 2,
                  ),
                _buildTextField(
                  label: isSecureNote ? tr.contents : tr.note,
                  controller: _noteController,
                  hintText: isSecureNote
                      ? tr.writeYourNoteHere
                      : tr.additionalInformation,
                  maxLines: isSecureNote ? 10 : 3,
                ),
                const SizedBox(height: 8),
                _buildTagsSection(),
              ],
            ),
            const SizedBox(height: 16),
            if (!isCrypto)
              _buildSection(context, tr.securitySettings, [
                _buildTextField(
                  label: tr.passwordExpiryDays,
                  controller: _durationController,
                  keyboardType: TextInputType.number,
                  hintText: tr.leaveBlankForNoExpiry,
                  suffixIcon: const Icon(Icons.timer_outlined),
                ),
                if (widget.item?.passwordLastChanged != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      tr.lastChanged(
                        widget.item!.passwordLastChanged!.toString().split(
                          '.',
                        )[0],
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ),
                if (widget.item?.passwordHistory != null &&
                    widget.item!.passwordHistory!.isNotEmpty)
                  ListTile(
                    title: Text(tr.viewPasswordHistory),
                    subtitle: Text(
                      tr.records(widget.item!.passwordHistory!.length),
                    ),
                    trailing: const Icon(Icons.history),
                    onTap: _showPasswordHistory,
                  ),
              ]),
            const SizedBox(height: 16),
            _buildSection(context, tr.displaySettings, [
              SwitchListTile(
                title: Text(tr.pin),
                subtitle: Text(tr.keepThisItemAtTheTopOf),
                secondary: const Icon(Icons.push_pin_outlined),
                value: _isPinned,
                onChanged: (v) => setState(() => _isPinned = v),
              ),
              ListTile(
                leading: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: (_colorLabel != null && _colorLabel!.isNotEmpty)
                        ? _getColorForLabel(_colorLabel!).withValues(alpha: 0.3)
                        : Colors.grey.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: (_colorLabel != null && _colorLabel!.isNotEmpty)
                          ? _getColorForLabel(_colorLabel!)
                          : Colors.grey,
                      width: 2,
                    ),
                  ),
                ),
                title: Text(tr.colorLabel),
                subtitle: Text(_colorLabel ?? tr.none),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showColorPicker(),
              ),
            ]),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Color _getColorForLabel(String label) {
    final map = <String, Color>{
      tr.red: Colors.red,
      tr.orange: Colors.orange,
      tr.yellow: Colors.amber,
      tr.green: Colors.green,
      tr.blue: Colors.blue,
      tr.purple: Colors.purple,
      tr.pink: Colors.pink,
      tr.cyan: Colors.teal,
    };
    return map[label] ?? Colors.grey;
  }

  void _showColorPicker() {
    final colors = <String, Color>{
      tr.red: Colors.red,
      tr.orange: Colors.orange,
      tr.yellow: Colors.amber,
      tr.green: Colors.green,
      tr.blue: Colors.blue,
      tr.purple: Colors.purple,
      tr.pink: Colors.pink,
      tr.cyan: Colors.teal,
    };

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.chooseColorLabel),
        content: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _buildColorChoice(ctx, null, tr.none, Colors.grey),
            ...colors.entries.map(
              (e) => _buildColorChoice(ctx, e.key, e.key, e.value),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorChoice(
    BuildContext ctx,
    String? value,
    String label,
    Color color,
  ) {
    final isSelected =
        _colorLabel == value || (_colorLabel == null && value == null);
    return InkWell(
      onTap: () {
        setState(() => _colorLabel = value);
        Navigator.pop(ctx);
      },
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(color: color, width: isSelected ? 3 : 2),
            ),
            child: value == null
                ? Icon(Icons.block, color: Colors.grey[400], size: 20)
                : (isSelected
                      ? Icon(Icons.check, color: color, size: 20)
                      : null),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildTagsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.tags, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ..._tags.map(
                (tag) => Chip(
                  label: Text(tag, style: const TextStyle(fontSize: 12)),
                  onDeleted: () {
                    setState(() {
                      _tags.remove(tag);
                    });
                  },
                  deleteIconColor: Colors.red,
                  padding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              ActionChip(
                label: const Icon(Icons.add, size: 16),
                onPressed: _showAddTagDialog,
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(tr.addTag),
          content: TextField(
            controller: _tagInputController,
            autofocus: true,
            decoration: InputDecoration(hintText: tr.enterTagName),
            onSubmitted: (value) {
              if (value.isNotEmpty) {
                setState(() {
                  if (!_tags.contains(value)) {
                    _tags.add(value);
                  }
                  _tagInputController.clear();
                });
                Navigator.pop(context);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.cancel),
            ),
            TextButton(
              onPressed: () {
                final value = _tagInputController.text;
                if (value.isNotEmpty) {
                  setState(() {
                    if (!_tags.contains(value)) {
                      _tags.add(value);
                    }
                    _tagInputController.clear();
                  });
                }
                Navigator.pop(context);
              },
              child: Text(tr.confirm),
            ),
          ],
        );
      },
    );
  }

  void _showPasswordHistory({
    List<PasswordHistoryEntry>? history,
    String? title,
  }) {
    final displayHistory = (history ?? widget.item?.passwordHistory ?? [])
        .reversed
        .toList();
    if (displayHistory.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.4,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  title ?? tr.passwordHistory,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: displayHistory.length,
                    itemBuilder: (context, index) {
                      final entry = displayHistory[index];
                      return ListTile(
                        title: Text(
                          entry.password,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Text(
                          entry.changedAt.toString().split('.')[0],
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.copy_rounded, size: 20),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: entry.password),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(tr.copiedToClipboard)),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSection(
    BuildContext context,
    String title,
    List<Widget> children,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: children.asMap().entries.map((entry) {
              final index = entry.key;
              final child = entry.value;
              return Column(
                children: [
                  child,
                  if (index < children.length - 1)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool isRequired = false,
    bool isPassword = false,
    String? hintText,
    int maxLines = 1,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    List<String>? autofillHints,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: controller,
        obscureText: isPassword,
        maxLines: maxLines,
        keyboardType: keyboardType,
        autofillHints: autofillHints,
        decoration: InputDecoration(
          labelText: isRequired ? '$label *' : label,
          hintText: hintText,
          border: InputBorder.none,
          isDense: true,
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }

  void _showNetworkPicker() {
    final networks = ref.read(networksProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                tr.chooseBlockchainNetwork,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: networks.length + 1,
                itemBuilder: (context, index) {
                  if (index == networks.length) {
                    return ListTile(
                      leading: const Icon(Icons.add),
                      title: Text(tr.addNetwork),
                      onTap: () {
                        Navigator.pop(context);
                        _showAddNetworkDialog();
                      },
                    );
                  }
                  final network = networks[index];
                  return ListTile(
                    title: Text(network),
                    trailing: _selectedNetwork == network
                        ? const Icon(Icons.check, color: Colors.blue)
                        : null,
                    onTap: () {
                      setState(() {
                        _selectedNetwork = network;
                      });
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddNetworkDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.addNetwork),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr.enterNetworkNameEGArbitrum),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _selectedNetwork = controller.text;
                });
              }
              Navigator.pop(context);
            },
            child: Text(tr.confirm),
          ),
        ],
      ),
    );
  }

  Widget _buildSharedVaultPicker() {
    final sharedVaultsAsync = ref.watch(sharedVaultsProvider);

    return sharedVaultsAsync.when(
      data: (vaults) {
        if (vaults.isEmpty) return const SizedBox.shrink();

        String subtitle = tr.personalVault;
        if (_selectedSharedVaultId != null) {
          try {
            final vault = vaults.firstWhere(
              (v) => v.id == _selectedSharedVaultId,
            );
            subtitle = tr.sharedVault(vault.name);
          } catch (_) {
            _selectedSharedVaultId = null;
          }
        }

        return ListTile(
          leading: const Icon(Icons.folder_shared_outlined),
          title: Text(tr.saveLocation),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showSharedVaultPicker(vaults),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  void _showSharedVaultPicker(List<SharedVault> vaults) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr.chooseSaveLocation,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(tr.personalVaultDefault),
                trailing: _selectedSharedVaultId == null
                    ? const Icon(Icons.check, color: Colors.blue)
                    : null,
                onTap: () {
                  setState(() => _selectedSharedVaultId = null);
                  Navigator.pop(context);
                },
              ),
              ...vaults.map(
                (vault) => ListTile(
                  leading: const Icon(Icons.folder_shared_outlined),
                  title: Text(vault.name),
                  trailing: _selectedSharedVaultId == vault.id
                      ? const Icon(Icons.check, color: Colors.blue)
                      : null,
                  onTap: () {
                    setState(() => _selectedSharedVaultId = vault.id);
                    Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showCategoryPicker() {
    final categories = ref.read(categoriesProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr.chooseCategory,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: categories.length + 1,
                itemBuilder: (context, index) {
                  if (index == categories.length) {
                    return ListTile(
                      leading: const Icon(Icons.add),
                      title: Text(tr.addCategory),
                      onTap: () {
                        Navigator.pop(context);
                        _showAddCategoryDialog();
                      },
                    );
                  }
                  final category = categories[index];
                  return ListTile(
                    title: Text(localizedCategory(category)),
                    trailing: _categoryController.text == category
                        ? const Icon(Icons.check, color: Colors.blue)
                        : null,
                    onTap: () {
                      setState(() {
                        _categoryController.text = category;
                      });
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddCategoryDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.addCategory),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr.enterCategoryName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() {
                  _categoryController.text = controller.text;
                });
              }
              Navigator.pop(context);
            },
            child: Text(tr.confirm),
          ),
        ],
      ),
    );
  }

  void _show2FAConfig() {
    final controller = TextEditingController(text: _totpSecret);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.configureFa),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z2-7\s]')),
          ],
          decoration: InputDecoration(
            labelText: tr.secretKey,
            hintText: 'JBSWY3DPEHPK3PXP',
            helperText: tr.usuallyOrCharacters,
            suffixIcon: IconButton(
              icon: const Icon(Icons.copy_rounded, size: 20),
              tooltip: tr.copySecretKey,
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  Clipboard.setData(
                    ClipboardData(text: controller.text.replaceAll(' ', '')),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(tr.secretKeyCopiedToClipboard)),
                  );
                }
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _totpSecret = null;
              });
              Navigator.pop(context);
            },
            child: Text(tr.clear, style: const TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              final secret = controller.text.replaceAll(' ', '').toUpperCase();
              setState(() {
                _totpSecret = secret.isEmpty ? null : secret;
              });
              Navigator.pop(context);
            },
            child: Text(tr.confirm),
          ),
        ],
      ),
    );
  }
}

class _AccountControllerGroup {
  final String id;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController labelController;
  final List<PasswordHistoryEntry>? passwordHistory;
  final DateTime? passwordLastChanged;
  bool obscurePassword = true;

  _AccountControllerGroup({
    String? id,
    String? username,
    String? password,
    String? label,
    this.passwordHistory,
    this.passwordLastChanged,
  }) : id = id ?? '',
       usernameController = TextEditingController(text: username),
       passwordController = TextEditingController(text: password),
       labelController = TextEditingController(text: label);

  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    labelController.dispose();
  }
}
