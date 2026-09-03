import 'package:bip39/bip39.dart' as bip39;
import 'package:web3dart/web3dart.dart';
import 'package:bip32/bip32.dart' as bip32;
import 'package:hex/hex.dart';
import 'package:flutter/foundation.dart';

class CryptoUtils {
  /// 从私钥生成以太坊地址
  static String? getEthAddressFromPrivateKey(String privateKey) {
    try {
      // 移除 0x 前缀
      String cleanKey = privateKey.trim().startsWith('0x')
          ? privateKey.trim().substring(2)
          : privateKey.trim();
      if (cleanKey.length != 64) return null;

      final credentials = EthPrivateKey.fromHex(cleanKey);
      return credentials.address.hexEip55;
    } catch (e) {
      return null;
    }
  }

  /// 从助记词生成私钥 (标准路径 m/44'/60'/0'/0/0)
  static Future<String?> getPrivateKeyFromMnemonic(String mnemonic) async {
    try {
      final cleanMnemonic = mnemonic.trim();
      if (!bip39.validateMnemonic(cleanMnemonic)) return null;

      return await compute(_derivePrivateKeyTask, cleanMnemonic);
    } catch (e) {
      return null;
    }
  }

  /// 内部任务函数，在 Isolate 中运行
  static String? _derivePrivateKeyTask(String mnemonic) {
    try {
      final seed = bip39.mnemonicToSeed(mnemonic);
      final root = bip32.BIP32.fromSeed(seed);
      final child = root.derivePath("m/44'/60'/0'/0/0");
      if (child.privateKey == null) return null;
      return HEX.encode(child.privateKey!);
    } catch (e) {
      return null;
    }
  }

  /// 内部任务函数，在 Isolate 中运行，同时返回地址和私钥
  static Map<String, String?> _deriveAllTask(String mnemonic) {
    try {
      final seed = bip39.mnemonicToSeed(mnemonic);
      final root = bip32.BIP32.fromSeed(seed);
      final child = root.derivePath("m/44'/60'/0'/0/0");

      if (child.privateKey == null)
        return {'address': null, 'privateKey': null};

      final privateKeyHex = HEX.encode(child.privateKey!);
      final credentials = EthPrivateKey.fromHex(privateKeyHex);
      final address = credentials.address.hexEip55;

      return {'address': address, 'privateKey': privateKeyHex};
    } catch (e) {
      return {'address': null, 'privateKey': null};
    }
  }

  /// 从助记词同步生成地址和私钥
  static Future<Map<String, String?>> getAllFromMnemonic(
    String mnemonic,
  ) async {
    try {
      final cleanMnemonic = mnemonic.trim();
      if (!bip39.validateMnemonic(cleanMnemonic))
        return {'address': null, 'privateKey': null};

      return await compute(_deriveAllTask, cleanMnemonic);
    } catch (e) {
      return {'address': null, 'privateKey': null};
    }
  }

  /// 通用生成逻辑
  static Future<String?> generateAddress({
    String? privateKey,
    String? mnemonic,
    String network = 'ETH',
  }) async {
    // 目前仅支持 ETH/EVM 兼容网络
    if (privateKey != null && privateKey.trim().isNotEmpty) {
      return getEthAddressFromPrivateKey(privateKey);
    } else if (mnemonic != null && mnemonic.trim().isNotEmpty) {
      final result = await getAllFromMnemonic(mnemonic);
      return result['address'];
    }
    return null;
  }
}
