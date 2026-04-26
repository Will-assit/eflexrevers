import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/ble_packet.dart';
import '../models/screen_entry.dart';
import '../models/uuid_info.dart';
import 'settings_service.dart';

/// Service d'analyse des données BLE via l'API Claude (Anthropic)
class ClaudeService {
  static const String _apiUrl = 'https://api.anthropic.com/v1/messages';
  static const String _model = 'claude-opus-4-5';
  static const String _apiVersion = '2023-06-01';

  final SettingsService _settings;

  ClaudeService(this._settings);

  /// Analyse la corrélation entre les paquets BLE et les captures d'écran
  Future<String> analyzeCorrelation(
    List<BlePacket> blePackets,
    List<ScreenEntry> screenEntries,
  ) async {
    if (_settings.apiKey.isEmpty) {
      throw Exception('Clé API manquante. Configurez-la dans les Réglages.');
    }

    // Construction du contexte BLE (N derniers paquets)
    final bleLines = blePackets
        .take(_settings.maxBlePackets)
        .map((p) {
          final sb = StringBuffer();
          sb.write('${_fmtTime(p.timestamp)} [${p.shortUuid}] HEX:${p.hexValue}');
          if (p.asciiValue.isNotEmpty) sb.write(' ASCII:${p.asciiValue}');
          if (p.uint8Value != null) sb.write(' u8:${p.uint8Value}');
          if (p.uint16Value != null) sb.write(' u16:${p.uint16Value}');
          if (p.float32Value != null) {
            sb.write(' f32:${p.float32Value!.toStringAsFixed(3)}');
          }
          return sb.toString();
        })
        .join('\n');

    // Construction du contexte écran (M dernières entrées)
    final screenLines = screenEntries
        .take(_settings.maxScreenEntries)
        .map((e) => '${_fmtTime(e.timestamp)} ${e.displayText}')
        .join('\n');

    final langInstruction = _settings.claudeLanguage == 'FR'
        ? 'Réponds en français.'
        : 'Reply in English.';

    final userMessage = '''
$langInstruction

## Données BLE reçues (${blePackets.length} paquets, ${blePackets.map((p) => p.uuid).toSet().length} UUID distinctes) :
$bleLines

## Textes capturés sur l'écran eFlexApp (${screenEntries.length} entrées) :
$screenLines

Analyse ces données et identifie :
1. Quelles UUID correspondent à quelles fonctions (taux éthanol, température, mode, statut…)
2. Comment décoder les valeurs HEX (format bytes, unité, facteur d'échelle, plage)
3. Les corrélations temporelles entre les valeurs BLE et ce qui est affiché dans l'app
4. Tout pattern ou anomalie remarquable dans le protocole
''';

    final response = await http
        .post(
          Uri.parse(_apiUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': _settings.apiKey,
            'anthropic-version': _apiVersion,
          },
          body: jsonEncode({
            'model': _model,
            'max_tokens': 4096,
            'system': _settings.systemPrompt,
            'messages': [
              {'role': 'user', 'content': userMessage},
            ],
          }),
        )
        .timeout(const Duration(seconds: 30));

    return _handleResponse(response);
  }

  /// Teste la connexion à l'API avec un message minimal
  Future<bool> testConnection() async {
    if (_settings.apiKey.isEmpty) return false;

    try {
      final response = await http
          .post(
            Uri.parse(_apiUrl),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': _settings.apiKey,
              'anthropic-version': _apiVersion,
            },
            body: jsonEncode({
              'model': _model,
              'max_tokens': 5,
              'messages': [
                {'role': 'user', 'content': 'ping'},
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Analyse une UUID spécifique pour enrichir la Protocol Map
  Future<Map<String, String>> analyzeUuid(UuidInfo uuidInfo) async {
    if (_settings.apiKey.isEmpty) {
      throw Exception('Clé API manquante.');
    }

    final samples = uuidInfo.packets
        .take(10)
        .map((p) => p.hexValue)
        .toSet()
        .join(' | ');

    final message = '''
UUID BLE à analyser : ${uuidInfo.uuid}
Exemples de valeurs HEX observées : $samples
Plage numérique : ${uuidInfo.minValue?.toStringAsFixed(2) ?? 'N/A'} → ${uuidInfo.maxValue?.toStringAsFixed(2) ?? 'N/A'}
Nombre de paquets reçus : ${uuidInfo.packets.length}

Contexte : système d'injection éthanol pour moto (eFlexFuel).
Identifie le type de donnée de cette caractéristique BLE.
Réponds UNIQUEMENT en JSON valide avec ces champs : {"suggestedName":"...","dataType":"...","explanation":"..."}
''';

    final response = await http
        .post(
          Uri.parse(_apiUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': _settings.apiKey,
            'anthropic-version': _apiVersion,
          },
          body: jsonEncode({
            'model': _model,
            'max_tokens': 300,
            'system': _settings.systemPrompt,
            'messages': [
              {'role': 'user', 'content': message},
            ],
          }),
        )
        .timeout(const Duration(seconds: 15));

    final text = _handleResponse(response);

    // Extraction du JSON de la réponse Claude
    final match = RegExp(r'\{[^}]+\}', dotAll: true).firstMatch(text);
    if (match != null) {
      try {
        final json = jsonDecode(match.group(0)!) as Map<String, dynamic>;
        return {
          'suggestedName': json['suggestedName']?.toString() ?? 'Inconnu',
          'dataType': json['dataType']?.toString() ?? 'inconnu',
          'explanation': json['explanation']?.toString() ?? '',
        };
      } catch (_) {}
    }

    return {
      'suggestedName': 'Inconnu',
      'dataType': 'inconnu',
      'explanation': text,
    };
  }

  /// Interprète la réponse HTTP et lève des exceptions explicites
  String _handleResponse(http.Response response) {
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['content'] as List).first['text'] as String;
    }

    String errorMsg;
    try {
      final err = jsonDecode(response.body) as Map<String, dynamic>;
      errorMsg = err['error']?['message']?.toString() ?? 'Erreur inconnue';
    } catch (_) {
      errorMsg = response.body;
    }

    switch (response.statusCode) {
      case 401:
        throw Exception('Clé API invalide. Vérifiez vos Réglages.');
      case 429:
        throw Exception('Limite de débit atteinte. Réessayez dans quelques instants.');
      case 529:
        throw Exception('API surchargée. Réessayez plus tard.');
      default:
        throw Exception('Erreur API ${response.statusCode} : $errorMsg');
    }
  }

  /// Formate un DateTime en HH:mm:ss.ms
  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}.'
      '${dt.millisecond.toString().padLeft(3, '0')}';
}
