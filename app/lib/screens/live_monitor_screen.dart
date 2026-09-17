import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../services/api_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';
import '../widgets/audio_visualizer.dart';
import 'alert_screen.dart';

/// One analysed audio window: the model's answer plus the audio it heard.
class _AnalysedWindow {
  final Map<String, dynamic>? result;
  final List<int>? clipBytes;
  final double seconds;

  const _AnalysedWindow(this.result, this.clipBytes, this.seconds);
}

class LiveMonitorScreen extends StatefulWidget {
  final bool mediaPlayback;
  final bool suddenMotion;
  final double sensitivityThreshold;
  final ValueChanged<bool> onMonitoringChanged;

  const LiveMonitorScreen({
    super.key,
    required this.mediaPlayback,
    required this.suddenMotion,
    required this.sensitivityThreshold,
    required this.onMonitoringChanged,
  });

  @override
  State<LiveMonitorScreen> createState() => _LiveMonitorScreenState();
}

class _LiveMonitorScreenState extends State<LiveMonitorScreen> {
  final ApiService _apiService = ApiService();
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Timer? _monitorTimer;

  String _currentClass = 'normal';
  String? _rawClass;
  double _p1Confidence = 0.0;
  double _p2Confidence = 0.0;
  int _riskScore = 0;
  String _riskLevel = 'NORMAL';
  bool _isMonitoring = false;
  bool _pipelineBusy = false;
  bool _alertOpen = false;
  double _amplitude = 0.0;
  String _stage = 'Idle';
  String? _monitorError;

  @override
  void initState() {
    super.initState();
    // The recorder only emits amplitudes while a capture is running, so this
    // subscription is created once and simply goes quiet between windows.
    _amplitudeSubscription =
        _recorder.onAmplitudeChanged(const Duration(milliseconds: 90)).listen((amplitude) {
      if (!mounted) return;
      // dBFS (roughly -60 .. 0) normalised to 0..1 for the visualiser.
      final normalised = ((amplitude.current + 55) / 55).clamp(0.0, 1.0);
      setState(() => _amplitude = normalised);
    });
  }

  // ------------------------------------------------------------------
  // Detection pipeline
  // ------------------------------------------------------------------

  Future<_AnalysedWindow> _recordAndAnalyze(
    double duration, {
    String? primaryCandidate,
    double? primaryConfidence,
  }) async {
    final tempDirectory = await getTemporaryDirectory();
    final file = File(
      '${tempDirectory.path}${Platform.pathSeparator}echo_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
      path: file.path,
    );

    await Future<void>.delayed(Duration(milliseconds: (duration * 1000).round()));
    final outputPath = await _recorder.stop();
    if (outputPath == null) {
      throw StateError('The microphone did not produce an audio file.');
    }

    final outputFile = File(outputPath);
    List<int>? clipBytes;
    try {
      // Read the bytes before analysing: if this window turns out to be the
      // one that triggers an alert, these exact bytes are the evidence clip
      // the contacts hear. Re-recording afterwards would send audio from a
      // different moment than the one the model reacted to.
      clipBytes = await outputFile.readAsBytes();
      final result = await _apiService.detectAudio(
        audioFile: outputFile,
        duration: duration,
        mediaPlayback: widget.mediaPlayback,
        suddenMotion: widget.suddenMotion,
        primaryCandidate: primaryCandidate,
        primaryConfidence: primaryConfidence,
        sensitivityThreshold: widget.sensitivityThreshold,
        userId: AppSession.instance.userId,
        profile: AppSession.instance.modelProfile.value,
      );
      _applyResult(result);
      return _AnalysedWindow(result, clipBytes, duration);
    } finally {
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
    }
  }

  void _applyResult(Map<String, dynamic>? result) {
    if (!mounted) return;
    if (result == null) {
      setState(() => _monitorError =
          'Backend unreachable — could not analyse the last audio window.');
      return;
    }
    setState(() {
      _monitorError = null;
      _currentClass = result['candidate']?.toString() ?? 'normal';
      _rawClass = result['raw_candidate']?.toString();
      _p1Confidence = ((result['primary_confidence'] ?? result['confidence']) as num?)?.toDouble() ?? 0.0;
      _p2Confidence = (result['verification_confidence'] as num?)?.toDouble() ?? 0.0;
      _riskScore = (result['risk_score'] as num?)?.toInt() ?? 0;
      _riskLevel = result['risk_level']?.toString() ?? 'NORMAL';
    });
  }

  Future<void> _runMonitoringCycle() async {
    if (!_isMonitoring || _pipelineBusy || _alertOpen) return;
    _pipelineBusy = true;
    try {
      setState(() => _stage = 'Pass 1 · listening (2s)');
      final passOne = await _recordAndAnalyze(2.0);
      final result = passOne.result;
      if (result == null) return;

      if (result['immediate_verification'] == true && result['verified'] == true) {
        await _maybeRaiseAlert(result, passOne);
        return;
      }

      final rawCandidate = (result['raw_candidate'] ?? result['candidate'])?.toString();
      final confidence = (result['confidence'] as num?)?.toDouble();
      if (result['has_candidate'] == true && rawCandidate != null && confidence != null) {
        if (!_isMonitoring) return;
        setState(() => _stage = 'Pass 2 · verifying (5s)');
        final passTwo = await _recordAndAnalyze(
          5.0,
          // The raw class is what pass 2 must verify: on the demo head a
          // firecracker candidate is reported as "gunshot", and sending that
          // back would ask pass 2 to verify a class the head never predicted.
          primaryCandidate: rawCandidate,
          primaryConfidence: confidence,
        );
        if (passTwo.result != null) {
          await _maybeRaiseAlert(passTwo.result!, passTwo);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _monitorError = 'Monitoring paused: $error');
    } finally {
      _pipelineBusy = false;
      if (mounted && _isMonitoring) setState(() => _stage = 'Listening');
    }
  }

  // ------------------------------------------------------------------
  // Alerting + escalation
  // ------------------------------------------------------------------

  Future<void> _maybeRaiseAlert(Map<String, dynamic> result, _AnalysedWindow window) async {
    if (result['verified'] != true) return;
    final riskScore = (result['risk_score'] as num?)?.toInt() ?? 0;
    if (riskScore <= 30) return;

    final session = AppSession.instance;
    final className = result['candidate']?.toString() ?? 'unknown';
    final rawClass = result['raw_candidate']?.toString();

    await _apiService.logEvent(
      userId: session.userId,
      className: className,
      primaryConf: _p1Confidence,
      verificationConf: _p2Confidence,
      riskScore: riskScore,
      riskLevel: _riskLevel,
    );

    // A moderate-confidence ("SUSPICIOUS") read is worth logging, not worth a
    // full-screen alarm -- see docs/DECISIONS_LOG.md #10. Reserve the alert
    // screen (and the incident it would arm) for POSSIBLE_DANGER/HIGH_RISK;
    // the backend's own escalation floor (ECHO_MIN_ESCALATION_RISK, default
    // 61) would never actually dispatch below that anyway, so creating an
    // incident here would only ever come back suppressed.
    if (_riskLevel != 'POSSIBLE_DANGER' && _riskLevel != 'HIGH_RISK') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'Possible ${className.replaceAll('_', ' ')} ($riskScore/100, $_riskLevel) '
              '— logged, below the alert threshold.',
            ),
          ),
        );
      }
      return;
    }

    final position = await _currentPosition();

    // The incident is what actually reaches other people: it arms the
    // countdown, then calls and messages the saved contacts with this clip.
    Map<String, dynamic>? incident;
    if (result['should_alert'] == true && session.autoEscalation.value) {
      incident = await _apiService.createIncident(
        userId: session.userId,
        className: className,
        rawClass: rawClass,
        profile: session.modelProfile.value,
        primaryConf: _p1Confidence,
        verificationConf: _p2Confidence,
        riskScore: riskScore,
        riskLevel: _riskLevel,
        verified: true,
        latitude: position?.latitude,
        longitude: position?.longitude,
        accuracyM: position?.accuracy,
        placeLabel: 'Last known location',
        userLabel: session.displayName,
        clipBytes: window.clipBytes,
        clipFilename: 'incident_${className}_${window.seconds.toStringAsFixed(0)}s.wav',
      );
    }

    if (!mounted) return;
    final decision = result['decision'] as Map<String, dynamic>?;
    final instructions = decision != null && decision['rationale'] != null
        ? [decision['rationale'].toString()]
        : const ['Assess your immediate surroundings and follow local emergency guidance.'];
    final facilities = await _fetchNearbyFacilities(className, position);

    if (!mounted) return;
    setState(() => _alertOpen = true);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AlertScreen(
          title: 'Acoustic threat detected',
          threatClass: className,
          rawClass: rawClass,
          riskScore: riskScore,
          riskLevel: _riskLevel,
          p1Conf: _p1Confidence,
          p2Conf: _p2Confidence,
          instructions: instructions,
          nearbyFacilities: facilities,
          incident: incident,
          profile: session.modelProfile.value,
        ),
      ),
    );
    if (mounted) setState(() => _alertOpen = false);
  }

  Future<Position?> _currentPosition() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        return await Geolocator.getCurrentPosition(
          timeLimit: const Duration(seconds: 8),
        );
      }
    } catch (_) {
      // A location fix is best-effort; the alert must still go out without it.
    }
    return null;
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
    try {
      final usingFallbackLocation = position == null;
      final lat = position?.latitude ?? 17.3850;
      final lng = position?.longitude ?? 78.4867;
      final places = await _apiService.getNearbyPlaces(lat: lat, lng: lng, type: type);

      // A fallback location must say so on screen — showing "nearby" results
      // for a location that is not the user's is exactly the kind of
      // undisclosed fake data this app must not present.
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
    } catch (_) {
      return [
        {'name': 'Nearby lookup unavailable', 'address': 'Could not reach the location or places service.'}
      ];
    }
  }

  // ------------------------------------------------------------------
  // Session control
  // ------------------------------------------------------------------

  Future<void> _startMonitoring() async {
    final hasPermission = await _recorder.hasPermission();
    if (!mounted) return;
    if (!hasPermission) {
      setState(() => _monitorError = 'Microphone permission is required to monitor sound.');
      return;
    }
    setState(() {
      _isMonitoring = true;
      _monitorError = null;
      _stage = 'Listening';
    });
    widget.onMonitoringChanged(true);
    unawaited(_runMonitoringCycle());
    _monitorTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_runMonitoringCycle());
    });
  }

  Future<void> _stopMonitoring() async {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    setState(() {
      _isMonitoring = false;
      _stage = 'Idle';
      _amplitude = 0;
    });
    widget.onMonitoringChanged(false);
    try {
      await _recorder.stop();
    } catch (_) {
      // The recorder may already have released its session.
    }
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    _amplitudeSubscription?.cancel();
    // Leaving the tab while monitoring is active must not leave the dashboard
    // showing a stale "LISTENING" status for a recorder that no longer exists.
    if (_isMonitoring) {
      widget.onMonitoringChanged(false);
    }
    _recorder.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        FadeSlideIn(
          index: 0,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      '01 // SENSOR TELEMETRY',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                        color: AppColors.inkMuted,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'LIVE ACOUSTIC MONITOR',
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
              ValueListenableBuilder<String>(
                valueListenable: AppSession.instance.modelProfile,
                builder: (context, profile, _) => StatusPill(
                  label: profile == 'demo' ? 'DEMO ENGINE' : 'PROD ENGINE',
                  color: AppColors.ink,
                  background: profile == 'demo' ? AppColors.primary : AppColors.surfaceAlt,
                  icon: profile == 'demo' ? Icons.science_outlined : Icons.verified_outlined,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        FadeSlideIn(
          index: 0,
          child: Text(
            _isMonitoring
                ? 'STATE: ${_stage.toUpperCase()} // SAMPLING 16KHZ MONO STREAM'
                : 'STANDBY // INITIATE ENGINE TO COMMENCE 2-SECOND DETECTION WINDOWS',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: AppColors.inkMuted,
            ),
          ),
        ),
        const SizedBox(height: 16),
        FadeSlideIn(
          index: 1,
          child: LiveWaveform(
            amplitude: _amplitude,
            active: _isMonitoring,
            color: AppColors.forRiskLevel(_riskLevel),
            height: 156,
            overlayLabel: 'MIC STREAM · 16 kHz WAV',
          ),
        ),
        const SizedBox(height: 18),
        FadeSlideIn(
          index: 2,
          child: PressableScale(
            child: ElevatedButton.icon(
              onPressed: _isMonitoring ? _stopMonitoring : _startMonitoring,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isMonitoring ? AppColors.ink : AppColors.primary,
                foregroundColor: _isMonitoring ? AppColors.surface : AppColors.ink,
                side: const BorderSide(color: AppColors.line, width: 1.5),
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: Icon(
                _isMonitoring ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: 20,
              ),
              label: Text(
                _isMonitoring ? 'HALT TELEMETRY STREAM' : 'INITIALIZE TELEMETRY STREAM',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
        ),
        if (_monitorError != null) ...[
          const SizedBox(height: 14),
          AppCard(
            background: AppColors.primary,
            borderColor: AppColors.line,
            hasShadow: true,
            shadowOffset: 2,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 20, color: AppColors.ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'ERR // ${_monitorError!.toUpperCase()}',
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
        const SizedBox(height: 22),
        FadeSlideIn(
          index: 3,
          child: AppCard(
            hasShadow: true,
            shadowOffset: 3,
            child: Row(
              children: [
                RiskGauge(score: _riskScore, level: _riskLevel, size: 124),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CLASSIFIED SIGNATURE',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w900,
                          color: AppColors.inkMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _currentClass.replaceAll('_', ' ').toUpperCase(),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                      if (_rawClass != null && _rawClass != _currentClass) ...[
                        const SizedBox(height: 6),
                        StatusPill(
                          label: 'RAW // ${_rawClass!.toUpperCase()}',
                          color: AppColors.ink,
                          background: AppColors.surfaceAlt,
                        ),
                      ],
                      const SizedBox(height: 10),
                      StatusPill(
                        label: 'LEVEL // ${_riskLevel.replaceAll('_', ' ')}',
                        color: AppColors.forRiskLevel(_riskLevel),
                        background: AppColors.softForRiskLevel(_riskLevel),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const FadeSlideIn(index: 4, child: SectionLabel('02 // TWO-PASS VERIFICATION MATRIX')),
        FadeSlideIn(
          index: 4,
          child: AppCard(
            hasShadow: true,
            shadowOffset: 3,
            child: Column(
              children: [
                _buildConfidenceRow('PASS 1 · PRIMARY WINDOW (2S)', _p1Confidence, AppColors.primary),
                const SizedBox(height: 16),
                _buildConfidenceRow('PASS 2 · VERIFICATION WINDOW (5S)', _p2Confidence, AppColors.ink),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfidenceRow(String label, double confidence, Color color) {
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
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: AppColors.inkMuted,
              ),
            ),
            AnimatedCounter(
              value: confidence * 100,
              suffix: '%',
              decimals: 1,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 10,
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            border: Border.all(color: AppColors.line, width: 1),
          ),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: confidence.clamp(0.0, 1.0)),
            duration: AppDurations.slow,
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value,
              child: Container(
                color: color,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
