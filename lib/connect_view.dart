import 'dart:async';

import 'package:flutter/material.dart';

import 'about.dart';
import 'device_discovery.dart';
import 'main.dart';
import 'pairing.dart';
import 'signaling.dart';

/// Loopback, reached over `adb reverse`. Developer-only: it needs USB
/// debugging, so it stays hidden until asked for from the overflow menu.
const String kUsbHost = '127.0.0.1';

PairingPayload get kUsbTarget =>
    const PairingPayload(host: kUsbHost, port: kSignalPort, name: 'USB cable');

enum _Overflow { rescan, usb, forgetAll, about }

class ConnectView extends StatefulWidget {
  const ConnectView({
    super.key,
    required this.saved,
    required this.onConnect,
    required this.onForget,
    required this.onForgetAll,
    this.error,
  });

  final List<PairingPayload> saved;
  final ValueChanged<PairingPayload> onConnect;
  final ValueChanged<PairingPayload> onForget;
  final VoidCallback onForgetAll;
  final String? error;

  @override
  State<ConnectView> createState() => _ConnectViewState();
}

class _ConnectViewState extends State<ConnectView> {
  final _address = TextEditingController();
  final _discovery = DeviceDiscovery();
  bool _showUsb = false;

  @override
  void initState() {
    super.initState();
    _discovery.addListener(_onDiscovery);
    _discovery.start();
  }

  @override
  void dispose() {
    _discovery.removeListener(_onDiscovery);
    _discovery.dispose();
    _address.dispose();
    super.dispose();
  }

  void _onDiscovery() {
    if (mounted) setState(() {});
  }

  void _submitAddress() {
    final payload = PairingPayload.tryParse(_address.text);
    if (payload == null) return;
    widget.onConnect(payload);
  }

  /// Discovered computers that are not already saved, so nothing appears twice.
  List<PairingPayload> get _fresh {
    final savedHosts = widget.saved.map((e) => e.host).toSet();
    return _discovery.devices
        .where((d) => !savedHosts.contains(d.host))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fresh = _fresh;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BeamCam'),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (context, mode, _) => PopupMenuButton<ThemeMode>(
              icon: Icon(mode.icon),
              tooltip: 'Appearance',
              initialValue: mode,
              onSelected: (m) => unawaited(setThemeMode(m)),
              itemBuilder: (context) => [
                for (final m in ThemeMode.values)
                  PopupMenuItem(
                    value: m,
                    child: Row(
                      children: [
                        Icon(m.icon, size: 18),
                        const SizedBox(width: 12),
                        Text(m.label),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          PopupMenuButton<_Overflow>(
            onSelected: (choice) {
              switch (choice) {
                case _Overflow.rescan:
                  _discovery.restart();
                case _Overflow.usb:
                  setState(() => _showUsb = !_showUsb);
                case _Overflow.forgetAll:
                  widget.onForgetAll();
                case _Overflow.about:
                  unawaited(showAboutSheet(context));
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _Overflow.rescan,
                child: Text('Scan again'),
              ),
              PopupMenuItem(
                value: _Overflow.usb,
                child: Text(_showUsb ? 'Hide USB option' : 'Connect over USB'),
              ),
              if (widget.saved.isNotEmpty)
                const PopupMenuItem(
                  value: _Overflow.forgetAll,
                  child: Text('Forget all computers'),
                ),
              const PopupMenuItem(
                value: _Overflow.about,
                child: Text('About BeamCam'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (widget.error != null) ...[
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                title: Text(
                  widget.error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (widget.saved.isNotEmpty) ...[
            _Header('Saved'),
            Card(
              child: Column(
                children: [
                  for (final device in widget.saved)
                    _DeviceTile(
                      device: device,
                      onTap: () => widget.onConnect(device),
                      onForget: () => widget.onForget(device),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          _Header('On this network'),
          Card(
            child: fresh.isEmpty
                ? const ListTile(
                    leading: SizedBox(
                      width: 24,
                      height: 24,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    title: Text('Looking for computers'),
                    subtitle: Text(
                      'Open BeamCam on your computer and keep both on the '
                      'same Wi-Fi.',
                    ),
                  )
                : Column(
                    children: [
                      for (final device in fresh)
                        _DeviceTile(
                          device: device,
                          onTap: () => widget.onConnect(device),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 24),

          _Header('Other ways to connect'),
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.qr_code_2),
                  title: Text('Scan the code with your camera'),
                  subtitle: Text(
                    'Point your phone camera at the QR code in the BeamCam '
                    'window, then tap the link it offers.',
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _address,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Address',
                            hintText: '192.168.1.4',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => _submitAddress(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _submitAddress,
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                ),
                if (_showUsb) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.usb),
                    title: const Text('Connect over USB'),
                    subtitle: const Text(
                      'Needs USB debugging and '
                      'adb reverse tcp:$kSignalPort tcp:$kSignalPort',
                    ),
                    onTap: () => widget.onConnect(kUsbTarget),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 28),
          const AboutFooter(),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onTap, this.onForget});

  final PairingPayload device;
  final VoidCallback onTap;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.computer),
      title: Text(device.name),
      subtitle: Text(device.host),
      trailing: onForget == null
          ? const Icon(Icons.chevron_right)
          : IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Forget',
              onPressed: onForget,
            ),
      onTap: onTap,
    );
  }
}
