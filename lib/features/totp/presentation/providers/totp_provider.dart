import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/totp_engine.dart';

// 订阅秒针的 Provider
final tickerProvider = StreamProvider<int>((ref) {
  return Stream.periodic(const Duration(seconds: 1), (i) => i);
});

final totpProgressProvider = Provider.family<double, int>((ref, period) {
  ref.watch(tickerProvider);
  return TotpEngine.getProgress(period);
});
