import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_accessibility_service/accessibility_event.dart';
import 'package:flutter_accessibility_service/flutter_accessibility_service.dart';
import '../models/screen_entry.dart';
import 'settings_service.dart';

/// Service de capture des textes affichés dans l'eFlexApp via AccessibilityService
class AccessibilityService extends ChangeNotifier {
  final SettingsService _settings;

  AccessibilityService(this._settings);

  /// Package cible : seuls les événements de cette app sont traités
  static const String _targetPackage = 'com.eflexfuel.app';

  bool _isEnabled = false;
  bool _isListening = false;
  final List<ScreenEntry> _entries = [];
  StreamSubscription<AccessibilityEvent>? _subscription;

  // Getters publics
  bool get isEnabled => _isEnabled;
  bool get isListening => _isListening;
  List<ScreenEntry> get entries => List.unmodifiable(_entries);
  int get entryCount => _entries.length;

  /// Vérifie si le service d'accessibilité est activé dans les paramètres Android
  Future<bool> checkEnabled() async {
    try {
      _isEnabled =
          await FlutterAccessibilityService.isAccessibilityPermissionEnabled();
      notifyListeners();
      return _isEnabled;
    } catch (e) {
      debugPrint('[Accessibilité] Erreur vérification permission : $e');
      return false;
    }
  }

  /// Ouvre la page des paramètres d'accessibilité Android
  Future<void> requestPermission() async {
    try {
      await FlutterAccessibilityService.requestAccessibilityPermission();
      // Revérification après retour de l'utilisateur
      await Future.delayed(const Duration(milliseconds: 500));
      await checkEnabled();
    } catch (e) {
      debugPrint('[Accessibilité] Erreur ouverture paramètres : $e');
    }
  }

  /// Démarre l'écoute des événements d'accessibilité
  void startListening() {
    if (_isListening) return;

    try {
      _subscription =
          FlutterAccessibilityService.accessStream.listen(
        (AccessibilityEvent event) {
          // Filtre uniquement les événements de l'eFlexApp
          if (event.packageName != _targetPackage) return;
          _processEvent(event);
        },
        onError: (e) {
          debugPrint('[Accessibilité] Erreur stream : $e');
        },
      );
      _isListening = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[Accessibilité] Erreur démarrage écoute : $e');
    }
  }

  /// Arrête l'écoute des événements
  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
    _isListening = false;
    notifyListeners();
  }

  /// Traite un événement d'accessibilité et extrait tous les textes visibles
  void _processEvent(AccessibilityEvent event) {
    final texts = <String>[];

    // Texte principal du nœud
    if (event.text != null && event.text!.isNotEmpty && event.text != 'null') {
      texts.add(event.text!);
    }

    // Textes des nœuds enfants (sous-éléments de l'interface)
    _extractSubNodeTexts(event.subNodes, texts);

    if (texts.isEmpty) return;

    // Déduplication : éviter d'ajouter la même entrée deux fois de suite
    if (_entries.isNotEmpty && _entries.first.displayText == texts.join(' | ')) {
      return;
    }

    _addEntry(texts, event.packageName ?? _targetPackage);
  }

  /// Extrait récursivement les textes des nœuds enfants
  void _extractSubNodeTexts(
      List<AccessibilityEvent>? nodes, List<String> texts) {
    if (nodes == null) return;
    for (final node in nodes) {
      if (node.text != null &&
          node.text!.isNotEmpty &&
          node.text != 'null' &&
          !texts.contains(node.text)) {
        texts.add(node.text!);
      }
      _extractSubNodeTexts(node.subNodes, texts);
    }
  }

  /// Ajoute une nouvelle entrée de capture à la liste
  void _addEntry(List<String> texts, String packageName) {
    final entry = ScreenEntry(
      timestamp: DateTime.now(),
      texts: List.unmodifiable(texts),
      packageName: packageName,
    );

    _entries.insert(0, entry);

    // Respect de la limite mémoire configurée
    if (_entries.length > _settings.maxLogsMemory) {
      _entries.removeRange(_settings.maxLogsMemory, _entries.length);
    }

    notifyListeners();
  }

  /// Efface toutes les entrées capturées
  void clearEntries() {
    _entries.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
