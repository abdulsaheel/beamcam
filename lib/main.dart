import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'receiver_page.dart';
import 'sender_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Draw behind the status and navigation bars, and make both transparent, so
  // the app's own background reaches every edge instead of leaving black strips
  // beside the content.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  runApp(const BeamCamApp());
}

/// One codebase, two roles. The phone captures, the desktop receives.
/// Role is picked from the host platform rather than a setting, because a
/// desktop build has no camera worth sending and a phone build has no virtual
/// camera to feed.
bool get _isSender => Platform.isAndroid || Platform.isIOS;

class BeamCamApp extends StatelessWidget {
  const BeamCamApp({super.key});

  static const _seed = Color(0xFF0B57D0); // Material blue, AOSP default

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BeamCam',
      debugShowCheckedModeBanner: false,
      // Follows the system rather than forcing a look. Stock Material in both
      // modes: no bespoke palette, no custom type scale.
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: _isSender ? const SenderPage() : const ReceiverPage(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // The desktop receiver still wants a dark stage for video; it sets that
      // locally rather than dragging the whole app dark.
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
