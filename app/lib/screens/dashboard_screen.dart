import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';
import '../widgets/audio_visualizer.dart';
import 'settings_screen.dart';

/// Home dashboard: status, who would be alerted, context signals, activity.
class DashboardScreen extends StatefulWidget {
  final bool isMonitoring;
  final bool mediaPlayback;
  final bool suddenMotion;
  // Whether MotionService's accelerometer auto-detector has fired within its
  // hold window. This is display-only: it never changes what `suddenMotion`
  // reports, it just tells the user their manual toggle is not the only
  // source of this signal. See MotionService's doc comment.
  final bool autoMotionDetected;
  final double sensitivityThreshold;
  final ValueChanged<bool> onMediaPlaybackChanged;
  final ValueChanged<bool> onSuddenMotionChanged;
  final ValueChanged<double> onSensitivityChanged;
  final VoidCallback onOpenMonitor;
  final VoidCallback onOpenContacts;

  const DashboardScreen({
    super.key,
    required this.isMonitoring,
    required this.mediaPlayback,
    required this.suddenMotion,
    required this.autoMotionDetected,
    required this.sensitivityThreshold,
    required this.onMediaPlaybackChanged,
    required this.onSuddenMotionChanged,
    required this.onSensitivityChanged,
    required this.onOpenMonitor,
    required this.onOpenContacts,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ApiService _api = ApiService();

  Map<String, dynamic>? _readiness;
  List<Map<String, dynamic>> _recentEvents = const [];
  bool _loading = true;
  bool _backendReachable = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final userId = AppSession.instance.userId;
    final results = await Future.wait([
      _api.escalationReadiness(userId),
      _api.getEventHistory(userId),
    ]);
    if (!mounted) return;
    final readiness = results[0] as Map<String, dynamic>?;
    final events = results[1] as List<Map<String, dynamic>>?;
    setState(() {
      _loading = false;
      _backendReachable = readiness != null || events != null;
      _readiness = readiness;
      _recentEvents = (events ?? const []).take(4).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = AppSession.instance;
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.primary,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          FadeSlideIn(index: 0, child: _buildHeader(session)),
          const SizedBox(height: 20),
          FadeSlideIn(index: 1, child: _buildHero()),
          if (!_backendReachable && !_loading) ...[
            const SizedBox(height: 14),
            FadeSlideIn(index: 2, child: _buildBackendWarning()),
          ],
          const SizedBox(height: 20),
          FadeSlideIn(index: 2, child: _buildEscalationCard()),
          const SizedBox(height: 24),
          const FadeSlideIn(index: 3, child: SectionLabel('Device context signals')),
          FadeSlideIn(index: 3, child: _buildContextCard()),
          const SizedBox(height: 24),
          FadeSlideIn(
            index: 4,
            child: SectionLabel(
              'Recent detections',
              trailing: TextButton(
                onPressed: _refresh,
                child: const Text('Refresh', style: TextStyle(fontSize: 12)),
              ),
            ),
          ),
          FadeSlideIn(index: 4, child: _buildRecentEvents()),
        ],
      ),
    );
  }

  Widget _buildHeader(AppSession session) {
    final name = session.displayName;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.primary,
            border: Border.all(color: AppColors.line, width: 1.5),
            boxShadow: neoShadow(offset: 2),
          ),
          alignment: Alignment.center,
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : 'E',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: AppColors.ink,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '00 // SYSTEM_SHIELD',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w900,
                  color: AppColors.inkMuted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                name.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<String>(
          valueListenable: session.modelProfile,
          builder: (context, profile, _) => profile == 'demo'
              ? const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: StatusPill(
                    label: 'DEMO MODEL',
                    color: AppColors.ink,
                    background: AppColors.primary,
                    icon: Icons.science_outlined,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.line, width: 1.2),
          ),
          child: IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20, color: AppColors.ink),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SettingsScreen(
                  sensitivityThreshold: widget.sensitivityThreshold,
                  onSensitivityChanged: widget.onSensitivityChanged,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHero() {
    final monitoring = widget.isMonitoring;
    return AppCard(
      hasShadow: true,
      shadowOffset: 4,
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          PulseRing(
            active: monitoring,
            color: monitoring ? AppColors.primary : AppColors.lineSubtle,
            size: 154,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: monitoring ? AppColors.primary : AppColors.surfaceAlt,
                border: Border.all(color: AppColors.line, width: 1.5),
              ),
              child: Icon(
                monitoring ? Icons.hearing : Icons.hearing_disabled,
                size: 34,
                color: AppColors.ink,
              ),
            ),
          ),
          const SizedBox(height: 16),
          StatusPill(
            label: monitoring ? 'TELEMETRY // ACTIVE' : 'TELEMETRY // STANDBY',
            color: monitoring ? AppColors.ink : AppColors.inkMuted,
            background: monitoring ? AppColors.primary : AppColors.surfaceAlt,
            icon: monitoring ? Icons.circle : Icons.pause_circle_outline,
          ),
          const SizedBox(height: 12),
          Text(
            monitoring
                ? 'Echo is analysing 2-second windows and verifying anything suspicious over 5 seconds.'
                : 'Monitoring runs on the Live Monitor tab, where the microphone session lives.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: AppColors.inkMuted, height: 1.5),
          ),
          const SizedBox(height: 18),
          PressableScale(
            child: ElevatedButton.icon(
              onPressed: widget.onOpenMonitor,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.line, width: 1.5),
              ),
              icon: Icon(
                monitoring ? Icons.open_in_full : Icons.play_arrow_rounded,
                size: 18,
                color: AppColors.ink,
              ),
              label: Text(monitoring ? 'VIEW LIVE MONITOR' : 'OPEN LIVE MONITOR'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackendWarning() {
    return AppCard(
      background: AppColors.primary,
      borderColor: AppColors.line,
      hasShadow: true,
      shadowOffset: 3,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 20, color: AppColors.ink),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'ERR // BACKEND UNREACHABLE AT ${AppSession.apiBaseUrl}. Telemetry and alert services offline.',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                height: 1.4,
                color: AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEscalationCard() {
    final readiness = _readiness;
    final ready = readiness?['ready'] == true;
    final contactCount = (readiness?['contact_count'] as num?)?.toInt() ?? 0;
    final blockers = List<String>.from(readiness?['blockers'] as Iterable? ?? const []);
    final channels = readiness?['channels'] as Map<String, dynamic>?;
    final simulated = channels?['simulation_mode'] == true;

    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      onTap: widget.onOpenContacts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: ready ? AppColors.primary : AppColors.surfaceAlt,
                  border: Border.all(color: AppColors.line, width: 1.2),
                ),
                child: Icon(
                  ready ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined,
                  size: 16,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'DISPATCH READY STATE',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: AppColors.ink,
                  ),
                ),
              ),
              StatusPill(
                label: _loading ? 'SYNCING' : (ready ? 'VERIFIED' : 'PENDING'),
                color: AppColors.ink,
                background: ready ? AppColors.primary : AppColors.surfaceAlt,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            contactCount == 0
                ? 'No emergency contacts registered. Protocol dispatch offline.'
                : '$contactCount contact${contactCount == 1 ? '' : 's'} linked. Escalation sequence primed for automated voice dispatch, 5s telemetry clip, and Telegram coordinate broadcast.',
            style: const TextStyle(fontSize: 12, color: AppColors.inkMuted, height: 1.5),
          ),
          if (simulated) ...[
            const SizedBox(height: 10),
            const StatusPill(
              label: 'PROTOCOL // SIMULATION MODE',
              color: AppColors.ink,
              background: AppColors.surfaceAlt,
              icon: Icons.science_outlined,
            ),
          ],
          if (blockers.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...blockers.take(3).map(
                  (blocker) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '!',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: AppColors.vermilion,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            blocker,
                            style: const TextStyle(fontSize: 12, color: AppColors.inkMuted, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              border: Border.all(color: AppColors.lineSubtle, width: 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text(
                  'CONFIGURE RECIPIENTS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: AppColors.ink,
                  ),
                ),
                Icon(Icons.arrow_forward, size: 14, color: AppColors.ink),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextCard() {
    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            activeThumbColor: AppColors.primary,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: const Text(
              'MEDIA SUPPRESSION FILTER',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.3),
            ),
            subtitle: const Text(
              'Attenuate confidence when entertainment or speech media is active',
              style: TextStyle(fontSize: 11, color: AppColors.inkMuted),
            ),
            value: widget.mediaPlayback,
            onChanged: widget.onMediaPlaybackChanged,
          ),
          const Divider(height: 1, color: AppColors.lineSubtle),
          SwitchListTile(
            activeThumbColor: AppColors.primary,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Flexible(
                  child: Text(
                    'HIGH ACCEL SENSOR TRIGGER',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                  ),
                ),
                if (widget.autoMotionDetected) ...[
                  const SizedBox(width: 8),
                  const StatusPill(
                    label: 'AUTO-TRIPPED',
                    color: AppColors.ink,
                    background: AppColors.primary,
                    icon: Icons.vibration,
                  ),
                ],
              ],
            ),
            subtitle: const Text(
              'Escalates threat weight upon kinetic shock or sudden velocity change',
              style: TextStyle(fontSize: 11, color: AppColors.inkMuted),
            ),
            value: widget.suddenMotion,
            onChanged: widget.onSuddenMotionChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildRecentEvents() {
    if (_loading) {
      return const AppCard(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(color: AppColors.ink),
          ),
        ),
      );
    }
    if (_recentEvents.isEmpty) {
      return AppCard(
        child: Row(
          children: const [
            Icon(Icons.check_circle_outline, color: AppColors.ink, size: 20),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'LOGS // ZERO THREAT SIGNATURES RECORDED',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: AppColors.inkMuted,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: _recentEvents.map((event) {
        final level = event['risk_level']?.toString() ?? 'NORMAL';
        final color = AppColors.forRiskLevel(level);
        final timestamp = DateTime.fromMillisecondsSinceEpoch(
          (((event['timestamp'] as num?) ?? 0) * 1000).round(),
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AppCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.softForRiskLevel(level),
                    border: Border.all(color: AppColors.line, width: 1.2),
                  ),
                  child: Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.ink),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (event['class_name']?.toString() ?? 'unknown').replaceAll('_', ' ').toUpperCase(),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${timestamp.day.toString().padLeft(2, '0')}/${timestamp.month.toString().padLeft(2, '0')} '
                        '${timestamp.hour.toString().padLeft(2, '0')}:'
                        '${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    border: Border.all(color: AppColors.line, width: 1),
                  ),
                  child: AnimatedCounter(
                    value: (event['risk_score'] as num?)?.toInt() ?? 0,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
