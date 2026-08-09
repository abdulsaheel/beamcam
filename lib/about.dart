import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';


/// Read from the built bundle, which Flutter fills from `version:` in
/// pubspec.yaml — so a release bumps one line and both apps follow.
String appVersion = '';

Future<void> loadVersion() async =>
    appVersion = (await PackageInfo.fromPlatform()).version;

const String kAuthor = 'Abdul Sahil';

/// Each logo carries its own background, so the wrong one on the wrong theme
/// shows as a pale square on a dark sheet.
class BeamCamLogo extends StatelessWidget {
  const BeamCamLogo({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: Image.asset(
        dark ? 'assets/logo-dark.png' : 'assets/logo-light.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
const String kRepoUrl = 'https://github.com/abdulsaheel/beamcam';


const String kIssuesUrl = '$kRepoUrl/issues';

String get kRepoLabel => kRepoUrl.replaceFirst('https://', '');

Future<void> openRepo() => _open(kRepoUrl);

Future<void> openIssues() => _open(kIssuesUrl);

Future<void> _open(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<void> showAboutSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const BeamCamLogo(),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('BeamCam', style: theme.textTheme.headlineSmall),
                    Text(
                      'Version $appVersion',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            _Row(label: 'Built by', value: kAuthor),
            const SizedBox(height: 8),
            _Row(label: 'Licence', value: 'GPL-3.0'),
            const SizedBox(height: 20),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.code),
                    title: Text(kRepoLabel),
                    subtitle: const Text('Source and releases'),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy_all_outlined),
                      tooltip: 'Copy link',
                      onPressed: () async {
                        await Clipboard.setData(
                          const ClipboardData(text: kRepoUrl),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Link copied')),
                          );
                        }
                      },
                    ),
                    onTap: openRepo,
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.bug_report_outlined),
                    title: const Text('Report an issue'),
                    subtitle: const Text('Something broken or missing'),
                    trailing: const Icon(Icons.open_in_new, size: 18),
                    onTap: openIssues,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  },
);

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}


class AboutFooter extends StatelessWidget {
  const AboutFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    return Column(
      children: [
        Text('BeamCam $appVersion · by $kAuthor', style: dim),
        const SizedBox(height: 2),
        TextButton(
          onPressed: openRepo,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(kRepoLabel, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }
}
