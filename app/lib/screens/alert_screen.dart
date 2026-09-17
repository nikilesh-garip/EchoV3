import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';
import '../widgets/audio_visualizer.dart';

/// Full-screen alert with the outbound escalation front and centre.
///
/// The old version told the person already standing in the room that
/// something happened. This one shows what is about to be sent to the people
/// who can actually help, gives that person a countdown to stop it, and then
/// reports, per contact and per channel, what really went out.
class AlertScreen extends StatefulWidget {
  final String title;
  final String threatClass;
  final String? rawClass;
  final int riskScore;
  final String riskLevel;
  final double p1Conf;
  final double p2Conf;
  final List<String> instructions;
  final List<Map<String, dynamic>> nearbyFacilities;
  final Map<String, dynamic>? incident;
  final String profile;

  const AlertScreen({
    super.key,
    required this.title,
    required this.threatClass,
    required this.riskScore,
    required this.riskLevel,
    required this.p1Conf,
    required this.p2Conf,
    required this.instructions,
    required this.nearbyFacilities,
    this.rawClass,
    this.incident,
    this.profile = 'real',
  });

  @override
  State<AlertScreen> createState() => _AlertScreenState();
}

class _AlertScreenState extends State<AlertScreen> {
  final ApiService _api = ApiService();
  Timer? _pollTimer;
  Map<String, dynamic>? _incident;
  bool _busy = false;
  // The cancel window is whatever the backend armed this incident with; the
  // ring needs that as its denominator, so capture it the first time we see it.
  double _countdownTotal = 0;

  @override
  void initState() {
    super.initState();
    _incident = widget.incident;
    _countdownTotal = ((_incident?['seconds_to_dispatch'] as num?) ?? 0).toDouble();
    if (_incident?['state'] == 'PENDING') {
      _pollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) => _refreshIncident());
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshIncident() async {
    final id = _incident?['id']?.toString();
    if (id == null) return;
    final updated = await _api.getIncident(id);
    if (!mounted || updated == null) return;
    setState(() => _incident = updated);
    if (updated['state'] != 'PENDING') {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  Future<void> _cancel() async {
    final id = _incident?['id']?.toString();
    if (id == null) return;
    setState(() => _busy = true);
    final response = await _api.cancelIncident(
      incidentId: id,
      userId: AppSession.instance.userId,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (response?['incident'] != null) {
        _incident = response!['incident'] as Map<String, dynamic>;
      }
    });
    if (response != null && response['cancelled'] != true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response['reason']?.toString() ?? 'Could not cancel.')),
      );
    }
  }

  Future<void> _dispatchNow() async {
    final id = _incident?['id']?.toString();
    if (id == null) return;
    setState(() => _busy = true);
    final updated = await _api.dispatchIncidentNow(
      incidentId: id,
      userLabel: AppSession.instance.displayName,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (updated != null) _incident = updated;
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = AppColors.forRiskLevel(widget.riskLevel);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(color),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                children: [
                  FadeSlideIn(index: 0, child: _buildEscalationCard()),
                  const SizedBox(height: 22),
                  const FadeSlideIn(index: 1, child: SectionLabel('Detection evidence')),
                  FadeSlideIn(index: 1, child: _buildEvidenceCard()),
                  const SizedBox(height: 22),
                  const FadeSlideIn(index: 2, child: SectionLabel('What to do now')),
                  FadeSlideIn(index: 2, child: _buildGuidanceCard()),
                  const SizedBox(height: 22),
                  const FadeSlideIn(index: 3, child: SectionLabel('Nearby public services')),
                  FadeSlideIn(index: 3, child: _buildFacilities()),
                ],
              ),
            ),
            _buildBottomActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      decoration: BoxDecoration(
        color: AppColors.primary,
        border: const Border(
          bottom: BorderSide(color: AppColors.line, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const StatusPill(
                label: 'CRITICAL ALERT // PROTOCOL ACTIVATED',
                color: AppColors.ink,
                background: AppColors.surface,
                icon: Icons.warning_amber_rounded,
              ),
              const Spacer(),
              if (widget.profile == 'demo')
                const StatusPill(
                  label: 'DEMO PROFILE',
                  color: AppColors.ink,
                  background: AppColors.surface,
                  icon: Icons.science_outlined,
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            widget.threatClass.replaceAll('_', ' ').toUpperCase(),
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: AppColors.ink,
              letterSpacing: 1.0,
            ),
          ),
          if (widget.rawClass != null && widget.rawClass != widget.threatClass) ...[
            const SizedBox(height: 4),
            Text(
              'RAW ACOUSTIC SIGNATURE: ${widget.rawClass!.toUpperCase()}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.inkMuted,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: AppColors.line, width: 1.2),
            ),
            child: Text(
              'THREAT SCORE ${widget.riskScore}/100 · ${widget.riskLevel.replaceAll('_', ' ')}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.ink,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEscalationCard() {
    final incident = _incident;
    if (incident == null) {
      return AppCard(
        background: AppColors.surfaceAlt,
        child: Row(
          children: const [
            Icon(Icons.notifications_off_outlined, size: 20, color: AppColors.inkMuted),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'No contact escalation was created for this detection. Check auto-escalation '
                'in Settings and make sure a contact is saved.',
                style: TextStyle(fontSize: 13, color: AppColors.inkMuted, height: 1.5),
              ),
            ),
          ],
        ),
      );
    }

    final state = incident['state']?.toString() ?? 'UNKNOWN';
    final armed = incident['escalation_armed'];
    final gateReason = incident['gate_reason']?.toString();

    switch (state) {
      case 'PENDING':
        return _buildCountdownCard(incident);
      case 'CANCELLED':
        return _buildStateCard(
          icon: Icons.verified_outlined,
          color: AppColors.success,
          background: AppColors.successSoft,
          title: 'Alert cancelled',
          body: 'Nobody was called or messaged. The detection is still recorded in your history.',
        );
      case 'SUPPRESSED':
        return _buildStateCard(
          icon: Icons.filter_alt_outlined,
          color: AppColors.info,
          background: AppColors.infoSoft,
          title: 'Contacts were not alerted',
          body: gateReason ?? 'This detection did not meet the escalation policy.',
        );
      case 'NO_CONTACTS':
        return _buildStateCard(
          icon: Icons.person_off_outlined,
          color: AppColors.danger,
          background: AppColors.dangerSoft,
          title: 'Nobody could be alerted',
          body: 'No emergency contact is saved. Add one on the Contacts tab so this never '
              'happens again.',
        );
      default:
        return _buildDispatchedCard(incident, armed);
    }
  }

  Widget _buildCountdownCard(Map<String, dynamic> incident) {
    final remaining = (incident['seconds_to_dispatch'] as num?)?.toDouble() ?? 0.0;
    final total = _countdownTotal > 0 ? _countdownTotal : (remaining > 0 ? remaining : 12.0);
    return AppCard(
      hasShadow: true,
      shadowOffset: 4,
      borderColor: AppColors.line,
      child: Column(
        children: [
          const Text(
            'ESC // DISPATCH SEQUENCE ARMED',
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w900,
              color: AppColors.vermilion,
            ),
          ),
          const SizedBox(height: 14),
          CountdownRing(remainingSeconds: remaining, totalSeconds: total),
          const SizedBox(height: 14),
          const Text(
            'Automated voice alert with 5s acoustic recording and Telegram GPS coordinates will broadcast to all registered emergency contacts upon countdown expiry.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.inkMuted, height: 1.5),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: PressableScale(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _cancel,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.ink,
                      side: const BorderSide(color: AppColors.line, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.shield_outlined, size: 18, color: AppColors.ink),
                    label: const Text(
                      "ABORT // I'M SAFE",
                      style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PressableScale(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _dispatchNow,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.ink,
                      foregroundColor: AppColors.surface,
                      side: const BorderSide(color: AppColors.line, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: const Icon(Icons.campaign_outlined, size: 18, color: AppColors.surface),
                    label: const Text(
                      'FORCE DISPATCH',
                      style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStateCard({
    required IconData icon,
    required Color color,
    required Color background,
    required String title,
    required String body,
  }) {
    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      background: background,
      borderColor: AppColors.line,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.control / 2),
              border: Border.all(color: AppColors.line, width: 1.2),
            ),
            child: Icon(icon, size: 18, color: AppColors.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(fontSize: 12, height: 1.5, color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDispatchedCard(Map<String, dynamic> incident, dynamic armed) {
    final attempts = List<Map<String, dynamic>>.from(
      (incident['attempts'] as Iterable?) ?? const [],
    );
    final anySimulated = attempts.any((a) => a['status'] == 'simulated');
    final rawPlaceLabel = incident['place_label']?.toString();
    final placeLabel =
        (rawPlaceLabel == null || rawPlaceLabel == 'Last known location' || rawPlaceLabel.isEmpty)
            ? null
            : rawPlaceLabel;

    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppRadii.control / 2),
                  border: Border.all(color: AppColors.line, width: 1.2),
                ),
                child: const Icon(Icons.campaign, size: 16, color: AppColors.ink),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'ESCALATION DISPATCH LOG',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: AppColors.ink,
                  ),
                ),
              ),
              if (anySimulated)
                const StatusPill(
                  label: 'SIMULATED',
                  color: AppColors.ink,
                  background: AppColors.surfaceAlt,
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (attempts.isEmpty)
            const Text(
              'DISPATCHING...',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.inkMuted,
              ),
            ),
          ...attempts.map(_buildAttemptRow),
          if (placeLabel != null && placeLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                border: Border.all(color: AppColors.lineSubtle, width: 1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.place_outlined, size: 16, color: AppColors.ink),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'DISPATCH COORDINATE: $placeLabel',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (anySimulated) ...[
            const SizedBox(height: 10),
            const Text(
              'Simulated transmission: Bot tokens/SIP credentials pending. Payload logged to disk.',
              style: TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAttemptRow(Map<String, dynamic> attempt) {
    final status = attempt['status']?.toString() ?? 'unknown';
    final channel = attempt['channel']?.toString() ?? 'unknown';
    final color = switch (status) {
      'sent' => AppColors.ink,
      'simulated' => AppColors.inkMuted,
      _ => AppColors.vermilion,
    };
    final icon = switch (channel) {
      'telegram' => Icons.send_outlined,
      'voice_call' => Icons.phone_in_talk_outlined,
      _ => Icons.error_outline,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: status == 'sent' ? AppColors.primary : AppColors.surfaceAlt,
              border: Border.all(color: AppColors.line, width: 1.2),
            ),
            child: Icon(icon, size: 16, color: AppColors.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${(attempt['contact_name'] ?? 'Contact').toString().toUpperCase()} · '
                  '${channel == 'voice_call' ? 'AUTOMATED CALL' : 'TELEGRAM'}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                ),
                const SizedBox(height: 2),
                Text(
                  attempt['detail']?.toString() ?? status,
                  style: const TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusPill(
            label: status.toUpperCase(),
            color: color,
            background: AppColors.surfaceAlt,
          ),
        ],
      ),
    );
  }

  Widget _buildEvidenceCard() {
    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      child: Row(
        children: [
          RiskGauge(score: widget.riskScore, level: widget.riskLevel, size: 110),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _confidenceLine('PASS 1 · PRIMARY (2S)', widget.p1Conf),
                const SizedBox(height: 12),
                _confidenceLine('PASS 2 · VERIFICATION (5S)', widget.p2Conf),
                const SizedBox(height: 12),
                Text(
                  _incident?['has_clip'] == true
                      ? '5-second high-fidelity acoustic evidence preserved.'
                      : 'Zero evidence clip archived.',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _confidenceLine(String label, double value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: AppColors.inkMuted,
              ),
            ),
            Text(
              '${(value * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: AppColors.ink),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            border: Border.all(color: AppColors.line, width: 1),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(
              color: AppColors.primary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGuidanceCard() {
    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widget.instructions
            .asMap()
            .entries
            .map(
              (entry) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        border: Border.all(color: AppColors.line, width: 1),
                      ),
                      child: Text(
                        '0${entry.key + 1}',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.value,
                        style: const TextStyle(fontSize: 12, height: 1.5, color: AppColors.ink),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildFacilities() {
    return Column(
      children: widget.nearbyFacilities
          .map(
            (facility) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(
                hasShadow: true,
                shadowOffset: 2,
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(AppRadii.control / 2),
                        border: Border.all(color: AppColors.line, width: 1.2),
                      ),
                      child: const Icon(Icons.place_outlined, size: 18, color: AppColors.ink),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            facility['name']?.toString().toUpperCase() ?? 'UNNAMED FACILITY',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            facility['address']?.toString() ?? '',
                            style: const TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildBottomActions() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: const Border(top: BorderSide(color: AppColors.line, width: 1.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: PressableScale(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.vermilion,
                  foregroundColor: AppColors.surface,
                  side: const BorderSide(color: AppColors.line, width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () async {
                  final uri = Uri(scheme: 'tel', path: '112');
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  } else if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Could not open the phone dialer on this device.')),
                    );
                  }
                },
                icon: const Icon(Icons.call, size: 18, color: AppColors.surface),
                label: const Text(
                  'DIRECT CALL // 112',
                  style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.line, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'DISMISS VIEW',
                style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5, color: AppColors.ink),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
