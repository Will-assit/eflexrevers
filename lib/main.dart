import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/accessibility_service.dart';
import 'services/ble_service.dart';
import 'services/claude_service.dart';
import 'services/hci_snoop_service.dart';
import 'services/settings_service.dart';
import 'screens/main_screen.dart';

/// Point d'entrée de l'application eFlexReverse
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Chargement des réglages persistants avant le démarrage de l'UI
  final settingsService = SettingsService();
  await settingsService.init();

  runApp(
    MultiProvider(
      providers: [
        // Réglages — toujours disponibles en premier
        ChangeNotifierProvider<SettingsService>.value(value: settingsService),

        // Service BLE — dépend des réglages pour le timeout et le filtre
        ChangeNotifierProxyProvider<SettingsService, BleService>(
          create: (ctx) => BleService(ctx.read<SettingsService>()),
          update: (ctx, settings, previous) =>
              previous ?? BleService(settings),
        ),

        // Service d'accessibilité — dépend des réglages pour la limite mémoire
        ChangeNotifierProxyProvider<SettingsService, AccessibilityService>(
          create: (ctx) => AccessibilityService(ctx.read<SettingsService>()),
          update: (ctx, settings, previous) =>
              previous ?? AccessibilityService(settings),
        ),

        // Service Claude — dépend des réglages pour la clé API et le prompt
        ProxyProvider<SettingsService, ClaudeService>(
          create: (ctx) => ClaudeService(ctx.read<SettingsService>()),
          update: (ctx, settings, previous) =>
              previous ?? ClaudeService(settings),
        ),

        // Service HCI Snoop — lecture passive du fichier btsnoop_hci.log
        ChangeNotifierProxyProvider<SettingsService, HciSnoopService>(
          create: (ctx) => HciSnoopService(ctx.read<SettingsService>()),
          update: (ctx, settings, previous) =>
              previous ?? HciSnoopService(settings),
        ),
      ],
      child: const EflexReverseApp(),
    ),
  );
}

/// Widget racine de l'application
class EflexReverseApp extends StatelessWidget {
  const EflexReverseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eFlexReverse',
      debugShowCheckedModeBanner: false,
      theme: _buildDarkTheme(),
      // Démarre directement sur l'écran principal (pas de connexion BLE requise)
      home: const MainScreen(),
    );
  }

  /// Thème sombre personnalisé : fond #1A1A1A, accent orange #FF6600
  ThemeData _buildDarkTheme() {
    const orange = Color(0xFFFF6600);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF1A1A1A),
      cardColor: const Color(0xFF333333),

      colorScheme: const ColorScheme.dark(
        primary: orange,
        secondary: orange,
        surface: Color(0xFF2A2A2A),
        onSurface: Colors.white,
        onPrimary: Colors.white,
      ),

      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF2A2A2A),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),

      // Texte : blanc principal, gris secondaire
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.white),
        bodyMedium: TextStyle(color: Colors.white),
        bodySmall: TextStyle(color: Color(0xFFAAAAAA)),
        labelLarge: TextStyle(color: Colors.white),
      ),

      // Boutons flottants orange
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: orange,
        foregroundColor: Colors.white,
      ),

      // Sliders orange
      sliderTheme: const SliderThemeData(
        activeTrackColor: orange,
        thumbColor: orange,
        overlayColor: Color(0x33FF6600),
        inactiveTrackColor: Color(0xFF444444),
      ),

      // Cartes avec fond légèrement surélevé
      cardTheme: CardThemeData(
        color: const Color(0xFF2A2A2A),
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),

      // Champs de saisie cohérents avec le thème sombre
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF333333),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        labelStyle: const TextStyle(color: Color(0xFFAAAAAA)),
        hintStyle: const TextStyle(color: Color(0xFF555555)),
      ),

      // Boutons ElevatedButton avec style orange par défaut
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: orange,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),

      // Snackbars sombres
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF333333),
        contentTextStyle: TextStyle(color: Colors.white),
      ),
    );
  }
}
