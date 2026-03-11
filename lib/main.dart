// =============================================================================
// UniSalento Orario — tutto in main.dart
// Nessun codegen, nessun file aggiuntivo.
//
// pubspec.yaml – dipendenze:
//   flutter_riverpod, http, shared_preferences, table_calendar,
//   icalendar_parser, intl, add_2_calendar
// =============================================================================

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:http/http.dart' as http;
import 'package:icalendar_parser/icalendar_parser.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

// =============================================================================
// ENTRY POINT
// =============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('it_IT', null);
  tz.initializeTimeZones();
  
  // Imposta fuso orario locale
  final locationName = DateTime.now().timeZoneName;
  try {
    tz.setLocalLocation(tz.getLocation(locationName));
  } catch (_) {
    tz.setLocalLocation(tz.getLocation('Europe/Rome'));
  }

  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [_sharedPrefsProvider.overrideWithValue(prefs)],
      child: const _App(),
    ),
  );
}

// =============================================================================
// MODELLI
// =============================================================================

class Corso {
  final String id;
  final String label;
  const Corso({required this.id, required this.label});
  factory Corso.fromAjax(Map<String, dynamic> j) => Corso(
    id: j['valore']?.toString() ?? j['id']?.toString() ?? '',
    label: j['label']?.toString() ?? j['nome']?.toString() ?? '',
  );
  Map<String, dynamic> toJson() => {'id': id, 'label': label};
  factory Corso.fromJson(Map<String, dynamic> j) =>
      Corso(id: j['id'], label: j['label']);
}

class AnnoCorso {
  final String id;
  final String label;
  const AnnoCorso({required this.id, required this.label});
  factory AnnoCorso.fromAjax(Map<String, dynamic> j) => AnnoCorso(
    id: j['valore']?.toString() ?? j['id']?.toString() ?? '',
    label: j['label']?.toString() ?? j['nome']?.toString() ?? '',
  );
  Map<String, dynamic> toJson() => {'id': id, 'label': label};
  factory AnnoCorso.fromJson(Map<String, dynamic> j) =>
      AnnoCorso(id: j['id'], label: j['label']);
}

class Curriculum {
  final String id;
  final String label;
  const Curriculum({required this.id, required this.label});
  factory Curriculum.fromAjax(Map<String, dynamic> j) => Curriculum(
    id: j['valore']?.toString() ?? j['id']?.toString() ?? '',
    label: j['label']?.toString() ?? j['nome']?.toString() ?? '',
  );
  Map<String, dynamic> toJson() => {'id': id, 'label': label};
  factory Curriculum.fromJson(Map<String, dynamic> j) =>
      Curriculum(id: j['id'], label: j['label']);
}

class LessonEvent {
  final String uid;
  final String title;
  final DateTime start;
  final DateTime end;
  final String? location;
  final String? professor;
  final String? description;
  const LessonEvent({
    required this.uid,
    required this.title,
    required this.start,
    required this.end,
    this.location,
    this.professor,
    this.description,
  });
  Map<String, dynamic> toJson() => {
    'uid': uid,
    'title': title,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'location': location,
    'professor': professor,
    'description': description,
  };
  factory LessonEvent.fromJson(Map<String, dynamic> j) => LessonEvent(
    uid: j['uid'],
    title: j['title'],
    start: DateTime.parse(j['start']),
    end: DateTime.parse(j['end']),
    location: j['location'],
    professor: j['professor'],
    description: j['description'],
  );
}

class UserPrefs {
  final Corso? corso;
  final AnnoCorso? anno;
  final Curriculum? curriculum;
  final bool setupDone;
  final bool notificationsEnabled;
  final int notificationAdvanceMinutes;

  const UserPrefs({
    this.corso,
    this.anno,
    this.curriculum,
    this.setupDone = false,
    this.notificationsEnabled = false,
    this.notificationAdvanceMinutes = 15,
  });

  UserPrefs copyWith({
    Corso? corso,
    AnnoCorso? anno,
    Curriculum? curriculum,
    bool? setupDone,
    bool? notificationsEnabled,
    int? notificationAdvanceMinutes,
  }) => UserPrefs(
    corso: corso ?? this.corso,
    anno: anno ?? this.anno,
    curriculum: curriculum ?? this.curriculum,
    setupDone: setupDone ?? this.setupDone,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    notificationAdvanceMinutes: notificationAdvanceMinutes ?? this.notificationAdvanceMinutes,
  );
}

// =============================================================================
// SERVIZIO HTTP — EasyAcademy/EasyCourse
// =============================================================================
//
//  Endpoint verificati tramite reverse engineering del bot Telegram funzionante:
//  • combo_call.php  → lista corsi, anni, curricula (un'unica chiamata)
//  • grid_call.php   → lezioni JSON settimanali
//  • export/ec_download_ical_grid.php → export iCal

class EasyAcademyService {
  static const _base = 'https://logistica.unisalento.it/PortaleStudenti';
  static const _combo = '$_base/combo_call.php';
  static const _grid = '$_base/grid_call.php';
  static const _icalExport = '$_base/export/ec_download_ical_grid.php';

  static final _aa = DateTime.now().month >= 9
      ? DateTime.now().year
      : DateTime.now().year - 1;

  final _client = http.Client();

  // Cache della risposta combo (contiene corsi + anni + insegnamenti)
  List<Map<String, dynamic>>? _comboCache;

  Map<String, String> get _h => {
    'accept': 'application/json, text/javascript, */*; q=0.01',
    'accept-language': 'it-IT,it;q=0.6',
    'cache-control': 'no-cache',
  };

  // ── Carica tutti i dati combo (corsi + anni) in un colpo ──────────────────
  Future<List<Map<String, dynamic>>> _fetchComboData() async {
    if (_comboCache != null) return _comboCache!;
    final r = await _client.post(
      Uri.parse(_combo),
      headers: _h,
      body: {'sw': 'ec_', 'aa': '$_aa', 'page': 'corsi', '_lang': 'it'},
    );
    final bodyStr = utf8.decode(r.bodyBytes);
    // Risposta: var elenco_corsi = [{"label":"2025/2026","valore":"2025","elenco":[...]}];  var elenco_scuole = [];
    final jsonStr = _extractJsonArray(bodyStr);
    final topLevel = jsonDecode(jsonStr) as List;
    // L'array ha un oggetto wrapper con chiave "elenco" contenente i corsi
    if (topLevel.isNotEmpty && topLevel[0] is Map) {
      final wrapper = topLevel[0] as Map<String, dynamic>;
      if (wrapper.containsKey('elenco')) {
        final list = (wrapper['elenco'] as List).cast<Map<String, dynamic>>();
        _comboCache = list;
        return list;
      }
    }
    // Fallback: usa direttamente il top level
    final list = topLevel.cast<Map<String, dynamic>>();
    _comboCache = list;
    return list;
  }

  /// Estrae il primo array JSON bilanciato dalla risposta combo_call.php.
  /// La risposta è: "var elenco_corsi = [...];  var elenco_scuole = [];"
  /// Usiamo il conteggio delle parentesi per trovare la chiusura corretta.
  String _extractJsonArray(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('[')) {
      // Trova la ] che chiude il primo array bilanciato
      return _findBalancedArray(trimmed, 0);
    }
    final start = trimmed.indexOf('[');
    if (start < 0) return '[]';
    return _findBalancedArray(trimmed, start);
  }

  String _findBalancedArray(String s, int start) {
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    for (int i = start; i < s.length; i++) {
      final c = s[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) {
          return s.substring(start, i + 1);
        }
      }
    }
    // Fallback se non troviamo la chiusura
    return s.substring(start);
  }

  // ── Corsi ─────────────────────────────────────────────────────────────────
  Future<List<Corso>> fetchCorsi() async {
    try {
      final data = await _fetchComboData();
      final corsi = <Corso>[];
      for (final c in data) {
        final code = c['valore']?.toString() ?? '';
        final label = c['label']?.toString() ?? '';
        if (code.isNotEmpty && label.isNotEmpty) {
          final tipo = c['tipo']?.toString() ?? '';
          final displayLabel = tipo.isNotEmpty ? '$label ($tipo)' : label;
          corsi.add(Corso(id: code, label: displayLabel));
        }
      }
      return corsi;
    } catch (e) {
      throw Exception('Errore nel recupero dei corsi: $e');
    }
  }

  // ── Anni ──────────────────────────────────────────────────────────────────
  Future<List<AnnoCorso>> fetchAnni(String corsoId) async {
    try {
      final data = await _fetchComboData();
      // Trova il corso nell'elenco combo
      final corsoData = data.firstWhere(
        (c) => c['valore']?.toString() == corsoId,
        orElse: () => <String, dynamic>{},
      );
      final elencoAnni = corsoData['elenco_anni'] as List? ?? [];
      final anni = <AnnoCorso>[];
      for (final a in elencoAnni) {
        final val = a['valore']?.toString() ?? '';
        final label =
            a['order_lbl']?.toString() ?? a['label']?.toString() ?? '';
        if (val.isNotEmpty) {
          anni.add(AnnoCorso(id: val, label: label));
        }
      }
      return anni;
    } catch (e) {
      throw Exception('Errore nel recupero degli anni: $e');
    }
  }

  // ── Curricula ─────────────────────────────────────────────────────────────
  Future<List<Curriculum>> fetchCurricula(String corsoId, String annoId) async {
    // I curricula sono già inclusi nella struttura degli anni
    // Per semplicità, restituiamo "Percorso comune" se non ci sono curricula distinti
    return [const Curriculum(id: '', label: 'Percorso comune')];
  }

  // ── Lezioni ───────────────────────────────────────────────────────────────
  Future<List<LessonEvent>> fetchLezioni({
    required String corsoId,
    required String annoId,
    String? curriculumId,
  }) async {
    // Prova prima JSON (più affidabile), poi iCal come fallback
    try {
      return await _jsonGrid(corsoId, annoId);
    } catch (e) {
      debugPrint('[JSON grid] $e → trying iCal');
    }
    try {
      return await _ical(corsoId, annoId);
    } catch (e) {
      debugPrint('[iCal] $e');
      rethrow;
    }
  }

  // Strategia A — JSON (grid_call.php) — stessi parametri del bot funzionante
  Future<List<LessonEvent>> _jsonGrid(String corsoId, String annoId) async {
    final date = DateFormat('dd-MM-yyyy').format(DateTime.now());
    final r = await _client.post(
      Uri.parse(_grid),
      headers: _h,
      body: {
        'include': 'corso',
        'anno': '$_aa',
        'corso': corsoId,
        'anno2[]': annoId, // formato "999|2"
        'date': date,
        'all_events': '1',
      },
    );
    final bodyStr = utf8.decode(r.bodyBytes);
    if (bodyStr.trim().isEmpty) {
      throw Exception('Risposta vuota da grid_call.php');
    }
    final data = jsonDecode(bodyStr) as Map<String, dynamic>;
    final celle = (data['celle'] ?? []) as List;
    return celle
        .cast<Map<String, dynamic>>()
        .map(_parseCella)
        .whereType<LessonEvent>()
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  LessonEvent? _parseCella(Map<String, dynamic> c) {
    try {
      final dataStr = c['data']?.toString() ?? '';
      final oraInizio = c['ora_inizio']?.toString() ?? '';
      final oraFine = c['ora_fine']?.toString() ?? '';
      final start = _parseDateTime(dataStr, oraInizio);
      final end = _parseDateTime(dataStr, oraFine);
      if (start == null || end == null) return null;
      return LessonEvent(
        uid: c['id']?.toString() ?? '${start.millisecondsSinceEpoch}',
        title:
            c['name_original']?.toString() ??
            c['nome_insegnamento']?.toString() ??
            'Lezione',
        start: start,
        end: end,
        location: c['aula']?.toString(),
        professor: c['docente']?.toString(),
        description: c['tipo']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  // Strategia B — iCal (export/ec_download_ical_grid.php)
  Future<List<LessonEvent>> _ical(String corsoId, String annoId) async {
    final date = DateFormat('dd-MM-yyyy').format(DateTime.now());
    final r = await _client.post(
      Uri.parse(_icalExport),
      headers: _h,
      body: {
        'include': 'corso',
        'anno': '$_aa',
        'corso': corsoId,
        'anno2[]': annoId,
        'date': date,
        'all_events': '1',
      },
    );
    final body = utf8.decode(r.bodyBytes);
    if (!body.contains('BEGIN:VCALENDAR')) {
      throw Exception('Risposta non è un file iCal');
    }
    final events = <LessonEvent>[];
    for (final comp in ICalendar.fromString(body).data) {
      if (comp['type'] != 'VEVENT') continue;
      final start = _icalDate(comp['dtstart']);
      final end = _icalDate(comp['dtend']);
      if (start == null || end == null) continue;
      final desc = comp['description']?.toString() ?? '';
      final prof = RegExp(
        r'(?:Docente|Prof\.?):?\s*([^\n\r]+)',
        caseSensitive: false,
      ).firstMatch(desc)?.group(1)?.trim();
      events.add(
        LessonEvent(
          uid: comp['uid']?.toString() ?? '${start.millisecondsSinceEpoch}',
          title: comp['summary']?.toString() ?? 'Lezione',
          start: start,
          end: end,
          location: comp['location']?.toString(),
          professor: prof,
          description: desc,
        ),
      );
    }
    return events..sort((a, b) => a.start.compareTo(b.start));
  }

  DateTime? _icalDate(dynamic v) {
    if (v == null) return null;
    try {
      if (v is DateTime) return v.toLocal();
      final s = v.toString();
      if (s.length >= 15) {
        return DateTime.parse(
          '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}'
          'T${s.substring(9, 11)}:${s.substring(11, 13)}:${s.substring(13, 15)}'
          '${s.endsWith('Z') ? 'Z' : ''}',
        ).toLocal();
      }
      return DateTime.parse(s).toLocal();
    } catch (_) {
      return null;
    }
  }

  DateTime? _parseDateTime(String date, String time) {
    try {
      final dp = date.contains('-') ? date.split('-') : date.split('/');
      final tp = time.split(':');
      if (dp.length < 3 || tp.length < 2) return null;
      int d, m, y;
      if (dp[0].length == 4) {
        y = int.parse(dp[0]);
        m = int.parse(dp[1]);
        d = int.parse(dp[2]);
      } else {
        d = int.parse(dp[0]);
        m = int.parse(dp[1]);
        y = int.parse(dp[2]);
      }
      return DateTime(y, m, d, int.parse(tp[0]), int.parse(tp[1]));
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// NOTIFICATION SERVICE
// =============================================================================

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);
    await _plugin.initialize(settings: initSettings);
  }

  Future<void> requestPermissions() async {
    if (Platform.isIOS) {
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    } else if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.requestNotificationsPermission();
      }
    }
  }

  Future<void> scheduleLessons(List<LessonEvent> lessons, int advanceMins) async {
    // Cancella tutte le vecchie notifiche
    await _plugin.cancelAll();

    const androidDetails = AndroidNotificationDetails(
      'lesson_channel',
      'Avvisi Lezioni',
      channelDescription: 'Notifiche prima dell\'inizio delle lezioni',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    int id = 0;
    final now = DateTime.now();

    for (final l in lessons) {
      final scheduleTime = l.start.subtract(Duration(minutes: advanceMins));
      if (scheduleTime.isAfter(now)) {
        final tzTime = tz.TZDateTime.from(scheduleTime, tz.local);
        
        final timeStr = DateFormat('HH:mm').format(l.start);
        final loc = l.location != null ? ' in ${l.location}' : '';

        await _plugin.zonedSchedule(
          id: id++,
          title: 'Lezione in arrivo: ${l.title}',
          body: 'Inizia alle $timeStr$loc',
          scheduledDate: tzTime,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    }
  }

  Future<void> showTestNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'lesson_channel',
      'Avvisi Lezioni',
      channelDescription: 'Notifiche prima dell\'inizio delle lezioni',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    
    await _plugin.show(
      id: 9999,
      title: 'Test Notifica OK ✅',
      body: 'Le notifiche di UniSalento Orario funzionano perfettamente!',
      notificationDetails: details,
    );
  }

  Future<void> cancelAll() => _plugin.cancelAll();
}

// =============================================================================
// PREFS SERVICE (SharedPreferences + cache lezioni)
// =============================================================================

class PrefsService {
  static const _kPrefs = 'u_prefs';
  static const _kCache = 'u_cache';
  static const _kTs = 'u_cache_ts';
  final SharedPreferences _sp;
  PrefsService(this._sp);

  UserPrefs load() {
    final raw = _sp.getString(_kPrefs);
    if (raw == null) return const UserPrefs();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return UserPrefs(
        corso: j['corso'] != null ? Corso.fromJson(j['corso']) : null,
        anno: j['anno'] != null ? AnnoCorso.fromJson(j['anno']) : null,
        curriculum: j['curriculum'] != null
            ? Curriculum.fromJson(j['curriculum'])
            : null,
        setupDone: j['setupDone'] == true,
        notificationsEnabled: j['notificationsEnabled'] == true,
        notificationAdvanceMinutes: j['notificationAdvanceMinutes'] as int? ?? 15,
      );
    } catch (_) {
      return const UserPrefs();
    }
  }

  Future<void> save(UserPrefs p) => _sp.setString(
    _kPrefs,
    jsonEncode({
      if (p.corso != null) 'corso': p.corso!.toJson(),
      if (p.anno != null) 'anno': p.anno!.toJson(),
      if (p.curriculum != null) 'curriculum': p.curriculum!.toJson(),
      'setupDone': p.setupDone,
      'notificationsEnabled': p.notificationsEnabled,
      'notificationAdvanceMinutes': p.notificationAdvanceMinutes,
    }),
  );

  Future<void> clear() async {
    await _sp.remove(_kPrefs);
    await clearCache();
  }

  Future<void> clearCache() async {
    await _sp.remove(_kCache);
    await _sp.remove(_kTs);
  }

  Future<void> cacheLezioni(List<LessonEvent> ev) async {
    await _sp.setString(
      _kCache,
      jsonEncode(ev.map((e) => e.toJson()).toList()),
    );
    await _sp.setString(_kTs, DateTime.now().toIso8601String());
  }

  List<LessonEvent>? cachedLezioni() {
    final raw = _sp.getString(_kCache);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(LessonEvent.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  bool get isStale {
    final ts = _sp.getString(_kTs);
    if (ts == null) return true;
    return DateTime.now().difference(DateTime.parse(ts)).inHours > 4;
  }
}

// =============================================================================
// PROVIDERS (Riverpod)
// =============================================================================

final _sharedPrefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError(),
);
final _prefsSvcProvider = Provider<PrefsService>(
  (r) => PrefsService(r.read(_sharedPrefsProvider)),
);
final _eaSvcProvider = Provider<EasyAcademyService>(
  (_) => EasyAcademyService(),
);
final _notificationSvcProvider = Provider<NotificationService>((ref) {
  final svc = NotificationService();
  svc.init();
  return svc;
});

// ── UserPrefs Notifier ────────────────────────────────────────────────────────
class _PrefsNotifier extends Notifier<UserPrefs> {
  @override
  UserPrefs build() => ref.read(_prefsSvcProvider).load();

  Future<void> setCorso(Corso c) async {
    state = UserPrefs(corso: c);
    await ref.read(_prefsSvcProvider).save(state);
    await ref.read(_prefsSvcProvider).clearCache();
  }

  Future<void> setAnno(AnnoCorso a) async {
    state = state.copyWith(anno: a, curriculum: null, setupDone: false);
    await ref.read(_prefsSvcProvider).save(state);
    await ref.read(_prefsSvcProvider).clearCache();
  }

  Future<void> setCurriculum(Curriculum c) async {
    state = state.copyWith(curriculum: c, setupDone: true);
    await ref.read(_prefsSvcProvider).save(state);
    await ref.read(_prefsSvcProvider).clearCache();
  }

  Future<void> setNotifications(bool enabled) async {
    if (enabled) {
      await ref.read(_notificationSvcProvider).requestPermissions();
    }
    state = state.copyWith(notificationsEnabled: enabled);
    await ref.read(_prefsSvcProvider).save(state);
  }

  Future<void> setNotificationAdvance(int minutes) async {
    state = state.copyWith(notificationAdvanceMinutes: minutes);
    await ref.read(_prefsSvcProvider).save(state);
  }

  Future<void> reset() async {
    state = const UserPrefs();
    await ref.read(_prefsSvcProvider).clear();
    await ref.read(_notificationSvcProvider).cancelAll();
  }
}

final _prefsProvider = NotifierProvider<_PrefsNotifier, UserPrefs>(
  _PrefsNotifier.new,
);

// ── Corsi / Anni / Curricula ──────────────────────────────────────────────────
final _corsiProvider = FutureProvider<List<Corso>>(
  (r) => r.read(_eaSvcProvider).fetchCorsi(),
);
final _anniProvider = FutureProvider.family<List<AnnoCorso>, String>(
  (r, id) => r.read(_eaSvcProvider).fetchAnni(id),
);
final _curriculaProvider =
    FutureProvider.family<List<Curriculum>, (String, String)>(
      (r, t) => r.read(_eaSvcProvider).fetchCurricula(t.$1, t.$2),
    );

// ── Lezioni ───────────────────────────────────────────────────────────────────
class _LezioniNotifier extends AsyncNotifier<List<LessonEvent>> {
  @override
  Future<List<LessonEvent>> build() async {
    final p = ref.watch(_prefsProvider);
    if (!p.setupDone || p.corso == null || p.anno == null) return [];
    return _load(p);
  }

  Future<List<LessonEvent>> _load(UserPrefs p) async {
    final svc = ref.read(_prefsSvcProvider);
    if (!svc.isStale) {
      final cached = svc.cachedLezioni();
      if (cached != null && cached.isNotEmpty) return cached;
    }
    try {
      final ev = await ref
          .read(_eaSvcProvider)
          .fetchLezioni(
            corsoId: p.corso!.id,
            annoId: p.anno!.id,
            curriculumId: p.curriculum?.id,
          );
      await svc.cacheLezioni(ev);
      return ev;
    } catch (_) {
      final cached = svc.cachedLezioni();
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _load(ref.read(_prefsProvider)));
  }
}

final _lezioniProvider =
    AsyncNotifierProvider<_LezioniNotifier, List<LessonEvent>>(
      _LezioniNotifier.new,
    );

final _selectedDayProvider = StateProvider<DateTime>((_) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
});

final _lezioniDelGiornoProvider = Provider<List<LessonEvent>>((ref) {
  final sel = ref.watch(_selectedDayProvider);
  return ref
      .watch(_lezioniProvider)
      .maybeWhen(
        data: (list) => list
            .where(
              (e) =>
                  e.start.year == sel.year &&
                  e.start.month == sel.month &&
                  e.start.day == sel.day,
            )
            .toList(),
        orElse: () => [],
      );
});

// =============================================================================
// APP
// =============================================================================

class _App extends ConsumerWidget {
  const _App();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(_prefsProvider);
    return MaterialApp(
      title: 'Orario UniSalento',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: p.setupDone ? const _OrarioScreen() : const _SetupScreen(),
    );
  }

  // Palette UniSalento — oro #f0cc00 + marrone caldo
  static const _uniGold = Color(0xFFF0CC00);
  static const _uniDark = Color(0xFF3D2B1F);

  ThemeData _theme(Brightness b) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: _uniGold, brightness: b),
    appBarTheme: AppBarTheme(
      backgroundColor: b == Brightness.light ? _uniDark : null,
      foregroundColor: b == Brightness.light ? Colors.white : null,
      elevation: 0,
    ),
  );
}

// =============================================================================
// SETUP SCREEN
// =============================================================================

class _SetupScreen extends ConsumerStatefulWidget {
  final bool canGoBack;
  const _SetupScreen({this.canGoBack = false});
  @override
  ConsumerState<_SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<_SetupScreen> {
  final _ctrl = PageController();
  int _step = 0;

  void _next() {
    _ctrl.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOut,
    );
    setState(() => _step++);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canGoBack = widget.canGoBack;

    void goBack() {
      if (_step > 0) {
        _ctrl.previousPage(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOut,
        );
        setState(() => _step--);
      } else if (canGoBack) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const _OrarioScreen()),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        leading: (_step > 0 || canGoBack)
            ? IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: goBack,
              )
            : null,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFF0CC00).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('🎓', style: TextStyle(fontSize: 20)),
            ),
            const SizedBox(width: 10),
            const Text('Configura il corso'),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOut,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (_step + 1) / 3,
                backgroundColor: cs.surfaceContainerHighest,
                color: const Color(0xFFF0CC00),
                minHeight: 5,
              ),
            ),
          ),
        ),
      ),
      body: PopScope(
        canPop: _step == 0 && !canGoBack,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          goBack();
        },
        child: PageView(
          controller: _ctrl,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _StepPage(
              0,
              'Corso di Laurea',
              'Scegli il tuo corso di studi',
              Icons.school_rounded,
              _CorsoStep(onDone: _next),
            ),
            _StepPage(
              1,
              'Anno di corso',
              'Seleziona l\'anno che frequenti',
              Icons.calendar_month_rounded,
              _AnnoStep(onDone: _next),
            ),
            _StepPage(
              2,
              'Curriculum',
              'Scegli il percorso formativo',
              Icons.route_rounded,
              _CurriculumStep(
                onDone: () {
                  if (!context.mounted) return;
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const _OrarioScreen()),
                    (route) => false,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepPage extends StatelessWidget {
  final int idx;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
  const _StepPage(this.idx, this.title, this.subtitle, this.icon, this.child);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  cs.primaryContainer,
                  cs.primaryContainer.withValues(alpha: 0.5),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withValues(alpha: 0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: cs.onPrimaryContainer, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Passo ${idx + 1} di 3',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onPrimaryContainer.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: cs.onPrimaryContainer,
                            ),
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onPrimaryContainer.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// ── Lista con ricerca ─────────────────────────────────────────────────────────

class _PickList<T> extends StatefulWidget {
  final List<T> items;
  final String Function(T) label;
  final void Function(T) onTap;
  const _PickList({
    required this.items,
    required this.label,
    required this.onTap,
  });
  @override
  State<_PickList<T>> createState() => _PickListState<T>();
}

class _PickListState<T> extends State<_PickList<T>> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filtered = widget.items
        .where((i) => widget.label(i).toLowerCase().contains(_q.toLowerCase()))
        .toList();
    return Column(
      children: [
        TextField(
          decoration: InputDecoration(
            hintText: 'Cerca...',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                label: Text(
                  '${filtered.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                backgroundColor: cs.primaryContainer,
                visualDensity: VisualDensity.compact,
                side: BorderSide.none,
              ),
            ),
            suffixIconConstraints: const BoxConstraints(maxHeight: 36),
            filled: true,
            fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Material(
                color: cs.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => widget.onTap(filtered[i]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.label(filtered[i]),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 14,
                          color: cs.outline,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Step widgets ──────────────────────────────────────────────────────────────

class _CorsoStep extends ConsumerWidget {
  final VoidCallback onDone;
  const _CorsoStep({required this.onDone});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_corsiProvider)
      .when(
        data: (list) => _PickList<Corso>(
          items: list,
          label: (c) => c.label,
          onTap: (c) async {
            await ref.read(_prefsProvider.notifier).setCorso(c);
            onDone();
          },
        ),
        loading: () => const _Loading(),
        error: (e, _) => _Err(e.toString()),
      );
}

class _AnnoStep extends ConsumerWidget {
  final VoidCallback onDone;
  const _AnnoStep({required this.onDone});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(_prefsProvider).corso?.id ?? '';
    return ref
        .watch(_anniProvider(id))
        .when(
          data: (list) => _PickList<AnnoCorso>(
            items: list,
            label: (a) => a.label,
            onTap: (a) async {
              await ref.read(_prefsProvider.notifier).setAnno(a);
              onDone();
            },
          ),
          loading: () => const _Loading(),
          error: (e, _) => _Err(e.toString()),
        );
  }
}

class _CurriculumStep extends ConsumerWidget {
  final VoidCallback onDone;
  const _CurriculumStep({required this.onDone});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(_prefsProvider);
    final key = (p.corso?.id ?? '', p.anno?.id ?? '');
    return ref
        .watch(_curriculaProvider(key))
        .when(
          data: (list) {
            final items = list.isEmpty
                ? const [Curriculum(id: '', label: 'Percorso Unico')]
                : list;

            return _PickList<Curriculum>(
              items: items,
              label: (c) => c.label,
              onTap: (c) async {
                await ref.read(_prefsProvider.notifier).setCurriculum(c);
                onDone();
              },
            );
          },
          loading: () => const _Loading(),
          error: (e, _) => _Err(e.toString()),
        );
  }
}

// =============================================================================
// ORARIO SCREEN
// =============================================================================

class _OrarioScreen extends ConsumerStatefulWidget {
  const _OrarioScreen();
  @override
  ConsumerState<_OrarioScreen> createState() => _OrarioScreenState();
}

class _OrarioScreenState extends ConsumerState<_OrarioScreen> {
  CalendarFormat _fmt = CalendarFormat.week;
  late DateTime _focused;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _focused = DateTime(n.year, n.month, n.day);
  }

  void _goToToday() {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    ref.read(_selectedDayProvider.notifier).state = today;
    setState(() => _focused = today);
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(_prefsProvider);
    final lezioniAsync = ref.watch(_lezioniProvider);
    final today = ref.watch(_selectedDayProvider);
    final todayLez = ref.watch(_lezioniDelGiornoProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Orario Lezioni'),
            if (p.corso != null)
              Text(
                [
                  p.corso!.label,
                  if (p.anno != null) ' · ${p.anno!.label}',
                ].join(),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.today_rounded),
            tooltip: 'Oggi',
            onPressed: _goToToday,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Aggiorna',
            onPressed: () => ref.read(_lezioniProvider.notifier).refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Impostazioni',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(_lezioniProvider.notifier).refresh(),
        color: const Color(0xFFF0CC00),
        child: Column(
          children: [
            lezioniAsync.when(
              data: (ev) => _calendar(ev, today),
              loading: () => _calendar([], today),
              error: (err, stack) => _calendar([], today),
            ),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
            _DayHeader(day: today),
            Expanded(
              child: lezioniAsync.when(
                data: (_) => _list(todayLez),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => _error(e.toString()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _calendar(List<LessonEvent> events, DateTime selected) {
    final withLez = <DateTime>{
      for (final e in events)
        DateTime(e.start.year, e.start.month, e.start.day),
    };
    final cs = Theme.of(context).colorScheme;
    return TableCalendar<LessonEvent>(
      locale: 'it_IT',
      firstDay: DateTime(2024),
      lastDay: DateTime(2027, 12, 31),
      focusedDay: _focused,
      selectedDayPredicate: (d) => isSameDay(d, selected),
      calendarFormat: _fmt,
      startingDayOfWeek: StartingDayOfWeek.monday,
      headerStyle: HeaderStyle(
        formatButtonShowsNext: false,
        titleCentered: true,
        titleTextStyle: Theme.of(
          context,
        ).textTheme.titleSmall!.copyWith(fontWeight: FontWeight.w600),
        formatButtonDecoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        formatButtonTextStyle: TextStyle(fontSize: 12, color: cs.onSurface),
        leftChevronIcon: Icon(Icons.chevron_left_rounded, color: cs.primary),
        rightChevronIcon: Icon(Icons.chevron_right_rounded, color: cs.primary),
      ),
      calendarStyle: CalendarStyle(
        todayDecoration: BoxDecoration(
          color: const Color(0xFFF0CC00).withValues(alpha: 0.3),
          shape: BoxShape.circle,
        ),
        todayTextStyle: TextStyle(
          fontWeight: FontWeight.bold,
          color: cs.onSurface,
        ),
        selectedDecoration: const BoxDecoration(
          color: Color(0xFF3D2B1F),
          shape: BoxShape.circle,
        ),
        selectedTextStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        markerDecoration: const BoxDecoration(
          color: Color(0xFFF0CC00),
          shape: BoxShape.circle,
        ),
        markerSize: 6,
        markersMaxCount: 1,
      ),
      eventLoader: (d) =>
          withLez.contains(DateTime(d.year, d.month, d.day)) &&
              events.isNotEmpty
          ? [events.first]
          : [],
      onDaySelected: (sel, foc) {
        ref.read(_selectedDayProvider.notifier).state = DateTime(
          sel.year,
          sel.month,
          sel.day,
        );
        setState(() => _focused = foc);
      },
      onFormatChanged: (f) => setState(() => _fmt = f),
      onPageChanged: (f) => setState(() => _focused = f),
    );
  }

  Widget _list(List<LessonEvent> lezioni) {
    if (lezioni.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.beach_access_rounded,
                size: 48,
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Nessuna lezione',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Niente da fare oggi, goditi la giornata! 🎉',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.outline.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: lezioni.length,
      itemBuilder: (_, i) => _LessonCard(event: lezioni[i]),
    );
  }

  Widget _error(String msg) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.errorContainer.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Errore nel caricamento',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            msg,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => ref.read(_lezioniProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Riprova'),
          ),
        ],
      ),
    ),
  );
}

// =============================================================================
// LESSON CARD
// =============================================================================

class _LessonCard extends StatelessWidget {
  final LessonEvent event;
  const _LessonCard({required this.event});

  static final _tf = DateFormat('HH:mm');

  Color _color(ColorScheme cs) {
    final palette = [
      cs.primary,
      cs.secondary,
      cs.tertiary,
      const Color(0xFFD4A017), // oro scuro
      const Color(0xFF1B7A6E), // verde teal
      const Color(0xFFC25B28), // terracotta
      const Color(0xFF7B2D8E), // viola caldo
    ];
    return palette[event.title.codeUnits.fold(0, (p, c) => p + c) %
        palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final txt = Theme.of(context).textTheme;
    final dur = event.end.difference(event.start);
    final dl = dur.inMinutes >= 60
        ? '${dur.inMinutes ~/ 60}h${dur.inMinutes % 60 > 0 ? ' ${dur.inMinutes % 60}min' : ''}'
        : '${dur.inMinutes}min';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _detail(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Column(
                  children: [
                    Text(
                      _tf.format(event.start),
                      style: txt.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _tf.format(event.end),
                      style: txt.bodySmall?.copyWith(color: cs.outline),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        dl,
                        style: txt.labelSmall?.copyWith(
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 3,
                height: 62,
                decoration: BoxDecoration(
                  color: _color(cs),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: txt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (event.professor != null) ...[
                      const SizedBox(height: 3),
                      _Row(Icons.person_outline, event.professor!),
                    ],
                    if (event.location != null) ...[
                      const SizedBox(height: 2),
                      _Row(Icons.room_outlined, event.location!),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _detail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final isEsercitazione = event.title.toLowerCase().contains(
          'esercitazio',
        );

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        event.title,
                        style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isEsercitazione
                            ? cs.tertiaryContainer
                            : cs.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        isEsercitazione ? 'Esercitazione' : 'Lezione',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isEsercitazione
                              ? cs.onTertiaryContainer
                              : cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Column(
                    children: [
                      _Row(
                        Icons.calendar_today_rounded,
                        DateFormat(
                          'EEEE d MMMM yyyy',
                          'it_IT',
                        ).format(event.start),
                      ),
                      const SizedBox(height: 12),
                      _Row(
                        Icons.access_time_rounded,
                        '${_tf.format(event.start)} – ${_tf.format(event.end)}',
                      ),
                      if (event.professor != null) ...[
                        const SizedBox(height: 12),
                        _Row(Icons.person_rounded, event.professor!),
                      ],
                      if (event.location != null) ...[
                        const SizedBox(height: 12),
                        _Row(Icons.room_rounded, event.location!),
                      ],
                    ],
                  ),
                ),
                if (event.description?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Note agguintive',
                    style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    event.description!,
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],


              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// WIDGET HELPERS
// =============================================================================

class _Row extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Row(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(icon, size: 15, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

class _DayHeader extends StatelessWidget {
  final DateTime day;
  const _DayHeader({required this.day});
  @override
  Widget build(BuildContext context) {
    final isToday = isSameDay(day, DateTime.now());
    final label = DateFormat('EEEE d MMMM', 'it_IT').format(day);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(
        isToday ? 'Oggi – $label' : label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: isToday ? cs.primary : cs.onSurface,
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 14),
        Text('Caricamento...'),
      ],
    ),
  );
}

class _Err extends StatelessWidget {
  final String msg;
  const _Err(this.msg);
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.wifi_off_rounded,
            size: 56,
            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 14),
          const Text('Impossibile caricare i dati'),
          const SizedBox(height: 6),
          Text(
            msg,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

// =============================================================================
// SETTINGS SCREEN
// =============================================================================

class _SettingsScreen extends ConsumerStatefulWidget {
  const _SettingsScreen();

  @override
  ConsumerState<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<_SettingsScreen> {
  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.info_outline_rounded, size: 48),
        title: const Text('Informazioni App'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Questa non è un\'applicazione ufficiale dell\'Università del Salento e non è in alcun modo collegata allo sviluppo o all\'amministrazione dell\'Ateneo.',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            const Text(
              'Tutti i dati visualizzati sono reperiti pubblicamente dal sito ufficiale "Logistica UniSalento".',
            ),
            const SizedBox(height: 24),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'vibecoded by JPaladins',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'v0.1a',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Chiudi'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(_prefsProvider);
    
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Notifiche', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
          ),
          SwitchListTile(
            title: const Text('Abilita avvisi per le lezioni'),
            subtitle: const Text('Ricevi una notifica prima dell\'inizio di ogni lezione'),
            value: prefs.notificationsEnabled,
            onChanged: (val) {
              ref.read(_prefsProvider.notifier).setNotifications(val);
            },
          ),
          if (prefs.notificationsEnabled)
            ListTile(
              title: const Text('Anticipo notifica'),
              subtitle: const Text('Minuti di preavviso'),
              trailing: DropdownButton<int>(
                value: prefs.notificationAdvanceMinutes,
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15 minuti')),
                  DropdownMenuItem(value: 30, child: Text('30 minuti')),
                  DropdownMenuItem(value: 60, child: Text('1 ora')),
                ],
                onChanged: (val) {
                  if (val != null) {
                    ref.read(_prefsProvider.notifier).setNotificationAdvance(val);
                  }
                },
              ),
            ),
          if (prefs.notificationsEnabled)
            ListTile(
              title: const Text('Test Notifica'),
              subtitle: const Text('Invia una notifica di prova ora'),
              trailing: ElevatedButton(
                onPressed: () {
                  ref.read(_notificationSvcProvider).showTestNotification();
                },
                child: const Text('Test'),
              ),
            ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Corso di Studio', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded),
            title: const Text('Cambia corso'),
            subtitle: const Text('Scegli un altro dipartimento, corso o anno'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const _SetupScreen(canGoBack: true),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('Informazioni App'),
            onTap: _showInfoDialog,
          ),
        ],
      ),
    );
  }
}
