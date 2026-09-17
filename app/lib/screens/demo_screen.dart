import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/api_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';
import 'alert_screen.dart';

/// Panel demo screen.
///
/// Injects a real prepared clip into the live /detect pipeline -- same model,
/// same risk scorer, same escalation path -- instead of showing hardcoded
/// text. The only thing it bypasses is room acoustics.
///
/// Switching to the demo head here is the presentation move: a Diwali
/// firecracker is detected as its own class and aliased to gunshot, so the
/// whole chain (verification, risk score, countdown, automated call, Telegram
/// clip) runs live on stage with a sound that is safe and legal to make.
class DemoScreen extends StatefulWidget {
  final bool mediaPlayback;
  final bool suddenMotion;
  final double sensitivityThreshold;

  const DemoScreen({
    super.key,
    required this.mediaPlayback,
    required this.suddenMotion,
    required this.sensitivityThreshold,
  });

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final ApiService _api = ApiService();

  static const _baseClasses = [
    'gunshot', 'scream', 'glass_breaking', 'explosion',
    'fire_alarm', 'siren', 'shouting', 'normal',
  ];

  Map<String, dynamic>? _guidanceRules;
  String? _busyClass;
  String? _statusMessage;
  bool _escalate = true;

  @override
  void initState() {
    super.initState();
    _api.fetchGuidanceRules().then((rules) {
      if (mounted) setState(() => _guidanceRules = rules);
    });
  }

  List<String> get _classes {
    final profile = AppSession.instance.modelProfile.value;
    return profile == 'demo' ? ['firecracker', ..._baseClasses] : _baseClasses;
  }

  Future<Position?> _position() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        return await Geolocator.getCurrentPosition(timeLimit: const Duration(seconds: 8));
      }
    } catch (_) {}
    return null;
  }

  Future<void> _runDemoClip(String soundClass) async {
    final session = AppSession.instance;
    setState(() {
      _busyClass = soundClass;
      _statusMessage = null;
    });

    final clipBytes = await _api.fetchDemoClip(soundClass);
    if (clipBytes == null) {
      if (!mounted) return;
      setState(() {
        _busyClass = null;
        _statusMessage = 'Could not fetch the $soundClass clip. Build the dataset first '
            '(prepare_dataset.py, or prepare_demo_dataset.py for firecracker).';
      });
      return;
    }

    final result = await _api.detectAudioBytes(
      audioBytes: clipBytes,
      filename: '$soundClass.wav',
      duration: 5.0,
      mediaPlayback: widget.mediaPlayback,
      suddenMotion: widget.suddenMotion,
      sensitivityThreshold: widget.sensitivityThreshold,
      userId: session.userId,
      profile: session.modelProfile.value,
    );

    if (!mounted) return;
    setState(() => _busyClass = null);

    if (result == null) {
      setState(() => _statusMessage = 'Detection request failed — is the backend running?');
      return;
    }

    final candidate = (result['candidate'] ?? soundClass).toString();
    final rawClass = result['raw_candidate']?.toString();

    if (result['verified'] != true) {
      setState(() => _statusMessage =
          '${candidate.toUpperCase()}: not verified by pass 2 (risk ${result['risk_score'] ?? 0}).');
      return;
    }

    await _api.logEvent(
      userId: session.userId,
      className: candidate,
      primaryConf: (result['primary_confidence'] as num?)?.toDouble() ?? 0.0,
      verificationConf: (result['verification_confidence'] as num?)?.toDouble() ?? 0.0,
      riskScore: (result['risk_score'] as num?)?.toInt() ?? 0,
      riskLevel: result['risk_level']?.toString() ?? 'NORMAL',
    );
    // logEvent is a real network round-trip -- the user can switch tabs
    // (fully disposing this State, via MainNavigationShell's KeyedSubtree)
    // before it resolves. Every other await in this file already guards its
    // following setState/Navigator/context use; this one didn't.
    if (!mounted) return;

    // A moderate-confidence ("SUSPICIOUS") read is worth logging, not worth
    // the full alert screen -- see docs/DECISIONS_LOG.md #10. The demo lab's
    // curated clips normally land well into POSSIBLE_DANGER/HIGH_RISK, so
    // this only changes behaviour for a genuinely borderline model output,
    // which is exactly when NOT dramatizing the result is the honest call.
    final riskLevel = result['risk_level']?.toString() ?? 'NORMAL';
    final showFullAlert =
        result['should_alert'] == true && (riskLevel == 'POSSIBLE_DANGER' || riskLevel == 'HIGH_RISK');

    if (!showFullAlert) {
      final suppressed = result['media_suppressed'] == true;
      setState(() => _statusMessage = suppressed
          ? 'Verified as likely media playback (risk ${result['risk_score']}). No alert raised — '
              'this is the movie-scene false-positive defence.'
          : result['should_alert'] == true
              ? 'Verified ${candidate.replaceAll('_', ' ')} at risk ${result['risk_score']} ($riskLevel) '
                  '— logged, below the alert-screen threshold.'
              : 'Verified at risk ${result['risk_score']} ($riskLevel) — below the '
                  'emergency-handoff threshold.');
      return;
    }

    final position = await _position();
    Map<String, dynamic>? incident;
    if (_escalate) {
      incident = await _api.createIncident(
        userId: session.userId,
        className: candidate,
        rawClass: rawClass,
        profile: session.modelProfile.value,
        primaryConf: (result['primary_confidence'] as num?)?.toDouble() ?? 0.0,
        verificationConf: (result['verification_confidence'] as num?)?.toDouble() ?? 0.0,
        riskScore: (result['risk_score'] as num?)?.toInt() ?? 0,
        riskLevel: result['risk_level']?.toString() ?? 'NORMAL',
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracyM: position?.accuracy,
        placeLabel: 'Last known location',
        userLabel: session.displayName,
        clipBytes: clipBytes,
        clipFilename: '$soundClass.wav',
      );
    }

    final rule = _guidanceRules?[candidate] as Map<String, dynamic>?;
    final instructions = rule != null
        ? List<String>.from(rule['instructions'] as Iterable)
        : const ['Stay alert.', 'Follow local emergency guidance.'];
    final facilities = await _fetchNearbyFacilities(candidate, position);

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AlertScreen(
          title: rule?['title']?.toString() ?? 'Acoustic threat detected',
          threatClass: candidate,
          rawClass: rawClass,
          riskScore: (result['risk_score'] as num?)?.toInt() ?? 0,
          riskLevel: result['risk_level']?.toString() ?? 'NORMAL',
          p1Conf: (result['primary_confidence'] as num?)?.toDouble() ?? 0.0,
          p2Conf: (result['verification_confidence'] as num?)?.toDouble() ?? 0.0,
          instructions: instructions,
          nearbyFacilities: facilities,
          incident: incident,
          profile: session.modelProfile.value,
        ),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _fetchNearbyFacilities(
    String detectedClass,
    Position? position,
  ) async {
    final type = detectedClass == 'fire_alarm'
        ? 'fire'
        : (detectedClass == 'gunshot' ||
                detectedClass == 'glass_breaking' ||
                detectedClass == 'shouting')
            ? 'police'
            : 'hospital';
    final usingFallbackLocation = position == null;
    final places = await _api.getNearbyPlaces(
      lat: position?.latitude ?? 17.3850,
      lng: position?.longitude ?? 78.4867,
      type: type,
    );
    final disclosure = usingFallbackLocation
        ? [
            {
              'name': 'Approximate location used',
              'address': 'Location permission unavailable — results below are for a default '
                  'demo location, not your actual position.',
            }
          ]
        : <Map<String, dynamic>>[];
    if (places == null || places.isEmpty) {
      return [
        ...disclosure,
        {'name': 'No nearby $type services found', 'address': 'Try again once you have a location fix.'}
      ];
    }
    return [
      ...disclosure,
      ...places.take(3).map((p) => {
            'name': p['name']?.toString() ?? 'Unnamed facility',
            'address': p['address']?.toString() ?? 'Address unavailable',
          }),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSession.instance;
    return ValueListenableBuilder<String>(
      valueListenable: session.modelProfile,
      builder: (context, profile, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            FadeSlideIn(
              index: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    '14 // LAB INJECTION BENCH',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      color: AppColors.inkMuted,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'TELEMETRY INJECTION',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                      color: AppColors.ink,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const FadeSlideIn(
              index: 0,
              child: Text(
                'Directly stream calibrated acoustic recordings into the live verification model. Exercises full two-pass classifier, dynamic risk scorer, and escalation state machine.',
                style: TextStyle(fontSize: 12, color: AppColors.inkMuted, height: 1.5),
              ),
            ),
            const SizedBox(height: 18),
            FadeSlideIn(index: 1, child: _buildProfileSwitch(session, profile)),
            const SizedBox(height: 16),
            FadeSlideIn(
              index: 2,
              child: AppCard(
                hasShadow: true,
                shadowOffset: 3,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: SwitchListTile(
                  activeThumbColor: AppColors.primary,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  title: const Text(
                    'OUTBOUND DISPATCH ESCALATION',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                  ),
                  subtitle: const Text(
                    'Arm real abort countdown, automated voice relay, and Telegram coordinate dispatch during demo tests.',
                    style: TextStyle(fontSize: 11, color: AppColors.inkMuted),
                  ),
                  value: _escalate,
                  onChanged: (value) => setState(() => _escalate = value),
                ),
              ),
            ),
            const SizedBox(height: 14),
            FadeSlideIn(
              index: 3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  border: Border.all(color: AppColors.lineSubtle, width: 1),
                ),
                child: Text(
                  'ACTIVE CONTEXT // MEDIA SUPPRESSION: ${widget.mediaPlayback ? "ON" : "OFF"} · '
                  'SUDDEN ACCEL: ${widget.suddenMotion ? "ON" : "OFF"} · '
                  'THRESHOLD: ${widget.sensitivityThreshold.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.3, color: AppColors.inkMuted),
                ),
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 14),
              AppCard(
                background: AppColors.primary,
                borderColor: AppColors.line,
                hasShadow: true,
                shadowOffset: 2,
                padding: const EdgeInsets.all(14),
                child: Text(
                  _statusMessage!.toUpperCase(),
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, height: 1.4, color: AppColors.ink),
                ),
              ),
            ],
            const SizedBox(height: 22),
            const SectionLabel('15 // SOUND SIGNATURE REPOSITORY'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 2.1,
              children: _classes
                  .asMap()
                  .entries
                  .map((entry) => FadeSlideIn(
                        index: entry.key,
                        child: _buildClassButton(entry.value),
                      ))
                  .toList(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProfileSwitch(AppSession session, String profile) {
    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      background: profile == 'demo' ? AppColors.primary : AppColors.surface,
      borderColor: AppColors.line,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'CLASSIFIER ENGINE PROFILE',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                ),
              ),
              StatusPill(
                label: profile == 'demo' ? 'DEMO PROFILE' : 'PRODUCTION',
                color: AppColors.ink,
                background: AppColors.surface,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _profileChoice(
                  session,
                  'real',
                  'PRODUCTION',
                  'Standard acoustic hazard library',
                  profile == 'real',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _profileChoice(
                  session,
                  'demo',
                  'DEMO PROFILE',
                  'Includes firecracker signature',
                  profile == 'demo',
                ),
              ),
            ],
          ),
          if (profile == 'demo') ...[
            const SizedBox(height: 12),
            const Text(
              'Diwali firecracker audio is classified independently and mapped to gunshot telemetry for presentation verification without live munitions.',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.ink, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  Widget _profileChoice(
    AppSession session,
    String value,
    String title,
    String subtitle,
    bool selected,
  ) {
    return PressableScale(
      onTap: () => session.setModelProfile(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(color: AppColors.line, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                color: selected ? AppColors.surface : AppColors.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                height: 1.3,
                color: selected ? AppColors.surface.withValues(alpha: 0.8) : AppColors.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClassButton(String soundClass) {
    final busy = _busyClass == soundClass;
    final isFirecracker = soundClass == 'firecracker';
    final isNormal = soundClass == 'normal';

    return PressableScale(
      onTap: _busyClass == null ? () => _runDemoClip(soundClass) : null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: busy ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(
            color: AppColors.line,
            width: 1.5,
          ),
          boxShadow: neoShadow(offset: 2),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: isNormal
                    ? AppColors.surfaceAlt
                    : isFirecracker
                        ? AppColors.primary
                        : AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(AppRadii.control / 2),
                border: Border.all(color: AppColors.line, width: 1.2),
              ),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink),
                    )
                  : Icon(
                      isFirecracker
                          ? Icons.celebration_outlined
                          : isNormal
                              ? Icons.check_circle_outline
                              : Icons.volume_up_outlined,
                      size: 17,
                      color: AppColors.ink,
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                soundClass.replaceAll('_', ' ').toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.3,
                  color: AppColors.ink,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
