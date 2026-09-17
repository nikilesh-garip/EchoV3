import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animations.dart';

/// Emergency contacts and how each one is reached.
///
/// A contact row is now a routing rule, not just a phone number: escalation
/// order, the Telegram chat that receives the clip and location, and a
/// per-channel opt-out. The rehearsal button at the top exists because setup
/// that is only ever exercised during a real emergency is setup that does not
/// work.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final ApiService _api = ApiService();

  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _notice;
  List<Map<String, dynamic>> _contacts = const [];
  Map<String, dynamic>? _readiness;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final userId = AppSession.instance.userId;
    final results = await Future.wait([
      _api.getContacts(userId),
      _api.escalationReadiness(userId),
    ]);
    if (!mounted) return;
    final contacts = results[0] as List<Map<String, dynamic>>?;
    setState(() {
      _loading = false;
      _readiness = results[1] as Map<String, dynamic>?;
      if (contacts == null) {
        _error = 'Could not reach the backend at ${AppSession.apiBaseUrl}.';
      } else {
        _contacts = contacts;
      }
    });
  }

  Future<void> _delete(int contactId) async {
    final ok = await _api.deleteContact(contactId, userId: AppSession.instance.userId);
    if (!mounted) return;
    if (ok) {
      await _load();
    } else {
      setState(() => _error = 'Could not delete the contact.');
    }
  }

  Future<void> _toggleChannel(Map<String, dynamic> contact, String field, bool value) async {
    final updated = await _api.updateContact(
      contactId: contact['id'] as int,
      userId: AppSession.instance.userId,
      fields: {field: value},
    );
    if (!mounted) return;
    if (updated == null) {
      setState(() => _error = 'Could not update that contact.');
    } else {
      await _load();
    }
  }

  Future<void> _runTest() async {
    setState(() {
      _busy = true;
      _notice = null;
      _error = null;
    });
    final result = await _api.sendEscalationTest(
      userId: AppSession.instance.userId,
      userLabel: AppSession.instance.displayName,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == null) {
      setState(() => _error = 'Test failed. Add a contact first and make sure the backend is running.');
      return;
    }
    final attempts = List<Map<String, dynamic>>.from(result['attempts'] as Iterable? ?? const []);
    final sent = attempts.where((a) => a['status'] == 'sent').length;
    final simulated = attempts.where((a) => a['status'] == 'simulated').length;
    final failed = attempts.where((a) => a['status'] == 'failed').length;
    setState(() => _notice =
        'Rehearsal complete — $sent delivered, $simulated simulated, $failed failed.');
    if (mounted) _showAttempts(attempts);
  }

  void _showAttempts(List<Map<String, dynamic>> attempts) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadii.control)),
        side: const BorderSide(color: AppColors.line, width: 1.5),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'REHEARSAL TELEMETRY DISPATCH',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Channel-level verification log. Simulated entries reflect pending SIP/Bot backend bindings.',
              style: TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.5),
            ),
            const SizedBox(height: 16),
            ...attempts.map(
              (attempt) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: attempt['status'] == 'sent'
                            ? AppColors.primary
                            : AppColors.surfaceAlt,
                        border: Border.all(color: AppColors.line, width: 1),
                      ),
                      child: Icon(
                        attempt['channel'] == 'telegram'
                            ? Icons.send_outlined
                            : Icons.phone_in_talk_outlined,
                        size: 15,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${(attempt['contact_name'] ?? 'Contact').toString().toUpperCase()} // ${attempt['status'].toString().toUpperCase()}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.3),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            attempt['detail']?.toString() ?? '',
                            style: const TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor({Map<String, dynamic>? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ContactEditor(api: _api, existing: existing),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _readiness?['ready'] == true;
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          color: AppColors.ink,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
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
                            '03 // RECIPIENTS & ROUTING',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.5,
                              color: AppColors.inkMuted,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'EMERGENCY DISPATCH',
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
                    StatusPill(
                      label: ready ? 'CHAIN READY' : 'CONFIG REQUIRED',
                      color: AppColors.ink,
                      background: ready ? AppColors.primary : AppColors.surfaceAlt,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const FadeSlideIn(
                index: 0,
                child: Text(
                  'Verified contacts queued for automated speech relay and Telegram telemetry dispatch upon alarm trip.',
                  style: TextStyle(fontSize: 12, color: AppColors.inkMuted, height: 1.5),
                ),
              ),
              const SizedBox(height: 16),
              FadeSlideIn(
                index: 1,
                child: AppCard(
                  hasShadow: true,
                  shadowOffset: 3,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'ESCALATION CHAIN REHEARSAL',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Executes end-to-end dry-run of Twilio voice dispatch and Telegram payload delivery across all configured recipients.',
                        style: TextStyle(fontSize: 11, color: AppColors.inkMuted, height: 1.5),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.line, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _busy || _contacts.isEmpty ? null : _runTest,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink),
                              )
                            : const Icon(Icons.wifi_tethering, size: 18, color: AppColors.ink),
                        label: Text(
                          _busy ? 'EXECUTING REHEARSAL…' : 'DISPATCH TEST SIGNAL',
                          style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5, color: AppColors.ink),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_notice != null) ...[
                const SizedBox(height: 12),
                _banner(_notice!, AppColors.primary, AppColors.ink, Icons.check_circle_outline),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                _banner(_error!, AppColors.surfaceAlt, AppColors.vermilion, Icons.error_outline),
              ],
              const SizedBox(height: 24),
              const SectionLabel('04 // RECIPIENT ROSTER'),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator(color: AppColors.ink)),
                )
              else if (_contacts.isEmpty)
                AppCard(
                  hasShadow: true,
                  shadowOffset: 2,
                  child: const Text(
                    'ZERO CONTACTS IN PROTOCOL. REGISTER RECIPIENTS BELOW TO ENABLE DISPATCH.',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: AppColors.inkMuted, height: 1.5),
                  ),
                )
              else
                ..._contacts.asMap().entries.map(
                      (entry) => FadeSlideIn(
                        index: entry.key + 2,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildContactCard(entry.value, entry.key),
                        ),
                      ),
                    ),
            ],
          ),
        ),
        Positioned(
          right: 20,
          bottom: 20,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.control),
              boxShadow: neoShadow(offset: 3),
            ),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.ink,
                side: const BorderSide(color: AppColors.line, width: 1.5),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.control)),
              ),
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.person_add_alt, size: 18, color: AppColors.ink),
              label: const Text(
                'NEW RECIPIENT',
                style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _banner(String text, Color background, Color color, IconData icon) {
    return AppCard(
      background: background,
      borderColor: AppColors.line,
      hasShadow: true,
      shadowOffset: 2,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.3, color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactCard(Map<String, dynamic> contact, int index) {
    final hasTelegram = (contact['telegram_chat_id']?.toString() ?? '').isNotEmpty;
    final notifyCall = contact['notify_call'] == true || contact['notify_call'] == 1;
    final notifyTelegram = contact['notify_telegram'] == true || contact['notify_telegram'] == 1;

    return AppCard(
      hasShadow: true,
      shadowOffset: 3,
      onTap: () => _openEditor(existing: contact),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  border: Border.all(color: AppColors.line, width: 1.2),
                ),
                child: Text(
                  '0${index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.ink, fontSize: 13),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (contact['name']?.toString() ?? 'Contact').toUpperCase(),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 0.3),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${contact['relation']?.toString().isNotEmpty == true ? '${contact['relation']?.toString().toUpperCase()} // ' : ''}'
                      '${contact['phone'] ?? ''}',
                      style: const TextStyle(fontSize: 11, color: AppColors.inkMuted, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.ink, size: 20),
                onPressed: () => _delete(contact['id'] as int),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: AppColors.lineSubtle),
          const SizedBox(height: 6),
          SwitchListTile(
            activeThumbColor: AppColors.primary,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('VOICE CALL DISPATCH', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
            value: notifyCall,
            onChanged: (value) => _toggleChannel(contact, 'notify_call', value),
          ),
          SwitchListTile(
            activeThumbColor: AppColors.primary,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('TELEGRAM CLIP + COORDINATES', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
            subtitle: hasTelegram
                ? Text(
                    'TELEGRAM CHAT // ${contact['telegram_chat_id']}',
                    style: const TextStyle(fontSize: 11, color: AppColors.inkMuted, fontWeight: FontWeight.w600),
                  )
                : const Text(
                    'CHAT UNLINKED · TAP CARD TO CONFIGURE',
                    style: TextStyle(fontSize: 10, color: AppColors.vermilion, fontWeight: FontWeight.w800),
                  ),
            value: notifyTelegram,
            onChanged: (value) => _toggleChannel(contact, 'notify_telegram', value),
          ),
        ],
      ),
    );
  }
}

/// Add / edit sheet, including the Telegram chat picker.
class _ContactEditor extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? existing;

  const _ContactEditor({required this.api, this.existing});

  @override
  State<_ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<_ContactEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?['name']?.toString() ?? '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.existing?['phone']?.toString() ?? '');
  late final TextEditingController _relation =
      TextEditingController(text: widget.existing?['relation']?.toString() ?? '');
  late final TextEditingController _chatId =
      TextEditingController(text: widget.existing?['telegram_chat_id']?.toString() ?? '');
  late int _priority = (widget.existing?['priority'] as num?)?.toInt() ?? 1;

  bool _saving = false;
  bool _loadingChats = false;
  String? _error;
  List<Map<String, dynamic>> _chats = const [];
  bool _telegramConfigured = true;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _relation.dispose();
    _chatId.dispose();
    super.dispose();
  }

  Future<void> _loadChats() async {
    setState(() => _loadingChats = true);
    final response = await widget.api.telegramChats();
    if (!mounted) return;
    setState(() {
      _loadingChats = false;
      _telegramConfigured = response?['configured'] == true;
      _chats = List<Map<String, dynamic>>.from(response?['chats'] as Iterable? ?? const []);
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final userId = AppSession.instance.userId;
    final existingId = widget.existing?['id'] as int?;

    final result = existingId == null
        ? await widget.api.addContact(
            userId: userId,
            name: _name.text.trim(),
            phone: _phone.text.trim(),
            relation: _relation.text.trim(),
            telegramChatId: _chatId.text.trim().isEmpty ? null : _chatId.text.trim(),
            priority: _priority,
          )
        : await widget.api.updateContact(
            contactId: existingId,
            userId: userId,
            fields: {
              'name': _name.text.trim(),
              'phone': _phone.text.trim(),
              'relation': _relation.text.trim(),
              'telegram_chat_id': _chatId.text.trim(),
              'priority': _priority,
            },
          );

    if (!mounted) return;
    setState(() => _saving = false);
    if (result == null) {
      setState(() => _error = 'Could not save the contact. Is the backend running?');
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: const Border(
            top: BorderSide(color: AppColors.line, width: 2),
          ),
          boxShadow: neoShadow(offset: 4),
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    color: AppColors.line,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.existing == null ? 'NEW RECIPIENT // PROTOCOL' : 'EDIT RECIPIENT // PROTOCOL',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'FULL NAME'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'PHONE NUMBER',
                    helperText: 'E.164 notation (+91...) required for automated SIP relay',
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Phone is required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _relation,
                  decoration: const InputDecoration(labelText: 'RELATIONSHIP TAG (PARENT, SECURITY, PEER)'),
                ),
                const SizedBox(height: 16),
                const SectionLabel('05 // DISPATCH PRIORITY INDEX'),
                Row(
                  children: List.generate(4, (index) {
                    final value = index + 1;
                    final selected = _priority == value;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('0$value'),
                        selected: selected,
                        selectedColor: AppColors.primary,
                        backgroundColor: AppColors.surfaceAlt,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.control),
                          side: BorderSide(
                            color: selected ? AppColors.line : AppColors.lineSubtle,
                            width: selected ? 1.5 : 1,
                          ),
                        ),
                        labelStyle: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                          color: selected ? AppColors.ink : AppColors.inkMuted,
                        ),
                        onSelected: (_) => setState(() => _priority = value),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 18),
                const SectionLabel('06 // TELEGRAM GPS DISPATCH BINDING'),
                TextFormField(
                  controller: _chatId,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'TELEGRAM CHAT ID',
                    helperText: '5s evidence clip, GPS coordinate pin, and threat class stream here',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.line, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _loadingChats ? null : _loadChats,
                  icon: _loadingChats
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink))
                      : const Icon(Icons.search, size: 18, color: AppColors.ink),
                  label: const Text(
                    'POLL INCOMING BOT CHAT IDENTIFIERS',
                    style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5, color: AppColors.ink),
                  ),
                ),
                if (!_telegramConfigured)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'STATUS: TELEGRAM_BOT_TOKEN unconfigured in backend environment. Broadcasts simulated.',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.vermilion, height: 1.5),
                    ),
                  ),
                ..._chats.map(
                  (chat) => Container(
                    margin: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceAlt,
                      border: Border.all(color: AppColors.lineSubtle, width: 1),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.chat_bubble_outline, size: 18, color: AppColors.ink),
                      title: Text(
                        (chat['name']?.toString() ?? '').toUpperCase(),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        'ID // ${chat['chat_id']}',
                        style: const TextStyle(fontSize: 11, color: AppColors.inkMuted),
                      ),
                      trailing: const Icon(Icons.add_circle_outline, size: 18, color: AppColors.ink),
                      onTap: () => setState(() => _chatId.text = chat['chat_id']?.toString() ?? ''),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.vermilion)),
                ],
                const SizedBox(height: 20),
                PressableScale(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.ink,
                      side: const BorderSide(color: AppColors.line, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _saving ? null : _save,
                    child: Text(
                      _saving ? 'COMMITTING TO DISPATCH...' : 'REGISTER CONTACT ENTRY',
                      style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
