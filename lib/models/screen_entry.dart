/// Modèle représentant une capture de texte depuis l'AccessibilityService
class ScreenEntry {
  final DateTime timestamp;

  /// Liste des textes visibles capturés à cet instant
  final List<String> texts;

  /// Nom du package source (com.eflexfuel.app)
  final String packageName;

  ScreenEntry({
    required this.timestamp,
    required this.texts,
    required this.packageName,
  });

  /// Concatène tous les textes avec le séparateur " | "
  String get displayText => texts.join(' | ');

  /// Sérialisation JSON pour l'export des logs
  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'texts': texts,
        'package': packageName,
      };
}
