import 'package:otp/otp.dart';

class TotpEngine {
  // 生成 6 位验证码并格式化为 "123 456"
  static String generateCode(String secret, {int interval = 30}) {
    if (secret.isEmpty) return "------";
    
    try {
      // 移除所有空格并转为大写（Base32 标准要求）
      final normalizedSecret = secret.replaceAll(' ', '').toUpperCase();
      
      final code = OTP.generateTOTPCodeString(
        normalizedSecret,
        DateTime.now().millisecondsSinceEpoch,
        interval: interval,
        algorithm: Algorithm.SHA1,
        isGoogle: true,
      );
      // 3+3 分组
      if (code.length == 6) {
        return "${code.substring(0, 3)} ${code.substring(3, 6)}";
      }
      return code;
    } catch (e) {
      return "--- ---";
    }
  }

  // 计算剩余时间进度 (0.0 到 1.0)
  static double getProgress(int interval) {
    final seconds = (DateTime.now().millisecondsSinceEpoch / 1000).floor() % interval;
    return (interval - seconds) / interval;
  }
}
