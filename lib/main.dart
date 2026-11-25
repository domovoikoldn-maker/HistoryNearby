// История рядом 3.0 (Flutter) - статьи Википедии с фото рядом с тобой или в любом городе.
// Разработчик: domovoi4ik
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String kLang = 'ru'; // язык Википедии: ru / en / ...
const String kUserAgent = 'HistoryNearby/3.0 (flutter hobby app; domovoi4ik)';
const List<int> kRadii = [500, 1000, 3000, 10000];

// ====================== модели и сеть ======================
class AppError implements Exception {
  final String message;
  AppError(this.message);
  @override
  String toString() => message;
}

class Loc {
  final double lat, lon;
  final String name;
  const Loc(this.lat, this.lon, this.name);
}

class Place {
  final int id;
  final String title, extract, url;
  final String? image;
  final double lat, lon;
  final int dist; // метры
  const Place({
    required this.id,
    required this.title,
    required this.extract,
    required this.url,
    required this.image,
    required this.lat,
    required this.lon,
    required this.dist,
  });
}

String fmtDist(int m) => m < 1000 ? '$m м' : '${(m / 1000).toStringAsFixed(1)} км';
String fmtRadius(int m) => m < 1000 ? '$m м' : '${m ~/ 1000} км';

Future<dynamic> _getJson(Uri uri) async {
  final r = await http
      .get(uri, headers: {'User-Agent': kUserAgent, 'Accept-Language': kLang})
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw AppError('сервер ответил ${r.statusCode}');
  return jsonDecode(utf8.decode(r.bodyBytes));
}

Future<dynamic> _wikiApi(Map<String, String> params) => _getJson(Uri.https(
      '$kLang.wikipedia.org',
      '/w/api.php',
      {'action': 'query', 'format': 'json', ...params},
    ));

/// 1) geosearch: ближайшие статьи с расстоянием и координатами
/// 2) один запрос за текстами, ссылками и фото (pageimages)
Future<List<Place>> searchPlaces(double lat, double lon, int radius) async {
  final geo = (await _wikiApi({
    'list': 'geosearch',
    'gscoord': '$lat|$lon',
    'gsradius': '$radius',
    'gslimit': '20',
  })) as Map<String, dynamic>;
  final hits = ((geo['query'] as Map<String, dynamic>?)?['geosearch'] as List<dynamic>?) ?? <dynamic>[];
  if (hits.isEmpty) return [];

  final ids = hits.map((h) => (h as Map<String, dynamic>)['pageid']).join('|');
  final info = (await _wikiApi({
    'prop': 'extracts|info|pageimages',
    'pageids': ids,
    'exintro': '1',
    'explaintext': '1',
    'exlimit': 'max',
    'inprop': 'url',
    'piprop': 'thumbnail',
    'pithumbsize': '700',
    'pilimit': 'max',
  })) as Map<String, dynamic>;
  final pages =
      ((info['query'] as Map<String, dynamic>?)?['pages'] as Map<String, dynamic>?) ?? <String, dynamic>{};

  final places = hits.map<Place>((h) {
    final m = h as Map<String, dynamic>;
    final id = (m['pageid'] as num).toInt();
    final p = (pages['$id'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final thumb = (p['thumbnail'] as Map<String, dynamic>?)?['source'] as String?;
    return Place(
      id: id,
      title: (m['title'] as String?) ?? '',
      extract: ((p['extract'] as String?) ?? '').trim(),
      url: (p['fullurl'] as String?) ?? 'https://$kLang.wikipedia.org/?curid=$id',
      image: thumb,
      lat: (m['lat'] as num).toDouble(),
      lon: (m['lon'] as num).toDouble(),
      dist: (m['dist'] as num?)?.round() ?? 0,
    );
  }).toList();
  places.sort((a, b) => a.dist.compareTo(b.dist));
  return places;
}

final RegExp _coordRe = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*[;,\s]\s*(-?\d+(?:\.\d+)?)\s*$');

/// Название города/адреса или координаты "59.93, 30.31" -> место (OpenStreetMap Nominatim)
Future<Loc?> geocode(String q) async {
  final m = _coordRe.firstMatch(q);
  if (m != null) {
    final lat = double.parse(m.group(1)!);
    final lon = double.parse(m.group(2)!);
    if (lat.abs() > 90 || lon.abs() > 180) throw AppError('координаты вне диапазона');
    return Loc(lat, lon, '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}');
  }
  final data = (await _getJson(Uri.https('nominatim.openstreetmap.org', '/search', {
    'q': q,
    'format': 'jsonv2',
    'limit': '1',
    'accept-language': kLang,
  }))) as List<dynamic>;
  if (data.isEmpty) return null;
  final d = data.first as Map<String, dynamic>;
  final parts = ((d['display_name'] as String?) ?? q).split(', ');
  var name = ((d['name'] as String?) ?? '').isNotEmpty ? d['name'] as String : parts.first;
  if (parts.length > 1) name += ', ${parts.last}';
  return Loc(double.parse(d['lat'] as String), double.parse(d['lon'] as String), name);
}

/// Примерное место по IP (запасной вариант, если GPS недоступен)
Future<Loc> ipLocate() async {
  try {
    final d = (await _getJson(Uri.https('ipwho.is', '/'))) as Map<String, dynamic>;
    if (d['success'] == true) {
      return Loc((d['latitude'] as num).toDouble(), (d['longitude'] as num).toDouble(),
          '${d['city'] ?? '?'}, ${d['country'] ?? ''} (по IP)');
    }
  } catch (_) {}
  final d = (await _getJson(Uri.https('ipapi.co', '/json/'))) as Map<String, dynamic>;
  if (d['latitude'] == null) throw AppError('не удалось определить по IP');
  return Loc((d['latitude'] as num).toDouble(), (d['longitude'] as num).toDouble(),
      '${d['city'] ?? '?'}, ${d['country_name'] ?? ''} (по IP)');
}

Future<Position> currentPosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw AppError('Геолокация выключена в настройках телефона');
  }
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    throw AppError('Нет разрешения на геолокацию');
  }
  try {
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
  } on TimeoutException {
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return last;
    throw AppError('Не удалось поймать сигнал GPS');
  }
}

Future<bool> openExternal(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

String errText(Object e) {
  if (e is AppError) return e.message;
  if (e is TimeoutException) return 'превышено время ожидания сети';
  return e.toString();
}

// ====================== интерфейс ======================
void main() => runApp(const HistoryApp());

class HistoryApp extends StatelessWidget {
  const HistoryApp({super.key});

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F6BFF), brightness: b),
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'История рядом',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _q = TextEditingController();
  Loc? _loc;
  int _radiusIdx = 1;
  List<Place> _places = [];
  bool _loading = false;
  bool _isError = false;
  String _status = '';
  int _req = 0; // номер последнего запроса: устаревшие ответы игнорируются

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    final lat = p.getDouble('lat');
    final lon = p.getDouble('lon');
    final name = p.getString('name');
    _radiusIdx = (p.getInt('radius') ?? 1).clamp(0, kRadii.length - 1).toInt();
    if (lat != null && lon != null && name != null) {
      if (!mounted) return;
      setState(() => _loc = Loc(lat, lon, name));
      _search();
    } else {
      _locateMe();
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    final l = _loc;
    if (l != null) {
      await p.setDouble('lat', l.lat);
      await p.setDouble('lon', l.lon);
      await p.setString('name', l.name);
    }
    await p.setInt('radius', _radiusIdx);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _search() async {
    final loc = _loc;
    if (loc == null) return;
    final rid = ++_req;
    final radius = kRadii[_radiusIdx];
    setState(() {
      _loading = true;
      _isError = false;
      _status = 'Ищу статьи в радиусе ${fmtRadius(radius)}…';
    });
    try {
      final res = await searchPlaces(loc.lat, loc.lon, radius);
      if (!mounted || rid != _req) return;
      setState(() {
        _places = res;
        _loading = false;
        _status = res.isEmpty
            ? 'В радиусе ${fmtRadius(radius)} ничего не найдено. Увеличь радиус или введи другой город'
            : 'Найдено: ${res.length} в радиусе ${fmtRadius(radius)}';
      });
    } catch (e) {
      if (!mounted || rid != _req) return;
      setState(() {
        _loading = false;
        _isError = true;
        _status = 'Ошибка: ${errText(e)}';
      });
    }
  }

  Future<void> _setLoc(Loc loc) async {
    setState(() => _loc = loc);
    await _save();
    await _search();
  }

  Future<void> _locateMe() async {
    final rid = ++_req;
    setState(() {
      _loading = true;
      _isError = false;
      _status = 'Определяю местоположение…';
    });
    Loc? loc;
    String? note;
    try {
      final pos = await currentPosition();
      loc = Loc(pos.latitude, pos.longitude, 'Моя позиция');
    } catch (e) {
      note = errText(e);
      try {
        loc = await ipLocate();
      } catch (_) {}
    }
    if (!mounted || rid != _req) return;
    if (loc == null) {
      setState(() {
        _loading = false;
        _isError = true;
        _status = note ?? 'Не удалось определить местоположение';
      });
      return;
    }
    if (note != null) _toast('$note. Использую примерное место по IP');
    await _setLoc(loc);
  }

  Future<void> _findText(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    FocusScope.of(context).unfocus();
    final rid = ++_req;
    setState(() {
      _loading = true;
      _isError = false;
      _status = 'Ищу место: $t …';
    });
    try {
      final loc = await geocode(t);
      if (!mounted || rid != _req) return;
      if (loc == null) {
        setState(() {
          _loading = false;
          _isError = true;
          _status = 'Такое место не найдено. Попробуй написать иначе';
        });
        return;
      }
      await _setLoc(loc);
    } catch (e) {
      if (!mounted || rid != _req) return;
      setState(() {
        _loading = false;
        _isError = true;
        _status = 'Ошибка поиска места: ${errText(e)}';
      });
    }
  }

  void _setRadius(int i) {
    if (i == _radiusIdx) return;
    setState(() => _radiusIdx = i);
    _save();
    _search();
  }

  Future<void> _refresh() => _loc != null ? _search() : _locateMe();

  void _open(Place p) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailPage(place: p)));
  }

  Widget _header(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: _findText,
            decoration: InputDecoration(
              hintText: 'Город, адрес или 59.93, 30.31',
              filled: true,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: () => _findText(_q.text),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.place, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _loc?.name ?? 'Место не выбрано',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (var i = 0; i < kRadii.length; i++)
                ChoiceChip(
                  label: Text(fmtRadius(kRadii[i])),
                  selected: i == _radiusIdx,
                  onSelected: (_) => _setRadius(i),
                ),
            ],
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _status,
                style: TextStyle(color: _isError ? cs.error : cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _locateMe,
        icon: const Icon(Icons.my_location),
        label: const Text('Я здесь'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar.large(title: const Text('История рядом')),
            SliverToBoxAdapter(child: _header(cs)),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => PlaceCard(place: _places[i], onTap: () => _open(_places[i])),
                childCount: _places.length,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }
}

/// Фото статьи или красивая заглушка, если фото нет
class PlaceImage extends StatelessWidget {
  final String? url;
  const PlaceImage({super.key, required this.url});

  Widget _placeholder(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primaryContainer, cs.tertiaryContainer],
        ),
      ),
      child: Center(
        child: Icon(Icons.account_balance, size: 48, color: cs.onPrimaryContainer.withAlpha(140)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null) return _placeholder(context);
    return Image.network(
      u,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      headers: const {'User-Agent': kUserAgent},
      loadingBuilder: (c, child, progress) => progress == null ? child : _placeholder(c),
      errorBuilder: (c, e, s) => _placeholder(c),
    );
  }
}

class DistChip extends StatelessWidget {
  final String text;
  const DistChip({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(150),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.near_me, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

class PlaceCard extends StatelessWidget {
  final Place place;
  final VoidCallback onTap;
  const PlaceCard({super.key, required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 0,
      color: cs.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(tag: 'place-${place.id}', child: PlaceImage(url: place.image)),
                  Positioned(left: 12, bottom: 12, child: DistChip(text: fmtDist(place.dist))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(place.title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    place.extract.isEmpty ? '(нет описания)' : place.extract,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DetailPage extends StatelessWidget {
  final Place place;
  const DetailPage({super.key, required this.place});

  Future<void> _wiki(BuildContext context) async {
    final ok = await openExternal(place.url);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть ссылку')));
    }
  }

  Future<void> _map(BuildContext context) async {
    final t = Uri.encodeComponent(place.title);
    var ok = await openExternal('geo:${place.lat},${place.lon}?q=${place.lat},${place.lon}($t)');
    if (!ok) {
      ok = await openExternal(
          'https://www.openstreetmap.org/?mlat=${place.lat}&mlon=${place.lon}#map=17/${place.lat}/${place.lon}');
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось открыть карту')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            automaticallyImplyLeading: false,
            leading: Padding(
              padding: const EdgeInsets.all(6),
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(tag: 'place-${place.id}', child: PlaceImage(url: place.image)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black26],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('${fmtDist(place.dist)} от тебя',
                            style: TextStyle(color: cs.onPrimaryContainer, fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(place.title, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  Text(
                    place.extract.isEmpty ? '(нет описания)' : place.extract,
                    style: tt.bodyLarge?.copyWith(height: 1.55),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _wiki(context),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Читать в Википедии'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _map(context),
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('Показать на карте'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
