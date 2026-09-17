import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';

/// Two records, deliberately kept apart:
///   * Detections -- everything the model verified, including events that were
///     logged but never escalated.
///   * Escalations -- what actually reached another human being, per channel.
/// Collapsing them into one list would hide the difference between "Echo
/// noticed something" and "somebody was called".
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with SingleTickerProviderStateMixin {
  final ApiService _api = ApiService();
  late final TabController _tabs = TabController(length: 2, vsync: this);

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _events = const [];
  List<Map<String, dynamic>> _incidents = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final userId = AppSession.instance.userId;
    final results = await Future.wait([
      _api.getEventHistory(userId),
      _api.getIncidentHistory(userId),
    ]);
    if (!mounted) return;
    final events = results[0];
    final incidents = results[1];
    setState(() {
      _loading = false;
      if (events == null && incidents == null) {
        _error = 'Could not reach the backend at ${AppSession.apiBaseUrl}.';
      }
      _events = events ?? const [];
      _incidents = incidents ?? const [];
    });
  }

  Future<void> _clearEvents() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          side: const BorderSide(color: AppColors.line, width: 1.5),
        ),
        title: const Text(
          'PURGE DETECTION LOGS?',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 0.5),
        ),
        content: const Text(
          'This purges recorded acoustic telemetry signatures from local cache. Outbound dispatch records and Telegram audit logs are retained permanently.',
          style: TextStyle(fontSize: 12, color: AppColors.inkMuted, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.vermilion,
              foregroundColor: AppColors.surface,
              side: const BorderSide(color: AppColors.line, width: 1.2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.control)),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('PURGE RECORDS', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _api.clearEventHistory(AppSession.instance.userId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      '07 // INCIDENT LOGS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                        color: AppColors.inkMuted,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'AUDIT TRAIL',
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
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.line, width: 1.2),
                ),
                child: IconButton(
                  icon: const Icon(Icons.refresh, size: 18, color: AppColors.ink),
                  onPressed: _load,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.line, width: 1.2),
                ),
                child: IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppColors.ink, size: 18),
                  onPressed: _clearEvents,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppColors.line, width: 1.5),
            ),
          ),
          child: TabBar(
            controller: _tabs,
            labelColor: AppColors.ink,
            unselectedLabelColor: AppColors.inkMuted,
            indicatorColor: AppColors.primary,
            indicatorWeight: 3,
            indicatorSize: TabBarIndicatorSize.tab,
            labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.5),
            tabs: [
              Tab(text: 'DETECTIONS [ ${_events.length} ]'),
              Tab(text: 'DISPATCHES [ ${_incidents.length} ]'),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_error!, style: const TextStyle(color: AppColors.vermilion, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.ink))
              : TabBarView(
                  controller: _tabs,
                  children: [
                    RefreshIndicator(
                      onRefresh: _load,
                      color: AppColors.ink,
                      child: _buildEvents(),
                    ),
                    RefreshIndicator(
                      onRefresh: _load,
                      color: AppColors.ink,
                      child: _buildIncidents(),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildEvents() {
    if (_events.isEmpty) return _empty('ARCHIVE EMPTY // ZERO DETECTIONS LOGGED');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: _events.length,
      itemBuilder: (context, index) {
        final event = _events[index];
        final level = event['risk_level']?.toString() ?? 'NORMAL';
        final color = AppColors.forRiskLevel(level);
        return FadeSlideIn(
          index: index,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppCard(
              hasShadow: true,
              shadowOffset: 2,
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.softForRiskLevel(level),
                      border: Border.all(color: AppColors.line, width: 1.2),
                    ),
                    child: Icon(Icons.graphic_eq, size: 18, color: AppColors.ink),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (event['class_name']?.toString() ?? '').replaceAll('_', ' ').toUpperCase(),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_formatTime(event['timestamp'])} // '
                          'P1: ${_pct(event['primary_conf'])} · P2: ${_pct(event['verification_conf'])}',
                          style: const TextStyle(fontSize: 10, color: AppColors.inkMuted, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      border: Border.all(color: AppColors.line, width: 1),
                    ),
                    child: Text(
                      'SCORE ${event['risk_score'] ?? 0}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIncidents() {
    if (_incidents.isEmpty) {
      return _empty('DISPATCH ARCHIVE EMPTY // ZERO OUTBOUND ALARMS');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: _incidents.length,
      itemBuilder: (context, index) {
        final incident = _incidents[index];
        final state = incident['state']?.toString() ?? 'UNKNOWN';
        final attempts = List<Map<String, dynamic>>.from(
          incident['attempts'] as Iterable? ?? const [],
        );
        final color = switch (state) {
          'DISPATCHED' => AppColors.vermilion,
          'CANCELLED' => AppColors.ink,
          'PENDING' => AppColors.primary,
          _ => AppColors.inkMuted,
        };

        return FadeSlideIn(
          index: index,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AppCard(
              hasShadow: true,
              shadowOffset: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          (incident['class_name']?.toString() ?? '').replaceAll('_', ' ').toUpperCase(),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                        ),
                      ),
                      if (incident['profile'] == 'demo')
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: StatusPill(
                            label: 'DEMO',
                            color: AppColors.ink,
                            background: AppColors.primary,
                          ),
                        ),
                      StatusPill(
                        label: state,
                        color: color,
                        background: AppColors.surfaceAlt,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_formatTime(incident['created_at'])} · THREAT ${incident['risk_score'] ?? 0}/100'
                    '${incident['raw_class'] != null && incident['raw_class'] != incident['class_name'] ? ' · RAW ${incident['raw_class']}' : ''}',
                    style: const TextStyle(fontSize: 11, color: AppColors.inkMuted, fontWeight: FontWeight.w600),
                  ),
                  if (incident['note'] != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      incident['note'].toString().toUpperCase(),
                      style: const TextStyle(fontSize: 10, color: AppColors.inkMuted, height: 1.4, fontWeight: FontWeight.w700),
                    ),
                  ],
                  if (attempts.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Divider(height: 1, color: AppColors.lineSubtle),
                    const SizedBox(height: 10),
                    ...attempts.map(
                      (attempt) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: AppColors.surfaceAlt,
                                border: Border.all(color: AppColors.lineSubtle, width: 1),
                              ),
                              child: Icon(
                                attempt['channel'] == 'telegram'
                                    ? Icons.send_outlined
                                    : Icons.phone_in_talk_outlined,
                                size: 12,
                                color: AppColors.ink,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${(attempt['contact_name'] ?? 'Contact').toString().toUpperCase()} // ${(attempt['status'] ?? '').toString().toUpperCase()}',
                                style: const TextStyle(fontSize: 11, color: AppColors.ink, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _empty(String message) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 40),
        Icon(Icons.inbox_outlined, size: 40, color: AppColors.lineSubtle),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: AppColors.inkMuted, height: 1.5),
        ),
      ],
    );
  }

  String _pct(dynamic value) => '${(((value as num?) ?? 0) * 100).toStringAsFixed(0)}%';

  String _formatTime(dynamic epochSeconds) {
    final time = DateTime.fromMillisecondsSinceEpoch(
      ((((epochSeconds as num?) ?? 0)) * 1000).round(),
    );
    return '${time.day.toString().padLeft(2, '0')}/${time.month.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
