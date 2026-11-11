import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() => runApp(const TVMApp());

enum MediaKind { movie, series, live }

class MediaItem {
  final String title, poster, category, id, extension, description;
  final MediaKind kind;
  final double rating;
  final int duration;
  final String? streamUrl;
  const MediaItem({
    required this.title,
    required this.poster,
    required this.category,
    required this.id,
    required this.extension,
    required this.description,
    required this.kind,
    required this.rating,
    required this.duration,
    this.streamUrl,
  });

  Map<String, dynamic> toJson() => {
    't': title,
    'p': poster,
    'c': category,
    'i': id,
    'e': extension,
    'd': description,
    'k': kind.name,
    'r': rating,
    'u': duration,
    's': streamUrl,
  };

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
    title: (j['t'] ?? '').toString(),
    poster: (j['p'] ?? '').toString(),
    category: (j['c'] ?? '').toString(),
    id: (j['i'] ?? '').toString(),
    extension: (j['e'] ?? '').toString(),
    description: (j['d'] ?? '').toString(),
    kind: MediaKind.values.firstWhere(
      (k) => k.name == j['k'],
      orElse: () => MediaKind.movie,
    ),
    rating: (j['r'] as num?)?.toDouble() ?? 0,
    duration: (j['u'] as num?)?.toInt() ?? 0,
    streamUrl: j['s'] as String?,
  );
}

// تُنفَّذ في Isolate منفصل حتى لا تتجمد الواجهة مع القوائم الكبيرة.
String _encodeItems(List<MediaItem> items) =>
    jsonEncode(items.map((e) => e.toJson()).toList());
List<MediaItem> _decodeItems(String raw) => (jsonDecode(raw) as List)
    .whereType<Map>()
    .map((m) => MediaItem.fromJson(Map<String, dynamic>.from(m)))
    .toList();

/// رفض صريح من الخادم لاسم المستخدم/كلمة المرور (وليس فشل شبكة).
class AuthFailed implements Exception {
  final String message;
  const AuthFailed(this.message);
  @override
  String toString() => message;
}

class Credentials {
  final String user, pass;
  const Credentials(this.user, this.pass);
}

/// تخزين بيانات الدخول والمحتوى على الجهاز حتى لا يُطلب الدخول كل مرة.
class Store {
  final _secure = const FlutterSecureStorage();
  Directory? _dir;

  Future<File> _file(String name) async {
    _dir ??= await getApplicationSupportDirectory();
    return File('${_dir!.path}/$name');
  }

  Future<Credentials?> readCreds() async {
    try {
      final u = await _secure.read(key: 'tvm_user');
      final p = await _secure.read(key: 'tvm_pass');
      if (u != null && u.isNotEmpty && p != null && p.isNotEmpty) {
        return Credentials(u, p);
      }
    } catch (_) {}
    // بعض أجهزة الشاشات لا يعمل فيها التخزين الآمن؛ نستخدم ملفاً داخل مجلد التطبيق الخاص.
    try {
      final f = await _file('session.json');
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString());
        if (m is Map && m['u'] is String && m['p'] is String) {
          return Credentials(m['u'] as String, m['p'] as String);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveCreds(String u, String p) async {
    var secureOk = false;
    try {
      await _secure.write(key: 'tvm_user', value: u);
      await _secure.write(key: 'tvm_pass', value: p);
      secureOk = await _secure.read(key: 'tvm_pass') == p;
    } catch (_) {}
    if (!secureOk) {
      try {
        final f = await _file('session.json');
        await f.writeAsString(jsonEncode({'u': u, 'p': p}));
      } catch (_) {}
    }
  }

  Future<List<MediaItem>?> readCache(MediaKind k) async {
    try {
      final f = await _file('cache_${k.name}.json');
      if (!await f.exists()) return null;
      return await compute(_decodeItems, await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCache(MediaKind k, List<MediaItem> items) async {
    try {
      final f = await _file('cache_${k.name}.json');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(await compute(_encodeItems, items));
      await tmp.rename(f.path);
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await _secure.delete(key: 'tvm_user');
      await _secure.delete(key: 'tvm_pass');
    } catch (_) {}
    try {
      await _file('session.json').then((f) async {
        if (await f.exists()) await f.delete();
      });
      for (final k in MediaKind.values) {
        final f = await _file('cache_${k.name}.json');
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }
}

/// مصدر المحتوى: يعرض النسخة المخزنة فوراً ثم يحدّثها من الخادم.
class Repo {
  final XtreamClient client;
  final Store store;
  final XtreamSession session;
  Repo(this.client, this.store, this.session);
  final Map<MediaKind, List<MediaItem>> _mem = {};
  final Set<MediaKind> _fresh = {};

  bool isFresh(MediaKind k) => _fresh.contains(k);

  Future<List<MediaItem>?> cached(MediaKind k) async {
    final m = _mem[k];
    if (m != null) return m;
    final d = await store.readCache(k);
    if (d != null) _mem[k] = d;
    return d;
  }

  Future<List<MediaItem>> refresh(MediaKind k) async {
    final list = switch (k) {
      MediaKind.movie => await client.movies(session),
      MediaKind.series => await client.series(session),
      MediaKind.live => await client.live(session),
    };
    _mem[k] = list;
    _fresh.add(k);
    unawaited(store.writeCache(k, list));
    return list;
  }
}

class XtreamSession {
  final String host, username, password;
  const XtreamSession(this.host, this.username, this.password);
  Uri uri({String? action, Map<String, String> extra = const {}}) =>
      Uri.parse('$host/player_api.php').replace(
        queryParameters: {
          'username': username,
          'password': password,
          if (action != null) 'action': action,
          ...extra,
        },
      );
  String streamUrl(MediaItem item) {
    final folder = item.kind == MediaKind.live ? 'live' : 'movie';
    return '$host/$folder/$username/$password/${item.id}.${item.extension.isEmpty ? 'mp4' : item.extension}';
  }
}

class XtreamClient {
  final String host = 'http://103.175.129.163:80';
  Future<XtreamSession> login(String username, String password) async {
    final session = XtreamSession(host, username, password);
    final response = await http
        .get(session.uri())
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200)
      throw Exception('الخادم رفض الاتصال (${response.statusCode})');
    final data = jsonDecode(response.body);
    final info = data is Map && data['user_info'] is Map
        ? data['user_info'] as Map
        : null;
    if (info == null) throw Exception('رد غير متوقع من الخادم');
    if (info['auth'].toString() == '0') {
      throw const AuthFailed('اسم المستخدم أو كلمة المرور غير صحيحة');
    }
    return session;
  }

  Future<List<dynamic>> _get(
    XtreamSession s,
    String action, {
    Map<String, String> extra = const {},
  }) async {
    final r = await http
        .get(s.uri(action: action, extra: extra))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200)
      throw Exception('تعذر تحميل $action (${r.statusCode})');
    final value = jsonDecode(r.body);
    return value is List ? value : <dynamic>[];
  }

  Future<Map<String, String>> _categories(
    XtreamSession s,
    String action,
  ) async {
    final rows = await _get(s, action);
    return {
      for (final x in rows.whereType<Map>())
        (x['category_id'] ?? '').toString(): (x['category_name'] ?? 'عام')
            .toString(),
    };
  }

  Future<List<MediaItem>> movies(XtreamSession s) async {
    final cats = await _categories(s, 'get_vod_categories');
    final rows = await _get(s, 'get_vod_streams');
    return rows.whereType<Map>().map((m) {
      final id = (m['stream_id'] ?? '').toString();
      return MediaItem(
        title: (m['name'] ?? 'بدون عنوان').toString(),
        poster: (m['stream_icon'] ?? '').toString(),
        category: cats[(m['category_id'] ?? '').toString()] ?? 'أفلام',
        id: id,
        extension: (m['container_extension'] ?? 'mp4').toString(),
        description: (m['plot'] ?? 'متاح من خادم البث').toString(),
        kind: MediaKind.movie,
        rating: double.tryParse((m['rating'] ?? '0').toString()) ?? 0,
        duration: int.tryParse((m['duration_secs'] ?? '0').toString()) ?? 0,
        streamUrl: s.streamUrl(
          MediaItem(
            title: '',
            poster: '',
            category: '',
            id: id,
            extension: (m['container_extension'] ?? 'mp4').toString(),
            description: '',
            kind: MediaKind.movie,
            rating: 0,
            duration: 0,
          ),
        ),
      );
    }).toList();
  }

  Future<List<MediaItem>> live(XtreamSession s) async {
    final cats = await _categories(s, 'get_live_categories');
    final rows = await _get(s, 'get_live_streams');
    return rows.whereType<Map>().map((m) {
      final id = (m['stream_id'] ?? '').toString();
      return MediaItem(
        title: (m['name'] ?? 'قناة').toString(),
        poster: (m['stream_icon'] ?? '').toString(),
        category: cats[(m['category_id'] ?? '').toString()] ?? 'مباشر',
        id: id,
        extension: 'ts',
        description: 'بث مباشر',
        kind: MediaKind.live,
        rating: 0,
        duration: 0,
        streamUrl: s.streamUrl(
          MediaItem(
            title: '',
            poster: '',
            category: '',
            id: id,
            extension: 'ts',
            description: '',
            kind: MediaKind.live,
            rating: 0,
            duration: 0,
          ),
        ),
      );
    }).toList();
  }

  Future<List<MediaItem>> series(XtreamSession s) async {
    final cats = await _categories(s, 'get_series_categories');
    final rows = await _get(s, 'get_series');
    return rows
        .whereType<Map>()
        .map(
          (m) => MediaItem(
            title: (m['name'] ?? 'مسلسل').toString(),
            poster: (m['cover'] ?? '').toString(),
            category: cats[(m['category_id'] ?? '').toString()] ?? 'مسلسلات',
            id: (m['series_id'] ?? '').toString(),
            extension: '',
            description: (m['plot'] ?? '').toString(),
            kind: MediaKind.series,
            rating: double.tryParse((m['rating'] ?? '0').toString()) ?? 0,
            duration: 0,
          ),
        )
        .toList();
  }

  Future<List<MediaItem>> episodes(XtreamSession s, String seriesId) async {
    final r = await http
        .get(s.uri(action: 'get_series_info', extra: {'series_id': seriesId}))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('تعذر تحميل حلقات المسلسل');
    final data = jsonDecode(r.body);
    final episodes = <MediaItem>[];
    if (data is Map && data['episodes'] is Map) {
      for (final season in (data['episodes'] as Map).values) {
        if (season is List)
          for (final e in season.whereType<Map>()) {
            final id = (e['id'] ?? e['episode_id'] ?? '').toString();
            final ext = (e['container_extension'] ?? 'mp4').toString();
            episodes.add(
              MediaItem(
                title: 'الحلقة ${(e['episode_num'] ?? episodes.length + 1)}',
                poster:
                    (e['info'] is Map ? (e['info']['movie_image'] ?? '') : '')
                        .toString(),
                category: 'الحلقات',
                id: id,
                extension: ext,
                description: (e['title'] ?? '').toString(),
                kind: MediaKind.movie,
                rating: 0,
                duration:
                    int.tryParse(
                      (e['info'] is Map ? e['info']['duration_secs'] : '0')
                          .toString(),
                    ) ??
                    0,
                streamUrl: s.streamUrl(
                  MediaItem(
                    title: '',
                    poster: '',
                    category: '',
                    id: id,
                    extension: ext,
                    description: '',
                    kind: MediaKind.movie,
                    rating: 0,
                    duration: 0,
                  ),
                ),
              ),
            );
          }
      }
    }
    return episodes;
  }
}

class TVMApp extends StatefulWidget {
  const TVMApp({super.key});
  @override
  State<TVMApp> createState() => _TVMState();
}

class _TVMState extends State<TVMApp> {
  final client = XtreamClient();
  final store = Store();
  Repo? repo;
  bool booting = true, loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  /// عند فتح التطبيق: إن وُجدت بيانات دخول محفوظة ندخل مباشرة بدون شاشة تسجيل.
  Future<void> _boot() async {
    final c = await store.readCreds();
    if (c != null) {
      final s = XtreamSession(client.host, c.user, c.pass);
      repo = Repo(client, store, s);
      _validate(s);
    }
    if (mounted) setState(() => booting = false);
  }

  /// تحقق صامت في الخلفية. لا نُخرج المستخدم إلا إذا رفض الخادم الحساب صراحةً؛
  /// أما انقطاع الشبكة فيُبقي المحتوى المخزن ظاهراً.
  Future<void> _validate(XtreamSession s) async {
    try {
      await client.login(s.username, s.password);
    } on AuthFailed catch (e) {
      await _logout(message: e.message);
    } catch (_) {}
  }

  Future<void> signIn(String u, String p) async {
    if (u.isEmpty || p.isEmpty) {
      setState(() => error = 'أدخل اسم المستخدم وكلمة المرور');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final s = await client.login(u, p);
      await store.saveCreds(u, p);
      final r = Repo(client, store, s);
      // تحميل الأقسام الثلاثة وتخزينها قبل فتح الواجهة؛ فشل قسم لا يمنع الدخول.
      await Future.wait(
        MediaKind.values.map((k) => r.refresh(k).then((_) {}, onError: (_) {})),
      );
      if (mounted) setState(() => repo = r);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _logout({String? message}) async {
    await store.clear();
    if (mounted) {
      setState(() {
        repo = null;
        error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'TVM',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff080b14),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff7c5cff),
        brightness: Brightness.dark,
      ),
    ),
    // الاتجاه من اليمين لليسار لكل الشاشات بما فيها المشغل والنوافذ المنبثقة.
    builder: (context, child) =>
        Directionality(textDirection: TextDirection.rtl, child: child!),
    home: booting
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : repo == null
        ? LoginPage(onSubmit: signIn, busy: loading, error: error)
        : CatalogPage(repo: repo!, onLogout: _logout),
  );
}

class LoginPage extends StatefulWidget {
  final Future<void> Function(String, String) onSubmit;
  final bool busy;
  final String? error;
  const LoginPage({
    super.key,
    required this.onSubmit,
    required this.busy,
    required this.error,
  });
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  final u = TextEditingController();
  final p = TextEditingController();
  @override
  void dispose() {
    u.dispose();
    p.dispose();
    super.dispose();
  }

  void _showPairing() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ربط TVM بالشاشة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: 'tvm://pair?device=TVM',
              size: 180,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            const Text(
              'رمز الربط يحتاج خدمة pairing من السيرفر حتى ينقل البيانات بأمان. الإدخال اليدوي متاح الآن.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  void _submit() => widget.onSubmit(u.text.trim(), p.text);

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xff7c5cff),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: const Icon(Icons.live_tv_rounded, size: 46),
                ),
                const SizedBox(height: 20),
                const Text(
                  'TVM',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                const Text(
                  'ترفيه ذكي للهاتف والشاشة',
                  style: TextStyle(color: Colors.white60),
                ),
                const SizedBox(height: 28),
                Card(
                  color: const Color(0xff141927),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        TextField(
                          controller: u,
                          textDirection: TextDirection.ltr,
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'اسم المستخدم',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: p,
                          obscureText: true,
                          textDirection: TextDirection.ltr,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: 'كلمة المرور',
                            prefixIcon: Icon(Icons.lock_outline),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (widget.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              widget.error!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton.icon(
                            onPressed: widget.busy ? null : _submit,
                            icon: widget.busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.login),
                            label: Text(
                              widget.busy ? 'جارٍ تحميل المحتوى...' : 'دخول',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xff7c5cff),
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _showPairing,
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text('ربط بالشاشة عبر باركود'),
                        ),
                      ],
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

class CatalogPage extends StatefulWidget {
  final Repo repo;
  final Future<void> Function({String? message}) onLogout;
  const CatalogPage({super.key, required this.repo, required this.onLogout});
  @override
  State<CatalogPage> createState() => _CatalogState();
}

class _CatalogState extends State<CatalogPage> {
  int tab = 0;
  String q = '';
  String category = 'الكل';
  bool ascending = true;
  List<MediaItem>? items;
  List<String> cats = const ['الكل'];
  List<MediaItem> view = const [];
  bool refreshing = false;
  String? error;
  int _gen = 0;

  MediaKind get kind => MediaKind.values[tab];
  String get title => tab == 0
      ? 'الأفلام'
      : tab == 1
      ? 'المسلسلات'
      : 'البث المباشر';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// يعرض المحتوى المخزن فوراً، ثم يحدّثه من الخادم في الخلفية.
  Future<void> _load() async {
    final gen = ++_gen;
    final k = kind;
    final cached = await widget.repo.cached(k);
    if (!mounted || gen != _gen) return;
    if (cached != null) {
      setState(() {
        items = cached;
        _apply();
      });
      if (widget.repo.isFresh(k)) return;
    }
    setState(() => refreshing = true);
    try {
      final fresh = await widget.repo.refresh(k);
      if (!mounted || gen != _gen) return;
      setState(() {
        items = fresh;
        refreshing = false;
        _apply();
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        refreshing = false;
        if (items == null) {
          error = e.toString().replaceFirst('Exception: ', '');
        }
      });
    }
  }

  /// إعادة حساب القائمة المعروضة مرة واحدة عند تغير البيانات أو الفلتر (لا في كل بناء).
  void _apply() {
    final src = items ?? const <MediaItem>[];
    cats = <String>{'الكل', ...src.map((x) => x.category)}.toList();
    final ql = q.toLowerCase();
    final v = src
        .where(
          (x) =>
              (ql.isEmpty || x.title.toLowerCase().contains(ql)) &&
              (category == 'الكل' || x.category == category),
        )
        .toList();
    v.sort(
      (a, b) =>
          ascending ? a.title.compareTo(b.title) : b.title.compareTo(a.title),
    );
    view = v;
  }

  void _select(int v) {
    if (v == tab) return;
    setState(() {
      tab = v;
      category = 'الكل';
      q = '';
      items = null;
      error = null;
      refreshing = false;
      _apply();
    });
    _load();
  }

  Future<void> _search() async {
    final ctl = TextEditingController(text: q);
    final res = await showDialog<String>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('بحث'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (v) => Navigator.pop(dc, v),
          decoration: const InputDecoration(
            hintText: 'ابحث في المحتوى',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dc, ''),
            child: const Text('مسح'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dc, ctl.text),
            child: const Text('بحث'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (res == null || !mounted) return;
    setState(() {
      q = res.trim();
      _apply();
    });
  }

  Widget _body() {
    if (items == null) {
      if (error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('تعذر تحميل المحتوى:\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  autofocus: true,
                  onPressed: () {
                    setState(() => error = null);
                    _load();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        if (refreshing) const LinearProgressIndicator(minHeight: 2),
        SizedBox(
          height: 52,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            scrollDirection: Axis.horizontal,
            itemCount: cats.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) => ChoiceChip(
              label: Text(cats[i]),
              selected: category == cats[i],
              onSelected: (_) => setState(() {
                category = cats[i];
                _apply();
              }),
              selectedColor: const Color(0xff7c5cff),
            ),
          ),
        ),
        Expanded(
          child: view.isEmpty
              ? const Center(child: Text('لا يوجد محتوى'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  // عدد الأعمدة يتكيف مع حجم الشاشة (هاتف أو شاشة كبيرة).
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    childAspectRatio: .62,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: view.length,
                  itemBuilder: (_, i) => _FocusCard(
                    key: ValueKey('${view[i].kind.name}-${view[i].id}'),
                    item: view[i],
                    autofocus: i == 0,
                    onTap: () => _open(view[i]),
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext c) {
    final wide = MediaQuery.sizeOf(c).width >= 800;
    return Scaffold(
      appBar: AppBar(
        title: Text(q.isEmpty ? title : '$title — «$q»'),
        actions: [
          IconButton(
            tooltip: 'بحث',
            onPressed: _search,
            icon: Icon(q.isEmpty ? Icons.search : Icons.manage_search),
          ),
          IconButton(
            tooltip: 'ترتيب',
            onPressed: () => setState(() {
              ascending = !ascending;
              _apply();
            }),
            icon: Icon(ascending ? Icons.sort_by_alpha : Icons.sort),
          ),
          IconButton(
            tooltip: 'تسجيل الخروج',
            onPressed: _confirmLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      // على الشاشات الكبيرة: شريط جانبي يسهل التنقل بالريموت؛ على الهاتف: شريط سفلي.
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: tab,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.movie_outlined),
                      label: Text('أفلام'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.tv_outlined),
                      label: Text('مسلسلات'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.live_tv_outlined),
                      label: Text('مباشر'),
                    ),
                  ],
                ),
                Expanded(child: _body()),
              ],
            )
          : _body(),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: _select,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.movie_outlined),
                  label: 'أفلام',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tv_outlined),
                  label: 'مسلسلات',
                ),
                NavigationDestination(
                  icon: Icon(Icons.live_tv_outlined),
                  label: 'مباشر',
                ),
              ],
            ),
    );
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('تسجيل الخروج'),
        content: const Text(
          'سيتم حذف بيانات الدخول والمحتوى المخزن، وستحتاج لإدخالها مرة أخرى.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dc, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dc, true),
            child: const Text('خروج'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onLogout();
  }

  void _open(MediaItem item) {
    if (item.kind == MediaKind.series) {
      _showEpisodes(item);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PlayerPage(item: item)),
      );
    }
  }

  Future<void> _showEpisodes(MediaItem series) async {
    final nav = Navigator.of(context, rootNavigator: true);
    // نافذة التحميل لا تُغلق بزر الرجوع حتى لا يُغلق غيرها عند انتهاء التحميل.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    try {
      final eps = await widget.repo.client.episodes(
        widget.repo.session,
        series.id,
      );
      nav.pop();
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .7,
          maxChildSize: .95,
          builder: (_, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                series.title,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (eps.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('لا توجد حلقات متاحة')),
                ),
              for (var i = 0; i < eps.length; i++)
                ListTile(
                  autofocus: i == 0,
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(eps[i].title),
                  subtitle: Text(eps[i].description),
                  onTap: () {
                    Navigator.pop(sheet);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlayerPage(item: eps[i]),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      );
    } catch (e) {
      nav.pop();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }
}

/// بطاقة محتوى قابلة للتحديد بالريموت (أسهم + OK) مع إطار واضح عند التركيز.
class _FocusCard extends StatefulWidget {
  final MediaItem item;
  final VoidCallback onTap;
  final bool autofocus;
  const _FocusCard({
    super.key,
    required this.item,
    required this.onTap,
    this.autofocus = false,
  });
  @override
  State<_FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<_FocusCard> {
  bool focused = false;

  static const _placeholder = Center(
    child: Icon(Icons.movie_outlined, size: 44, color: Colors.white38),
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final radius = BorderRadius.circular(12);
    return AnimatedScale(
      scale: focused ? 1.06 : 1,
      duration: const Duration(milliseconds: 120),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: focused ? Colors.white : Colors.transparent,
            width: 3,
          ),
        ),
        child: Material(
          color: const Color(0xff141927),
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            autofocus: widget.autofocus,
            onTap: widget.onTap,
            onFocusChange: (v) => setState(() => focused = v),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: item.poster.isEmpty
                      ? _placeholder
                      : Image.network(
                          item.poster,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          cacheWidth: 320,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => _placeholder,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.category,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      if (item.rating > 0)
                        Text(
                          '★ ${item.rating.toStringAsFixed(1)}',
                          style: const TextStyle(
                            color: Color(0xffffc857),
                            fontSize: 11,
                          ),
                        ),
                    ],
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

class PlayerPage extends StatefulWidget {
  final MediaItem item;
  const PlayerPage({super.key, required this.item});
  @override
  State<PlayerPage> createState() => _PlayerState();
}

class _PlayerState extends State<PlayerPage> {
  VideoPlayerController? _c;
  bool ready = false;
  String? error;
  bool controls = true;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double speed = 1.0;
  double volume = 1.0;
  BoxFit _fit = BoxFit.contain;
  bool _dialogOpen = false;
  Timer? _hide;
  final _focus = FocusNode(debugLabel: 'player');
  final _playBtn = FocusNode(debugLabel: 'play');

  bool get isLive => widget.item.kind == MediaKind.live;

  @override
  void initState() {
    super.initState();
    // ملء الشاشة بالكامل: إخفاء أشرطة النظام وعدم وجود شريط علوي دائم.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _start();
  }

  Future<void> _start() async {
    try {
      final url = widget.item.streamUrl;
      if (url == null || url.isEmpty) throw Exception('رابط التشغيل غير متوفر');
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      _c = c; // يُتخلص منه في dispose حتى لو فشلت التهيئة
      c.addListener(() {
        if (!mounted) return;
        setState(() {
          position = c.value.position;
          duration = c.value.duration;
          if (c.value.hasError && error == null) {
            error = c.value.errorDescription ?? 'خطأ أثناء التشغيل';
          }
        });
      });
      await c.initialize();
      if (!mounted) return;
      setState(() => ready = true);
      await c.play();
      _showControls();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    _focus.dispose();
    _playBtn.dispose();
    _c?.dispose();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _resetHideTimer() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 5), () {
      if (mounted && !_dialogOpen && _c?.value.isPlaying == true) {
        _hideControls();
      }
    });
  }

  void _showControls({bool focusBar = false}) {
    if (!mounted) return;
    setState(() => controls = true);
    _resetHideTimer();
    if (focusBar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _playBtn.canRequestFocus) _playBtn.requestFocus();
      });
    }
  }

  void _hideControls() {
    if (!mounted) return;
    setState(() => controls = false);
    _hide?.cancel();
    _focus.requestFocus();
  }

  void _toggle() {
    final c = _c;
    if (c == null || !ready) return;
    c.value.isPlaying ? c.pause() : c.play();
    _showControls();
  }

  /// الريموت (والتركيز على الفيديو نفسه): OK = تشغيل/إيقاف، يمين/يسار = تقديم/تأخير 10 ثوانٍ،
  /// أعلى/أسفل = إظهار أزرار التحكم والانتقال إليها.
  /// عندما يكون التركيز على أحد الأزرار تعمل الأسهم للتنقل بين الأزرار بشكل طبيعي.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (!node.hasPrimaryFocus) {
      if (controls) _resetHideTimer();
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final down = e is KeyDownEvent;
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      if (down) _toggle();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlay) {
      _c?.play();
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPause) {
      _c?.pause();
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.mediaRewind) {
      if (!isLive) _seek(-10);
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.mediaFastForward) {
      if (!isLive) _seek(10);
      _showControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      _showControls(focusBar: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _time(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _seek(int seconds) async {
    final c = _c;
    if (c == null || !ready) return;
    final next = c.value.position + Duration(seconds: seconds);
    await c.seekTo(
      next < Duration.zero
          ? Duration.zero
          : (next > c.value.duration ? c.value.duration : next),
    );
  }

  String get _fitLabel => _fit == BoxFit.contain
      ? 'أصلي'
      : _fit == BoxFit.cover
      ? 'ملء الشاشة'
      : 'تمديد';

  /// تبديل شكل العرض: أصلي ← ملء الشاشة (قص الأطراف) ← تمديد.
  void _cycleFit() {
    setState(() {
      _fit = _fit == BoxFit.contain
          ? BoxFit.cover
          : _fit == BoxFit.cover
          ? BoxFit.fill
          : BoxFit.contain;
    });
    _resetHideTimer();
  }

  String _trackLabel(VideoAudioTrack t, int i) {
    final parts = [
      if ((t.label ?? '').isNotEmpty) t.label!,
      if ((t.language ?? '').isNotEmpty) '(${t.language})',
    ];
    return parts.isEmpty ? 'مسار ${i + 1}' : parts.join(' ');
  }

  Future<void> _audioMenu() async {
    final c = _c;
    if (c == null || !ready) return;
    _dialogOpen = true;
    try {
      List<VideoAudioTrack> tracks = const [];
      try {
        tracks = await c.getAudioTracks();
      } catch (_) {}
      if (!mounted) return;
      if (tracks.length < 2) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا توجد مسارات صوت أخرى في هذا المحتوى'),
          ),
        );
        return;
      }
      final id = await showDialog<String>(
        context: context,
        builder: (dc) => SimpleDialog(
          title: const Text('الصوت واللغة'),
          children: [
            for (var i = 0; i < tracks.length; i++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dc, tracks[i].id),
                child: Row(
                  children: [
                    Icon(
                      tracks[i].isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_trackLabel(tracks[i], i)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
      if (id != null) await c.selectAudioTrack(id);
    } finally {
      _dialogOpen = false;
      if (mounted) _resetHideTimer();
    }
  }

  Widget _btn(
    IconData icon,
    VoidCallback onTap, {
    String? tip,
    FocusNode? node,
    double size = 28,
  }) => IconButton(
    focusNode: node,
    tooltip: tip,
    iconSize: size,
    onPressed: onTap,
    style: ButtonStyle(
      // إطار واضح للزر المحدد بالريموت
      side: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.focused)
            ? const BorderSide(color: Colors.white, width: 2.5)
            : null,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.focused) ? Colors.white24 : null,
      ),
    ),
    icon: Icon(icon),
  );

  Widget _controls(VideoPlayerController v) {
    final max = duration.inMilliseconds == 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final value = duration.inMilliseconds == 0
        ? 0.0
        : position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble();
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent, Colors.black87],
            stops: [0, .45, 1],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // الشريط العلوي: رجوع + الاسم فوق الفيديو (لا يقتطع من مساحة الشاشة)
              Row(
                children: [
                  _btn(
                    Icons.arrow_forward,
                    () => Navigator.maybePop(context),
                    tip: 'رجوع',
                  ),
                  Expanded(
                    child: Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: isLive
                    ? const Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text('● بث مباشر'),
                      )
                    : Directionality(
                        textDirection: TextDirection.ltr,
                        child: Row(
                          children: [
                            Text(
                              _time(position),
                              style: const TextStyle(fontSize: 12),
                            ),
                            Expanded(
                              // السحب باللمس فقط؛ الريموت يقدّم/يؤخر بالأسهم.
                              child: ExcludeFocus(
                                child: Slider(
                                  value: value,
                                  max: max,
                                  onChanged: (x) => v.seekTo(
                                    Duration(milliseconds: x.round()),
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              _time(duration),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    if (!isLive)
                      _btn(Icons.replay_10, () {
                        _seek(-10);
                        _resetHideTimer();
                      }, tip: 'رجوع 10 ثوانٍ'),
                    _btn(
                      v.value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      _toggle,
                      node: _playBtn,
                      size: 44,
                      tip: 'تشغيل / إيقاف',
                    ),
                    if (!isLive)
                      _btn(Icons.forward_10, () {
                        _seek(10);
                        _resetHideTimer();
                      }, tip: 'تقديم 10 ثوانٍ'),
                    _btn(
                      volume == 0 ? Icons.volume_off : Icons.volume_up,
                      () {
                        setState(() => volume = volume == 0 ? 1 : 0);
                        v.setVolume(volume);
                        _resetHideTimer();
                      },
                      tip: 'كتم الصوت',
                    ),
                    PopupMenuButton<double>(
                      tooltip: 'السرعة',
                      initialValue: speed,
                      onOpened: () => _dialogOpen = true,
                      onCanceled: () {
                        _dialogOpen = false;
                        _resetHideTimer();
                      },
                      onSelected: (x) {
                        _dialogOpen = false;
                        setState(() => speed = x);
                        v.setPlaybackSpeed(x);
                        _resetHideTimer();
                      },
                      itemBuilder: (_) => [0.75, 1.0, 1.25, 1.5, 2.0]
                          .map(
                            (x) =>
                                PopupMenuItem(value: x, child: Text('${x}x')),
                          )
                          .toList(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Text(
                          '${speed}x',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    _btn(Icons.aspect_ratio, _cycleFit, tip: 'العرض: $_fitLabel'),
                    Text(
                      _fitLabel,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    _btn(Icons.record_voice_over_outlined, _audioMenu, tip: 'الصوت واللغة'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// الفيديو يملأ الشاشة كاملة على خلفية سوداء (بدون شريط علوي).
  Widget _video(VideoPlayerController v) {
    final s = v.value.size;
    final w = s.width > 0 ? s.width : 1920.0;
    final h = s.height > 0 ? s.height : 1080.0;
    return SizedBox.expand(
      child: FittedBox(
        fit: _fit,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(width: w, height: h, child: VideoPlayer(v)),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final v = _c;
    return PopScope(
      // زر الرجوع: أول ضغطة تخفي أزرار التحكم، والثانية تخرج من المشغل.
      canPop: !controls || error != null || v == null || !ready,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hideControls();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: error != null
              ? Stack(
                  children: [
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'تعذر تشغيل المحتوى:\n$error',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: SafeArea(
                        child: _btn(
                          Icons.arrow_forward,
                          () => Navigator.maybePop(context),
                          tip: 'رجوع',
                        ),
                      ),
                    ),
                  ],
                )
              : (v == null || !ready)
              ? const Center(child: CircularProgressIndicator())
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (controls) {
                      _hideControls();
                    } else {
                      _showControls();
                    }
                  },
                  child: Stack(
                    children: [
                      _video(v),
                      if (controls) _controls(v),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
