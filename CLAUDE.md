# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commandes essentielles

```bash
flutter pub get          # Installer les dépendances
flutter analyze lib/     # Analyse statique (doit retourner "No issues found")
flutter run              # Lancer sur appareil Android connecté
flutter build apk        # Build APK release
```

L'analyse doit être propre avant tout commit. Pas de tests automatisés dans ce projet.

## Architecture

Application Flutter Android de **reverse engineering BLE pour le boîtier eFlexFuel**. Elle corrèle les données BLE brutes avec ce que l'eFlexFuel app affiche à l'écran, puis envoie le tout à Claude (API Anthropic) pour identification du protocole.

### Contrainte fondamentale — BLE

Le boîtier eFlexFuel n'accepte **qu'une seule connexion BLE à la fois**. Quand l'eFlexFuel app est connectée, le boîtier arrête d'advertiser — eFlexReverse ne peut même plus le voir en scan. L'architecture choisie est donc :

#### Mode principal : HCI Snoop Log (passif)

- L'**eFlexFuel app** se connecte normalement au boîtier
- Android enregistre tout le trafic BLE dans `btsnoop_hci.log` (Options développeur → Journal HCI Bluetooth)
- **eFlexReverse** lit et parse ce fichier en continu via `HciSnoopService`
- **eFlexReverse** capture en parallèle l'écran de l'eFlexFuel app via `AccessibilityService`

#### Mode secondaire : connexion directe BLE (bloque l'eFlexFuel app)

- Accessible via le bouton Bluetooth de l'AppBar → `ScanScreen`
- `BleService` se connecte directement et subscribe à toutes les caractéristiques notify/indicate

### Services (lib/services/) — ChangeNotifier via Provider

| Service | Rôle |
|---|---|
| `SettingsService` | Source de vérité pour tous les réglages, persistés dans SharedPreferences |
| `HciSnoopService` | Parse `btsnoop_hci.log` (format RFC 1761), extrait paquets ATT GATT, polling périodique |
| `BleService` | Scan BLE, connexion directe, subscribe à toutes les caractéristiques notify/indicate, reconnexion auto |
| `AccessibilityService` | Écoute `FlutterAccessibilityService.accessStream`, filtre sur `com.eflexfuel.app`, extrait `event.text` et `event.subNodes` récursivement |
| `ClaudeService` | HTTP vers `api.anthropic.com/v1/messages`, modèle `claude-opus-4-5`, clé API depuis `SettingsService` |

Le `MultiProvider` dans `main.dart` injecte les services dans cet ordre : `SettingsService` → `BleService` / `AccessibilityService` / `HciSnoopService` → `ClaudeService`.

### Modèles (lib/models/)

- `BlePacket` — paquet reçu (BLE direct ou snoop), expose `hexValue`, `asciiValue`, `uint8Value`, `uint16Value`, `float32Value` (little-endian)
- `ScreenEntry` — capture de texte de l'eFlexApp, plusieurs textes par entrée joints avec ` | `
- `UuidInfo` — état consolidé d'une UUID : nom suggéré, type, plage min/max, explication Claude, liste des paquets

### Android natif

- **Package** : `com.example.eflexreverse`
- **Service d'accessibilité** : `slayer.accessibility.service.flutter_accessibility_service.AccessibilityListener` (fourni par le plugin, déclaré dans `AndroidManifest.xml`)
- **Config accessibilité** : `android/app/src/main/res/xml/accessibility_service_config.xml` — filtré sur `com.eflexfuel.app` uniquement
- Permissions BLUETOOTH_SCAN, BLUETOOTH_CONNECT et READ_EXTERNAL_STORAGE demandées au runtime via `permission_handler`
- `android:requestLegacyExternalStorage="true"` requis pour accès à `/sdcard/` sur Android 10

### Flux de données principal

```
HciSnoopService ──► List<BlePacket> ──┐  (mode snoop, défaut)
                                        ├──► MainScreen ──► ClaudeService ──► BottomSheet
BleService ──► List<BlePacket> ──────┘  (mode direct, prioritaire si connecté)

AccessibilityService ──► List<ScreenEntry> ──► ClaudeService.analyzeCorrelation()
```

`MainScreen` utilise `bleService.packets` si `bleService.isConnected`, sinon `snoopService.packets`.
`ProtocolScreen` fusionne les deux `uuidMap` : `{...snoop.uuidMap, ...ble.uuidMap}` (BLE direct prioritaire).

### Chemins de recherche du fichier snoop (dans l'ordre)

1. `settings.snoopFilePath` si non vide (chemin manuel)
2. `/sdcard/BtHciSnoop/btsnoop_hci.log` (Samsung One UI)
3. `/sdcard/btsnoop_hci.log` (AOSP générique)
4. `/sdcard/bluetooth/btsnoop_hci.log` (variante OEM)
5. `/data/misc/bluetooth/logs/btsnoop_hci.log` (root requis)

### Thème

Dark theme constant : `#1A1A1A` (fond), `#2A2A2A` (surfaces), `#333333` (cards), `#FF6600` (accent orange). Tous les commentaires dans le code Dart sont en **français**.
