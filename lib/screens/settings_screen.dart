import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/accessibility_service.dart' as acc_svc;
import '../services/claude_service.dart';
import '../services/hci_snoop_service.dart';
import '../services/settings_service.dart';

/// Écran de configuration de l'application
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _orange = Color(0xFFFF6600);

  // Contrôleurs de saisie
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _nameFilterCtrl;
  late TextEditingController _systemPromptCtrl;
  late TextEditingController _snoopFilePathCtrl;

  bool _apiKeyVisible = false;
  bool _isTesting = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsService>();
    _apiKeyCtrl = TextEditingController(text: s.apiKey);
    _nameFilterCtrl = TextEditingController(text: s.nameFilter);
    _systemPromptCtrl = TextEditingController(text: s.systemPrompt);
    _snoopFilePathCtrl = TextEditingController(text: s.snoopFilePath);
  }

  @override
  void dispose() {
    _apiKeyCtrl.dispose();
    _nameFilterCtrl.dispose();
    _systemPromptCtrl.dispose();
    _snoopFilePathCtrl.dispose();
    super.dispose();
  }

  // ─── Sélecteur de fichier btsnoop ─────────────────────────────────────────

  Future<void> _pickSnoopFile() async {
    final settings = context.read<SettingsService>();
    final snoop = context.read<HciSnoopService>();

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['log'],
      allowMultiple: false,
    );

    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Impossible d\'obtenir le chemin — accordez d\'abord '
              '"Accès à tous les fichiers" dans les Paramètres.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    _snoopFilePathCtrl.text = path;
    await settings.setSnoopFilePath(path);
    snoop.stop();
    await snoop.start();
  }

  // ─── Test de connexion API ─────────────────────────────────────────────────

  Future<void> _testApiConnection() async {
    final settings = context.read<SettingsService>();
    final claude = context.read<ClaudeService>();
    await settings.setApiKey(_apiKeyCtrl.text.trim());

    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    try {
      final ok = await claude.testConnection();
      setState(
          () => _testResult = ok ? '✅ Connexion réussie' : '❌ Clé invalide');
    } catch (e) {
      setState(() => _testResult = '❌ Erreur : $e');
    } finally {
      setState(() => _isTesting = false);
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final accService = context.watch<acc_svc.AccessibilityService>();

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text('Réglages',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Section API Claude ───────────────────────────────────────────
          _sectionHeader('API Claude', Icons.psychology),
          _card(children: [
            // Champ clé API
            TextField(
              controller: _apiKeyCtrl,
              obscureText: !_apiKeyVisible,
              style: const TextStyle(
                  color: Colors.white, fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Clé API Anthropic',
                labelStyle: const TextStyle(color: Color(0xFFAAAAAA)),
                hintText: 'sk-ant-…',
                hintStyle: const TextStyle(color: Color(0xFF555555)),
                filled: true,
                fillColor: const Color(0xFF333333),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none),
                suffixIcon: IconButton(
                  icon: Icon(
                    _apiKeyVisible
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: const Color(0xFFAAAAAA),
                  ),
                  onPressed: () =>
                      setState(() => _apiKeyVisible = !_apiKeyVisible),
                ),
              ),
              onChanged: (v) => settings.setApiKey(v.trim()),
            ),
            const SizedBox(height: 10),
            // Bouton test + résultat
            Row(
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _orange,
                      foregroundColor: Colors.white),
                  icon: _isTesting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.wifi_tethering, size: 16),
                  label: const Text('Tester la connexion'),
                  onPressed: _isTesting ? null : _testApiConnection,
                ),
                if (_testResult != null) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(_testResult!,
                        style: TextStyle(
                          color: _testResult!.startsWith('✅')
                              ? Colors.greenAccent
                              : Colors.red.shade300,
                          fontSize: 12,
                        )),
                  ),
                ],
              ],
            ),
          ]),

          // ── Section BLE ──────────────────────────────────────────────────
          _sectionHeader('Bluetooth BLE', Icons.bluetooth),
          _card(children: [
            // Timeout de scan
            _sliderRow(
              label: 'Timeout scan',
              value: settings.scanTimeout.toDouble(),
              min: 5,
              max: 30,
              divisions: 25,
              unit: 's',
              onChanged: (v) => settings.setScanTimeout(v.round()),
            ),
            // Auto-reconnexion
            _switchRow(
              label: 'Auto-reconnexion',
              subtitle: 'Reconnecte automatiquement si déconnecté',
              value: settings.autoReconnect,
              onChanged: settings.setAutoReconnect,
            ),
            // Filtre nom
            const SizedBox(height: 8),
            TextField(
              controller: _nameFilterCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Filtre nom appareil',
                labelStyle: const TextStyle(color: Color(0xFFAAAAAA)),
                hintText: 'eflex',
                filled: true,
                fillColor: const Color(0xFF333333),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none),
              ),
              onChanged: (v) => settings.setNameFilter(v),
            ),
          ]),

          // ── Section Accessibilité ────────────────────────────────────────
          _sectionHeader('Service d\'Accessibilité', Icons.accessibility_new),
          _card(children: [
            // Statut
            Row(
              children: [
                Icon(
                  accService.isEnabled
                      ? Icons.check_circle
                      : Icons.cancel,
                  color: accService.isEnabled
                      ? Colors.greenAccent
                      : Colors.red,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  accService.isEnabled ? 'Service actif' : 'Service inactif',
                  style: TextStyle(
                    color: accService.isEnabled
                        ? Colors.greenAccent
                        : Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6)),
                  onPressed: accService.requestPermission,
                  child: const Text('Activer', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            // Guide d'activation si non actif
            if (!accService.isEnabled) ...[
              const SizedBox(height: 12),
              const Text(
                'Guide d\'activation :',
                style: TextStyle(
                    color: Color(0xFFCCCCCC), fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              ..._activationSteps.map((step) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: _orange,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${_activationSteps.indexOf(step) + 1}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(step,
                              style: const TextStyle(
                                  color: Color(0xFFAAAAAA), fontSize: 12)),
                        ),
                      ],
                    ),
                  )),
            ],
          ]),

          // ── Section Analyse Claude ───────────────────────────────────────
          _sectionHeader('Analyse Claude', Icons.psychology_outlined),
          _card(children: [
            // Nombre de paquets BLE
            _sliderRow(
              label: 'Paquets BLE envoyés',
              value: settings.maxBlePackets.toDouble(),
              min: 10,
              max: 100,
              divisions: 9,
              unit: '',
              onChanged: (v) => settings.setMaxBlePackets(v.round()),
            ),
            // Nombre d'entrées écran
            _sliderRow(
              label: 'Entrées écran envoyées',
              value: settings.maxScreenEntries.toDouble(),
              min: 10,
              max: 100,
              divisions: 9,
              unit: '',
              onChanged: (v) => settings.setMaxScreenEntries(v.round()),
            ),
            // Langue de réponse
            Row(
              children: [
                const Text('Langue de réponse',
                    style: TextStyle(color: Colors.white)),
                const Spacer(),
                SegmentedButton<String>(
                  style: ButtonStyle(
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? Colors.white
                          : const Color(0xFFAAAAAA),
                    ),
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.selected)
                          ? _orange
                          : const Color(0xFF333333),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(value: 'FR', label: Text('FR')),
                    ButtonSegment(value: 'EN', label: Text('EN')),
                  ],
                  selected: {settings.claudeLanguage},
                  onSelectionChanged: (s) =>
                      settings.setClaudeLanguage(s.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Prompt système
            const Text('Prompt système',
                style: TextStyle(
                    color: Color(0xFFAAAAAA), fontSize: 12)),
            const SizedBox(height: 6),
            TextField(
              controller: _systemPromptCtrl,
              maxLines: 5,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF333333),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none),
              ),
              onChanged: settings.setSystemPrompt,
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () async {
                await settings.resetSystemPrompt();
                _systemPromptCtrl.text = SettingsService.defaultSystemPrompt;
              },
              child: const Text('Réinitialiser le prompt',
                  style: TextStyle(color: _orange, fontSize: 12)),
            ),
          ]),

          // ── Section HCI Snoop Log ────────────────────────────────────────
          _sectionHeader('HCI Snoop Log', Icons.bluetooth_audio),
          Consumer<HciSnoopService>(
            builder: (ctx, snoop, _) => _card(children: [
              // Statut courant
              Row(
                children: [
                  Icon(
                    snoop.status == SnoopStatus.lecture
                        ? Icons.radio_button_on
                        : snoop.status == SnoopStatus.erreur
                            ? Icons.error_outline
                            : Icons.radio_button_off,
                    color: snoop.status == SnoopStatus.lecture
                        ? Colors.greenAccent
                        : snoop.status == SnoopStatus.erreur
                            ? Colors.red
                            : Colors.orange,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      snoop.statusMessage,
                      style: TextStyle(
                        color: snoop.status == SnoopStatus.lecture
                            ? Colors.greenAccent
                            : const Color(0xFFAAAAAA),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Activation du mode snoop
              _switchRow(
                label: 'Mode Snoop actif',
                subtitle: 'Capture passive via btsnoop_hci.log',
                value: settings.snoopModeEnabled,
                onChanged: (v) {
                  settings.setSnoopModeEnabled(v);
                  if (v) {
                    snoop.start();
                  } else {
                    snoop.stop();
                  }
                },
              ),

              // Chemin du fichier manuel + sélecteur
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _snoopFilePathCtrl,
                      style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 12),
                      decoration: InputDecoration(
                        labelText: 'Chemin fichier (vide = autodécouverte)',
                        labelStyle:
                            const TextStyle(color: Color(0xFFAAAAAA)),
                        hintText: '/sdcard/BtHciSnoop/btsnoop_hci.log',
                        hintStyle:
                            const TextStyle(color: Color(0xFF555555)),
                        filled: true,
                        fillColor: const Color(0xFF333333),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none),
                      ),
                      onChanged: (v) => settings.setSnoopFilePath(v.trim()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF444444),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('Parcourir',
                        style: TextStyle(fontSize: 12)),
                    onPressed: _pickSnoopFile,
                  ),
                ],
              ),

              // Diagnostic : chemins essayés si erreur
              if (snoop.status == SnoopStatus.erreur &&
                  snoop.lastTriedPaths.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('Chemins testés :',
                    style: TextStyle(
                        color: Color(0xFFAAAAAA),
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ...snoop.lastTriedPaths.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        p,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            color: Color(0xFF666666),
                            fontSize: 10),
                      ),
                    )),
              ],

              // Intervalle de polling
              const SizedBox(height: 4),
              _sliderRow(
                label: 'Intervalle de polling',
                value: settings.snoopPollIntervalMs.toDouble(),
                min: 200,
                max: 2000,
                divisions: 18,
                unit: ' ms',
                onChanged: (v) => settings.setSnoopPollIntervalMs(v.round()),
              ),

              // Guide d'activation
              const Divider(color: Color(0xFF444444), height: 24),
              const Text(
                'Activation sur Android :',
                style: TextStyle(
                    color: Color(0xFFCCCCCC), fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const SizedBox(height: 6),
              ..._snoopSetupSteps.map((step) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: _orange,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${_snoopSetupSteps.indexOf(step) + 1}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(step,
                              style: const TextStyle(
                                  color: Color(0xFFAAAAAA), fontSize: 12)),
                        ),
                      ],
                    ),
                  )),
            ]),
          ),

          // ── Section Logs ─────────────────────────────────────────────────
          _sectionHeader('Logs', Icons.list_alt),
          _card(children: [
            // Taille max en mémoire
            _sliderRow(
              label: 'Taille max en mémoire',
              value: settings.maxLogsMemory.toDouble(),
              min: 100,
              max: 2000,
              divisions: 19,
              unit: ' entrées',
              onChanged: (v) => settings.setMaxLogsMemory(v.round()),
            ),
          ]),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ─── Widgets helpers ───────────────────────────────────────────────────────

  Widget _sectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: _orange, size: 18),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(
                  color: _orange,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }

  Widget _card({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String unit,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white)),
            Text(
              '${value.round()}$unit',
              style: const TextStyle(color: _orange, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: _orange,
          inactiveColor: const Color(0xFF444444),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _switchRow({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(color: Colors.white)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 11)),
      value: value,
      activeThumbColor: _orange,
      activeTrackColor: _orange.withValues(alpha: 0.5),
      onChanged: onChanged,
    );
  }

  /// Guide d'activation du service d'accessibilité
  static const List<String> _activationSteps = [
    'Ouvrez les Paramètres Android',
    'Allez dans Accessibilité',
    'Appuyez sur "Services installés" ou "Applications téléchargées"',
    'Sélectionnez "eFlexReverse — Capture eFlexFuel"',
    'Activez le service et confirmez',
  ];

  /// Guide d'activation du journal HCI Bluetooth
  static const List<String> _snoopSetupSteps = [
    'Ouvrez les Paramètres Android',
    'Allez dans Options développeur (activez-les si besoin : 7× sur "Numéro de build")',
    'Activez "Journal HCI Bluetooth" (ou "Activer le journal HCI Snoop Bluetooth")',
    'Autorisez "Accès à tous les fichiers" quand eFlexReverse le demande (Android 11+)',
    'Désactivez puis réactivez le Bluetooth pour que le journal prenne effet',
    'Reconnectez l\'eFlexFuel app au boîtier — le fichier btsnoop_hci.log est créé à ce moment',
  ];
}
