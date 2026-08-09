import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'about.dart';
import 'receiver_page.dart';
import 'sender_page.dart';


final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

const _themeKey = 'beamcam.theme';

extension ThemeModeLabel on ThemeMode {
  String get label => switch (this) {
    ThemeMode.system => 'Match system',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  IconData get icon => switch (this) {
    ThemeMode.system => Icons.brightness_auto_outlined,
    ThemeMode.light => Icons.light_mode_outlined,
    ThemeMode.dark => Icons.dark_mode_outlined,
  };
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeMode.value = mode;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_themeKey, mode.name);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();


  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // Read before the first frame so a saved choice never flashes the wrong
  // theme on launch.
  await loadVersion();

  final saved = (await SharedPreferences.getInstance()).getString(_themeKey);
  themeMode.value = ThemeMode.values.firstWhere(
    (m) => m.name == saved,
    orElse: () => ThemeMode.system,
  );

  runApp(const BeamCamApp());
}


bool get _isSender => Platform.isAndroid || Platform.isIOS;

class BeamCamApp extends StatelessWidget {
  const BeamCamApp({super.key});

  static const _seed = Color(0xFF0B57D0); // Material blue, AOSP default

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'BeamCam',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: _isSender ? const SenderPage() : const ReceiverPage(),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
    );
  }
}
