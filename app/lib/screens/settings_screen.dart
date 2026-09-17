import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:record/record.dart';

import '../services/api_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';

class SettingsScreen extends StatefulWidget {
  final double sensitivityThreshold;
  final ValueChanged<double> onSensitivityChanged;

  const SettingsScreen({
    super.key,
    required this.sensitivityThreshold,
    required this.onSensitivityChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final ApiService _api = ApiService();

  String _micStatus = 'Checking…';
  String _locationStatus = 'Checking…';
  Map<String, dynamic>? _escalationStatus;
  List<Map<String, dynamic>> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _refreshPermissionStatus();
    _loadBackendStatus();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _loadBackendStatus() async {
    final results = await Future.wait([_api.escalationStatus(), _api.getProfiles()]);
    if (!mounted) return;
    setState(() {
      _escalationStatus = results[0];
      final profiles = results[1]?['profiles'];
      _profiles = List<Map<String, dynamic>>.from(profiles as Iterable? ?? const []);
    });
  }

  Future<void> _refreshPermissionStatus() async {
    final hasMic = await _recorder.hasPermission();
    final locationPermission = await Geolocator.checkPermission();
    if (!mounted) return;
    setState(() {
      _micStatus = hasMic ? 'Authorized' : 'Not granted';
      _locationStatus = switch (locationPermission) {
        LocationPermission.always || LocationPermission.whileInUse => 'Authorized',
        LocationPermission.denied => 'Not requested',
        LocationPermission.deniedForever => 'Denied — enable in system settings',
        LocationPermission.unableToDetermine => 'Unavailable',
      };
    });
  }

  Future<void> _requestLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      setState(() => _locationStatus = 'Location services are off on this device');
      return;
    }
    await Geolocator.requestPermission();
    await _refreshPermissionStatus();
  }

  double _thresholdForSlider(double sliderValue) {
    // Mirrors the browser prototype: 1 is least sensitive (0.70), 9 is most (0.30).
    return double.parse((0.75 - sliderValue * 0.05).toStringAsFixed(2));
  }

  double _sliderForThreshold(double threshold) =>
      ((0.75 - threshold) / 0.05).clamp(1.0, 9.0);

  String _sensitivityLabel(double sliderValue, double threshold) {
    if (sliderValue < 4) return 'Low (${threshold.toStringAsFixed(2)})';
    if (sliderValue > 7) return 'High (${threshold.toStringAsFixed(2)})';
    return 'Medium (${threshold.toStringAsFixed(2)})';
  }

  @override
  Widget build(BuildContext context) {
    final sliderValue = _sliderForThreshold(widget.sensitivityThreshold);
    final session = AppSession.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '08 // SYSTEM CONFIG',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            color: AppColors.ink,
          ),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.line),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          FadeSlideIn(index: 0, child: _buildAccountCard(session)),
          const SizedBox(height: 24),
          const FadeSlideIn(index: 1, child: SectionLabel('09 // NEURAL ENGINE MATRIX')),
          FadeSlideIn(index: 1, child: _buildProfileCard(session)),
          const SizedBox(height: 24),
          const FadeSlideIn(index: 2, child: SectionLabel('10 // ESCALATION PROTOCOL')),
          FadeSlideIn(index: 2, child: _buildEscalationCard(session)),
          const SizedBox(height: 24),
          const FadeSlideIn(index: 3, child: SectionLabel('11 // DETECTION THRESHOLD CALIBRATION')),
          FadeSlideIn(
            index: 3,
            child: AppCard(
              hasShadow: true,
              shadowOffset: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PASS 1 CANDIDATE FILTER THRESHOLD',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _sensitivityLabel(sliderValue, widget.sensitivityThreshold).toUpperCase(),
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.inkMuted),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: AppColors.ink,
                      inactiveTrackColor: AppColors.lineSubtle,
                      thumbColor: AppColors.primary,
                      overlayColor: AppColors.primary.withValues(alpha: 0.2),
                      trackHeight: 6,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    ),
                    child: Slider(
                      value: sliderValue,
                      min: 1,
                      max: 9,
                      divisions: 8,
                      onChanged: (value) => widget.onSensitivityChanged(_thresholdForSlider(value)),
                    ),
                  ),
                  const Text(
                    'Higher sensitivity increases candidate capture volume. Pass 2 secondary verification enforces 5-second acoustic analysis before trigger.',
                    style: TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const FadeSlideIn(index: 4, child: SectionLabel('12 // HARDWARE & SENSOR PERMISSIONS')),
          FadeSlideIn(
            index: 4,
            child: AppCard(
              hasShadow: true,
              shadowOffset: 3,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Column(
                children: [
                  _permissionTile('MICROPHONE INPUT (16KHZ)', _micStatus, null),
                  const Divider(height: 1, color: AppColors.lineSubtle),
                  _permissionTile(
                    'GEOLOCATION TELEMETRY',
                    _locationStatus,
                    _locationStatus == 'Authorized' ? null : _requestLocationPermission,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const FadeSlideIn(index: 5, child: SectionLabel('13 // RUNTIME METADATA')),
          FadeSlideIn(
            index: 5,
            child: AppCard(
              hasShadow: true,
              shadowOffset: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('CLASSIFICATION ENGINE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5)),
                  const SizedBox(height: 4),
                  const Text(
                    'FastAPI microservice executing fine-tuned YAMNet acoustic embeddings (TensorFlow 2.15).',
                    style: TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  const Text('ENDPOINT TARGET', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 0.5)),
                  const SizedBox(height: 4),
                  Text(
                    AppSession.apiBaseUrl,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(AppSession session) {
    final user = session.currentUser;
    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: AppColors.line, width: 1.5),
            ),
            child: Text(
              (user?.displayName.isNotEmpty == true ? user!.displayName[0] : 'E').toUpperCase(),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppColors.ink,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (user?.displayName ?? 'Echo user').toUpperCase(),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                ),
                const SizedBox(height: 2),
                Text(
                  user?.email ?? '',
                  style: const TextStyle(fontSize: 11, color: AppColors.inkMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  'IDENTITY KEY // ${session.userId}',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.line, width: 1.2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onPressed: () async {
              await session.signOut();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('DISCONNECT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.5, color: AppColors.ink)),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard(AppSession session) {
    return ValueListenableBuilder<String>(
      valueListenable: session.modelProfile,
      builder: (context, active, _) {
        return AppCard(
          hasShadow: true,
          shadowOffset: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._profileOptions().map((entry) {
                final name = entry['name']?.toString() ?? 'real';
                final loaded = entry['loaded'] != false;
                final selected = active == name;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    onTap: loaded ? () => session.setModelProfile(name) : null,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.surfaceAlt : AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadii.control),
                        border: Border.all(
                          color: selected ? AppColors.ink : AppColors.lineSubtle,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            margin: const EdgeInsets.only(top: 2),
                            decoration: BoxDecoration(
                              color: selected ? AppColors.primary : AppColors.surface,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: AppColors.line, width: 1.5),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      name == 'demo' ? 'DEMO PROFILE // FIRECRACKER MAPPING' : 'PRODUCTION PROFILE // REAL HAZARDS',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                                    ),
                                    const SizedBox(width: 8),
                                    if (!loaded)
                                      const StatusPill(
                                        label: 'NOT BUILT',
                                        color: AppColors.ink,
                                        background: AppColors.surfaceAlt,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  entry['description']?.toString().toUpperCase() ??
                                      'EIGHT-CLASS SENSOR CLASSIFIER.',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: AppColors.inkMuted,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              if (active == 'demo')
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    border: Border.all(color: AppColors.line, width: 1),
                  ),
                  child: const Text(
                    'NOTE // DEMO PROFILE ACTIVE: Firecracker sound signatures map to gunshot telemetry for presentation without live munitions.',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppColors.ink, height: 1.4),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  List<Map<String, dynamic>> _profileOptions() {
    if (_profiles.isNotEmpty) return _profiles;
    // Backend unreachable: still let the user switch, and say the state is unknown.
    return const [
      {'name': 'real', 'description': 'Eight-class hazard classifier.', 'loaded': true},
      {
        'name': 'demo',
        'description': 'Adds a firecracker class, aliased to gunshot for the demonstration.',
        'loaded': true,
      },
    ];
  }

  Widget _buildEscalationCard(AppSession session) {
    final status = _escalationStatus;
    final telegramOn = status?['telegram_configured'] == true;
    final voiceOn = status?['voice_call_configured'] == true;
    final window = (status?['cancel_window_seconds'] as num?)?.toStringAsFixed(0) ?? '12';
    final minRisk = (status?['min_risk_score'] as num?)?.toStringAsFixed(0) ?? '61';

    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: session.autoEscalation,
            builder: (context, enabled, _) => SwitchListTile(
              activeThumbColor: AppColors.primary,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'AUTONOMOUS ESCALATION DISPATCH',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.3),
              ),
              subtitle: Text(
                'Automatically initiates outbound voice and Telegram alerts after a $window-second abort window.',
                style: const TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.4),
              ),
              value: enabled,
              onChanged: session.setAutoEscalation,
            ),
          ),
          const Divider(height: 1, color: AppColors.lineSubtle),
          const SizedBox(height: 10),
          _channelRow('TELEGRAM DISPATCH CHANNEL', telegramOn),
          const SizedBox(height: 8),
          _channelRow('TWILIO AUTOMATED VOICE RELAY', voiceOn),
          const SizedBox(height: 12),
          Text(
            'ESCALATION FLOOR: RISK SCORE >= $minRisk. Emergency services (112) are never contacted automatically without user confirmation.',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.inkMuted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _channelRow(String label, bool configured) {
    return Row(
      children: [
        Icon(
          configured ? Icons.check_circle_outline : Icons.info_outline,
          size: 16,
          color: AppColors.ink,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.3),
          ),
        ),
        StatusPill(
          label: configured ? 'ONLINE' : 'SIMULATED',
          color: AppColors.ink,
          background: configured ? AppColors.primary : AppColors.surfaceAlt,
        ),
      ],
    );
  }

  Widget _permissionTile(String title, String status, VoidCallback? onTap) {
    final ok = status == 'Authorized';
    return ListTile(
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 0.3)),
      subtitle: Text(status.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.inkMuted)),
      trailing: Icon(
        ok ? Icons.check_circle_outline : Icons.error_outline,
        color: ok ? AppColors.ink : AppColors.vermilion,
        size: 18,
      ),
      onTap: onTap,
    );
  }
}
