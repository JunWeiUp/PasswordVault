import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final selectedTabProvider = StateProvider<int>((ref) => 0);
final searchQueryProvider = StateProvider<String>((ref) => '');
final isSearchingProvider = StateProvider<bool>((ref) => false);

// --- Theme ---

enum SortMode { nameAsc, nameDesc, updatedDesc, updatedAsc }

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt('theme_mode') ?? 0;
    state = ThemeMode.values[index];
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_mode', mode.index);
  }
}

// --- Sort ---

final sortModeProvider = StateNotifierProvider<SortModeNotifier, SortMode>((ref) {
  return SortModeNotifier();
});

class SortModeNotifier extends StateNotifier<SortMode> {
  SortModeNotifier() : super(SortMode.updatedDesc) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt('sort_mode') ?? 2;
    if (index < SortMode.values.length) {
      state = SortMode.values[index];
    }
  }

  Future<void> setSortMode(SortMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sort_mode', mode.index);
  }
}

// --- Multi-Select ---

final isMultiSelectProvider = StateProvider<bool>((ref) => false);
final selectedItemIdsProvider = StateProvider<Set<String>>((ref) => {});
