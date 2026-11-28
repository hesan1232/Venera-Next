import 'package:flutter/material.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/scroll.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/features/web_service/web_server.dart';
import 'package:venera_next/features/web_service/web_service_runtime.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/battery_optimization.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

class WebServiceSettings extends StatefulWidget {
  const WebServiceSettings({super.key});

  @override
  State<WebServiceSettings> createState() => _WebServiceSettingsState();
}

class _WebServiceSettingsState extends State<WebServiceSettings> {
  static final _prefs = GlobalPreferenceStore(appdata.settings);

  List<String> _addresses = [];
  bool _running = false;
  bool? _ignoringBattery;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final addresses = await WebServer.localAddresses();
    if (!mounted) return;
    setState(() {
      _addresses = addresses;
      _running = WebServiceRuntime.instance.isRunning;
    });
    _refreshBattery();
  }

  Future<void> _refreshBattery() async {
    if (!BatteryOptimization.supported) return;
    final ignoring = await BatteryOptimization.isIgnoring();
    if (!mounted) return;
    setState(() => _ignoringBattery = ignoring);
  }

  /// Prompt once when the service is turned on: a plain Dart HttpServer is
  /// killed by Android's Doze unless this app is whitelisted.
  Future<void> _maybePromptBattery() async {
    if (!BatteryOptimization.supported) return;
    final ignoring = await BatteryOptimization.isIgnoring();
    if (ignoring != false || !mounted) return;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Keep web service running in background'.tl),
        content: Text(
          'Android may stop the server when the app is in the background. '
          'Disable battery optimization to keep browser and OPDS access '
          'available.'
              .tl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('Later'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Open system settings'.tl),
          ),
        ],
      ),
    );
    if (openSettings != true) return;
    await BatteryOptimization.requestIgnore();
    await _refresh();
  }

  Future<void> _apply() async {
    await WebServiceRuntime.instance.applySettings();
    await _refresh();
  }

  Future<void> _editPort() async {
    final controller = TextEditingController(
      text: '${_prefs.read(AppPreferences.webServicePort)}',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Web service port'.tl),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(hintText: '8080'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel'.tl),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value == null || value < 1024 || value > 65535) {
                Navigator.pop(dialogContext);
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: Text('OK'.tl),
          ),
        ],
      ),
    );
    if (result == null) return;
    await appdata.updateSettings((draft) {
      GlobalPreferenceStore(draft).write(AppPreferences.webServicePort, result);
    });
    await _apply();
  }

  Future<void> _editToken() async {
    final controller = TextEditingController(
      text: _prefs.read(AppPreferences.webServiceToken),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Access token'.tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Clients must send Authorization: Bearer <token>. Leave empty to disable auth.'
                  .tl,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: controller, obscureText: true),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel'.tl),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text('OK'.tl),
          ),
        ],
      ),
    );
    if (result == null) return;
    await appdata.updateSettings((draft) {
      GlobalPreferenceStore(
        draft,
      ).write(AppPreferences.webServiceToken, result);
    });
    await _apply();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _prefs.read(AppPreferences.webServiceEnabled);
    final localOnly = _prefs.read(AppPreferences.webServiceLocalOnly);
    final port = _prefs.read(AppPreferences.webServicePort);
    final token = _prefs.read(AppPreferences.webServiceToken);
    final urls = <String>[
      if (localOnly) 'http://127.0.0.1:$port/',
      for (final address in _addresses) 'http://$address:$port/',
    ];

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Web Service'.tl)),
        SwitchSetting.preference(
          title: 'Enable web service'.tl,
          subtitle: 'Read your library from a browser on this network.'.tl,
          preference: AppPreferences.webServiceEnabled,
          onChanged: () async {
            await _apply();
            if (_prefs.read(AppPreferences.webServiceEnabled)) {
              await _maybePromptBattery();
            }
          },
        ).toSliver(),
        if (enabled &&
            BatteryOptimization.supported &&
            _ignoringBattery == false)
          ListTile(
            leading: const Icon(Icons.battery_saver),
            title: Text('Disable battery optimization'.tl),
            subtitle: Text(
              'Android may stop the server when the app is in the background. '
              'Disable battery optimization to keep browser and OPDS access '
              'available.'
                  .tl,
            ),
            onTap: () async {
              await BatteryOptimization.requestIgnore();
              await _refresh();
            },
          ).toSliver(),
        if (enabled &&
            BatteryOptimization.supported &&
            _ignoringBattery == true)
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: Text('Battery optimization is off'.tl),
            subtitle: Text('Keep web service running in background'.tl),
          ).toSliver(),
        SwitchSetting.preference(
          title: 'Listen on localhost only'.tl,
          subtitle: 'Block access from other devices.'.tl,
          preference: AppPreferences.webServiceLocalOnly,
          onChanged: _apply,
        ).toSliver(),
        ListTile(
          title: Text('Web service port'.tl),
          subtitle: Text('$port'),
          onTap: _editPort,
        ).toSliver(),
        ListTile(
          title: Text('Access token'.tl),
          subtitle: Text(token.isEmpty ? 'Not set'.tl : '••••••••'),
          onTap: _editToken,
        ).toSliver(),
        SwitchSetting.preference(
          title: 'Allow progress writing'.tl,
          subtitle: 'Web readers can update reading progress.'.tl,
          preference: AppPreferences.webServiceAllowProgressWrite,
          onChanged: _apply,
        ).toSliver(),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _running ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      (_running ? 'Running' : 'Stopped').tl +
                          (enabled ? '' : ' · ${'Disabled in settings'.tl}'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!enabled)
                  Text(
                    'Turn on the switch above to start the web reader.'.tl,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 12,
                    ),
                  )
                else ...[
                  for (final url in urls)
                    SelectableText(url, style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 12),
                  Text(
                    'OPDS catalog (add this URL in KOReader / other OPDS readers):'
                        .tl,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final url in urls)
                    SelectableText(
                      '${url}opds',
                      style: const TextStyle(fontSize: 15),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Komga-compatible API (for Komelia and other Komga clients):'
                        .tl,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final url in urls)
                    SelectableText(
                      '${url}api/v1',
                      style: const TextStyle(fontSize: 15),
                    ),
                ],
                const SizedBox(height: 12),
                Text(
                  'API: /api/bookshelf · /api/search · /api/comic · /api/cover · /api/progress · /api/chapter'
                      .tl,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Komga API: /api/v1/series · /api/v1/books · /api/v1/libraries · OPDS-PSE page streaming'
                      .tl,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _apply,
                  icon: const Icon(Icons.restart_alt),
                  label: Text('Restart service'.tl),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
