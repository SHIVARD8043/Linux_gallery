import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ════════════════════════════════════════════════════════════════════
//  GLOBALS / HELPERS
// ════════════════════════════════════════════════════════════════════
const _imageExts = {'jpg', 'jpeg', 'png', 'webp'};
const _videoExts = {'mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v'};
const _heicExts = {'heic', 'heif'}; // 👈 HEIC సపోర్ట్ యాడ్ చేసాం

final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

String cacheDir() => '${Platform.environment['HOME'] ?? '/tmp'}/.cache/shivas_gallery';

Color _placeholder(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? const Color(0xFF1B1E2A) : const Color(0xFFE1E4EC);

String _hash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  return h.toRadixString(16);
}

/// Lightweight record: type 0=image, 1=video, 2=heic
class GItem {
  final String path;
  final int ms;
  final int type;
  const GItem(this.path, this.ms, this.type);
  
  bool get isVideo => type == 1;
  bool get isHeic => type == 2;
}

class _Section {
  final String title;
  final int start, end;
  const _Section(this.title, this.start, this.end);
}

// ─── Folder scan (Isolate) ───
Future<List<GItem>?> scanFolder(String folder) => Isolate.run<List<GItem>?>(() {
      final root = Directory(folder);
      if (!root.existsSync()) return null;
      final out = <GItem>[];
      void walk(Directory d) {
        List<FileSystemEntity> items;
        try { items = d.listSync(followLinks: false); } catch (_) { return; }
        for (final e in items) {
          final name = e.path.substring(e.path.lastIndexOf('/') + 1);
          if (name.startsWith('.')) continue;
          if (e is Directory) {
            walk(e);
          } else if (e is File) {
            final dot = name.lastIndexOf('.');
            if (dot < 0) continue;
            final ext = name.substring(dot + 1).toLowerCase();
            
            final isV = _videoExts.contains(ext);
            final isH = _heicExts.contains(ext);
            if (!isV && !isH && !_imageExts.contains(ext)) continue;
            
            int type = isV ? 1 : (isH ? 2 : 0);
            try { out.add(GItem(e.path, e.statSync().modified.millisecondsSinceEpoch, type)); } catch (_) {}
          }
        }
      }
      walk(root);
      return out;
    });

// ─── RAM Optimized Index ───
Future<Map<String, List<GItem>>> readIndex() async {
  final f = File('${cacheDir()}/index.json');
  if (!f.existsSync()) return {};
  final jsonStr = await Isolate.run(() => f.readAsStringSync());
  if (jsonStr.isEmpty) return {};
  try {
    final j = jsonDecode(jsonStr) as Map<String, dynamic>;
    return j.map((k, v) => MapEntry(
        k, (v as List).map((e) => GItem(e[0] as String, e[1] as int, e[2] as int)).toList()));
  } catch (_) { return {}; }
}

Future<void> writeIndex(Map<String, List<GItem>> index) async {
  final jsonStr = jsonEncode(index.map(
      (k, v) => MapEntry(k, v.map((m) => [m.path, m.ms, m.type]).toList())));
  await Isolate.run(() {
    final dir = Directory(cacheDir())..createSync(recursive: true);
    final tmp = File('${dir.path}/index.tmp');
    tmp.writeAsStringSync(jsonStr);
    tmp.renameSync('${dir.path}/index.json');
  });
}

// ─── Shared Job class for Caching ───
class _Job {
  final GItem item;
  final File out;
  final bool Function() cancelled;
  final Completer<File?> done = Completer();
  _Job(this.item, this.out, this.cancelled);
}

// ─── HEIC Cache Engine ───
class HeicCache {
  static const _maxParallel = 2;
  static int _active = 0;
  static final _queue = Queue<_Job>();

  static Future<File?> get(GItem it, bool Function() cancelled) {
    final out = File('${cacheDir()}/heic/${_hash(it.path)}_${it.ms}.jpg');
    if (out.existsSync()) return Future.value(out);
    final j = _Job(it, out, cancelled);
    _queue.addLast(j); // LIFO logic
    _pump();
    return j.done.future;
  }

  static void _pump() {
    while (_active < _maxParallel && _queue.isNotEmpty) {
      final j = _queue.removeLast();
      if (j.cancelled()) { j.done.complete(null); continue; }
      _active++;
      _make(j).then(j.done.complete).whenComplete(() { _active--; _pump(); });
    }
  }

  static Future<File?> _make(_Job j) async {
    try {
      Directory(j.out.parent.path).createSync(recursive: true);
      // 👈 ffmpeg బదులు పక్కా HEIC కన్వర్టర్ 'heif-convert' వాడుతున్నాం
      final p = await Process.start('heif-convert', [
        '-q', '80', // 80% క్వాలిటీ (స్పీడ్ అండ్ క్లారిటీ పర్ఫెక్ట్ గా ఉంటుంది)
        j.item.path,
        j.out.path,
      ]);
      await p.exitCode.timeout(const Duration(seconds: 15), onTimeout: () { p.kill(); return -1; });
      if (j.out.existsSync() && j.out.lengthSync() > 0) return j.out;
    } catch (_) {}
    return null;
  }
}

// ─── Video Thumbs Cache Engine ───
class VideoThumbs {
  static const _maxParallel = 2;
  static int _active = 0;
  static bool _ffmpegMissing = false;
  static final _queue = Queue<_Job>();

  static Future<File?> get(GItem it, bool Function() cancelled) {
    final out = File('${cacheDir()}/thumbs/${_hash(it.path)}_${it.ms}.jpg');
    if (out.existsSync()) return Future.value(out);
    if (_ffmpegMissing) return Future.value(null);
    final j = _Job(it, out, cancelled);
    _queue.addLast(j);
    _pump();
    return j.done.future;
  }

  static void _pump() {
    while (_active < _maxParallel && _queue.isNotEmpty) {
      final j = _queue.removeLast();
      if (j.cancelled()) { j.done.complete(null); continue; }
      _active++;
      _make(j).then(j.done.complete).whenComplete(() { _active--; _pump(); });
    }
  }

  static Future<File?> _make(_Job j) async {
    try {
      Directory(j.out.parent.path).createSync(recursive: true);
      for (final ss in const ['1', '0']) {
        final p = await Process.start('ffmpeg', [
          '-hide_banner', '-loglevel', 'quiet', '-nostdin', '-y',
          '-ss', ss, '-i', j.item.path,
          '-frames:v', '1', '-vf', 'scale=360:-2', 
          '-threads', '1', '-q:v', '5', j.out.path,
        ]);
        await p.exitCode.timeout(const Duration(seconds: 15), onTimeout: () { p.kill(); return -1; });
        if (j.out.existsSync() && j.out.lengthSync() > 0) return j.out;
      }
    } on ProcessException { _ffmpegMissing = true; } catch (_) {}
    return null;
  }
}

// ════════════════════════════════════════════════════════════════════
//  MAIN + THEME
// ════════════════════════════════════════════════════════════════════
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 300
    ..maximumSizeBytes = 128 << 20;

  final sp = await SharedPreferences.getInstance();
  themeNotifier.value = sp.getString('theme_mode') == 'light' ? ThemeMode.light : ThemeMode.dark;
  runApp(const LinuxGalleryApp());
}

ThemeData _buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final cs = ColorScheme.fromSeed(seedColor: Colors.blueAccent, brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: dark ? const Color(0xFF0F111A) : const Color(0xFFF6F7FB),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF151824) : Colors.white,
      foregroundColor: cs.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerColor: dark ? Colors.white10 : Colors.black12,
  );
}

class LinuxGalleryApp extends StatelessWidget {
  const LinuxGalleryApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, mode, __) => MaterialApp(
        title: "Shiva's Gallery",
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        themeMode: mode,
        home: const GalleryScreen(),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  GALLERY SCREEN
// ════════════════════════════════════════════════════════════════════
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<String> _folders = [];
  Map<String, String> _uuids = {}; 
  Map<String, List<GItem>> _index = {}; 
  final Set<String> _offline = {};

  List<GItem> _flat = [];
  List<_Section> _secs = [];

  bool _loading = false, _scanning = false, _rescan = false;

  final _fast = ValueNotifier<bool>(false); 
  final _scroll = ScrollController();
  Timer? _fastTimer, _poll;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _fastTimer?.cancel();
    _poll?.cancel();
    _scroll.dispose();
    _fast.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final sp = await SharedPreferences.getInstance();
    _folders = sp.getStringList('gallery_folders') ?? [];
    try { _uuids = Map<String, String>.from(jsonDecode(sp.getString('folder_uuids') ?? '{}')); } catch (_) {}
    _index = await readIndex();
    for (final f in _folders) { if (!Directory(f).existsSync()) _offline.add(f); }
    if (!mounted) return;
    _rebuildView();
    _scanAll();
  }

  Future<void> _saveFolders() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('gallery_folders', _folders);
    await sp.setString('folder_uuids', jsonEncode(_uuids));
  }

  Future<void> _scanAll() async {
    if (_scanning) { _rescan = true; return; }
    _scanning = true;
    if (mounted) setState(() => _loading = true);

    final results = await Future.wait(_folders.map((f) async => MapEntry(f, await scanFolder(f))));
    for (final r in results) {
      final prev = _index[r.key];
      final list = r.value;
      if (list == null || (list.isEmpty && prev != null && prev.isNotEmpty)) {
        _offline.add(r.key); 
      } else {
        _offline.remove(r.key);
        _index[r.key] = list;
      }
    }
    _index.removeWhere((k, _) => !_folders.contains(k));
    _scanning = false;
    if (!mounted) return;

    _rebuildView();
    setState(() => _loading = false);
    unawaited(writeIndex(_index));
    _updatePoll();

    if (_rescan) { _rescan = false; _scanAll(); }
  }

  void _rebuildView() {
    final all = <GItem>[];
    for (final f in _folders) {
      if (_offline.contains(f)) continue;
      final l = _index[f];
      if (l != null) all.addAll(l);
    }
    all.sort((a, b) => b.ms.compareTo(a.ms));

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yday = today.subtract(const Duration(days: 1));
    final secs = <_Section>[];
    var lastId = -1, start = 0;
    var title = '';

    for (var i = 0; i < all.length; i++) {
      final d = DateTime.fromMillisecondsSinceEpoch(all[i].ms);
      final fd = DateTime(d.year, d.month, d.day);
      int id;
      if (fd == today) { id = 1; } 
      else if (fd == yday) { id = 2; } 
      else if (d.year == now.year) { id = 100000 + d.month * 100 + d.day; } 
      else { id = d.year * 100 + d.month; }
      
      if (id != lastId) {
        if (i > 0) secs.add(_Section(title, start, i));
        start = i; lastId = id;
        title = id == 1 ? 'ఈరోజు (Today)' : id == 2 ? 'నిన్న (Yesterday)' : d.year == now.year ? DateFormat('EEE, d MMM').format(d) : DateFormat('MMMM yyyy').format(d);
      }
    }
    if (all.isNotEmpty) secs.add(_Section(title, start, all.length));

    if (!mounted) return;
    setState(() { _flat = all; _secs = secs; });
  }

  void _updatePoll() {
    if (_offline.isEmpty) { _poll?.cancel(); _poll = null; return; }
    _poll ??= Timer.periodic(const Duration(seconds: 5), (_) {
      for (final f in _offline) {
        if (_alive(f)) { _scanAll(); break; }
      }
    });
  }

  bool _alive(String f) {
    try {
      final d = Directory(f);
      return d.existsSync() && d.listSync(followLinks: false).isNotEmpty;
    } catch (_) { return false; }
  }

  Future<String?> _uuidFor(String path) async {
    try {
      final src = await Process.run('findmnt', ['-n', '-o', 'SOURCE', '--target', path]);
      final dev = (src.stdout as String).trim().split('[').first;
      if (dev.startsWith('/dev/')) {
        final r = await Process.run('lsblk', ['-no', 'UUID', dev]);
        final u = (r.stdout as String).trim();
        if (u.isNotEmpty) return u;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _addFolder() async {
    final dir = await getDirectoryPath(initialDirectory: Platform.environment['HOME'] ?? '/home');
    if (dir == null || _folders.contains(dir)) return;
    setState(() => _folders.add(dir));
    final u = await _uuidFor(dir);
    if (u != null) _uuids[dir] = u;
    await _saveFolders();
    _scanAll();
  }

  Future<void> _removeFolder(String f) async {
    setState(() { _folders.remove(f); _offline.remove(f); _index.remove(f); _uuids.remove(f); });
    await _saveFolders();
    _rebuildView();
    unawaited(writeIndex(_index));
    _updatePoll();
  }

  Future<void> _mount(String folder) async {
    final uuid = _uuids[folder];
    if (uuid == null) {
      Process.run('xdg-open', [folder.substring(0, folder.lastIndexOf('/'))]);
      _snack('Drive UUID లేదు — ఫైల్ మేనేజర్ లో మౌంట్ చెయ్.');
      return;
    }
    _snack('Mounting…');
    try {
      final r = await Process.run('udisksctl', ['mount', '-b', '/dev/disk/by-uuid/$uuid']);
      final msg = ((r.stdout as String) + (r.stderr as String)).trim();
      _snack(msg.isEmpty ? 'Done' : msg);
    } catch (_) { _snack('udisksctl లేదు. Install: sudo apt install udisks2'); }
    await Future.delayed(const Duration(seconds: 1));
    _scanAll();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
  }

  Future<void> _toggleTheme() async {
    final next = themeNotifier.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    themeNotifier.value = next;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('theme_mode', next == ThemeMode.light ? 'light' : 'dark');
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification && (n.scrollDelta ?? 0).abs() > 140) {
      _fast.value = true;
      _fastTimer?.cancel();
      _fastTimer = Timer(const Duration(milliseconds: 120), () => _fast.value = false);
    }
    return false;
  }

  void _open(int index) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => FullscreenViewer(items: _flat, initialIndex: index)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text("Shiva's Gallery", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          Text('${_flat.length} items', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ]),
        actions: [
          if (_loading) const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          IconButton(tooltip: dark ? 'Light theme' : 'Dark theme', icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined), onPressed: _toggleTheme),
          IconButton(tooltip: 'Add Folder', icon: Icon(Icons.create_new_folder_outlined, color: cs.primary), onPressed: _addFolder),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _scanAll),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          Container(
            width: 250, color: dark ? const Color(0xFF121521) : const Color(0xFFECEEF5),
            child: ListView.builder(
              itemCount: _folders.length,
              itemBuilder: (ctx, i) {
                final folder = _folders[i];
                final off = _offline.contains(folder);
                return ListTile(
                  leading: Icon(off ? Icons.folder_off_rounded : Icons.folder_rounded, color: off ? Colors.redAccent : cs.primary),
                  title: Text(folder.split(Platform.pathSeparator).last, style: TextStyle(color: off ? cs.onSurface.withOpacity(0.5) : cs.onSurface, fontWeight: FontWeight.bold)),
                  subtitle: Text(off ? 'Disk disconnected — tap to mount' : folder, style: TextStyle(fontSize: 10, color: off ? Colors.redAccent : cs.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: off ? () => _mount(folder) : null,
                  trailing: IconButton(icon: Icon(Icons.remove_circle_outline, size: 18, color: cs.onSurfaceVariant), onPressed: () => _removeFolder(folder)),
                );
              },
            ),
          ),
          VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
          Expanded(
            child: _secs.isEmpty && !_loading
                ? Center(child: Text('No photos or videos found.', style: TextStyle(color: cs.onSurfaceVariant)))
                : NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: Scrollbar(
                      controller: _scroll,
                      child: CustomScrollView(
                        controller: _scroll,
                        cacheExtent: 200, // 👈 RAM Fix
                        slivers: [
                          for (final s in _secs) ...[
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                                child: Text(s.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: cs.onSurface)),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              sliver: SliverGrid(
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, crossAxisSpacing: 8, mainAxisSpacing: 8),
                                delegate: SliverChildBuilderDelegate(
                                  (context, i) {
                                    final idx = s.start + i;
                                    final it = _flat[idx];
                                    return it.isVideo
                                        ? VideoTile(key: ValueKey(it.path), item: it, fast: _fast, onTap: () => _open(idx))
                                        : (it.isHeic
                                            ? HeicTile(key: ValueKey(it.path), item: it, fast: _fast, onTap: () => _open(idx))
                                            : ImageTile(key: ValueKey(it.path), item: it, fast: _fast, onTap: () => _open(idx)));
                                  },
                                  childCount: s.end - s.start,
                                  addAutomaticKeepAlives: false,
                                ),
                              ),
                            ),
                          ],
                          const SliverToBoxAdapter(child: SizedBox(height: 40)),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  TILES
// ════════════════════════════════════════════════════════════════════
class ImageTile extends StatefulWidget {
  final GItem item;
  final ValueNotifier<bool> fast;
  final VoidCallback onTap;
  const ImageTile({super.key, required this.item, required this.fast, required this.onTap});
  @override
  State<ImageTile> createState() => _ImageTileState();
}
class _ImageTileState extends State<ImageTile> {
  late bool _show = !widget.fast.value;
  @override void initState() { super.initState(); widget.fast.addListener(_onFast); }
  void _onFast() { if (!_show && !widget.fast.value && mounted) setState(() => _show = true); }
  @override void dispose() { widget.fast.removeListener(_onFast); super.dispose(); }
  @override Widget build(BuildContext context) {
    final w = (200 * MediaQuery.devicePixelRatioOf(context)).round();
    return GestureDetector(
      onTap: widget.onTap,
      child: RepaintBoundary( // 👈 CPU Fix
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _show
              ? Image.file(File(widget.item.path), cacheWidth: w, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.none, errorBuilder: (_, __, ___) => ColoredBox(color: _placeholder(context), child: const Center(child: Icon(Icons.broken_image_outlined, size: 20))))
              : ColoredBox(color: _placeholder(context)),
        ),
      ),
    );
  }
}

// ─── కొత్త HEIC Tile ───
class HeicTile extends StatefulWidget {
  final GItem item;
  final ValueNotifier<bool> fast;
  final VoidCallback onTap;
  const HeicTile({super.key, required this.item, required this.fast, required this.onTap});
  @override
  State<HeicTile> createState() => _HeicTileState();
}
class _HeicTileState extends State<HeicTile> {
  File? _img;
  bool _requested = false, _disposed = false;
  @override void initState() { super.initState(); widget.fast.addListener(_load); _load(); }
  void _load() {
    if (_requested || widget.fast.value) return;
    _requested = true;
    HeicCache.get(widget.item, () => _disposed).then((f) { if (mounted && f != null) setState(() => _img = f); });
  }
  @override void dispose() { _disposed = true; widget.fast.removeListener(_load); super.dispose(); }
  @override Widget build(BuildContext context) {
    final w = (200 * MediaQuery.devicePixelRatioOf(context)).round();
    return GestureDetector(
      onTap: widget.onTap,
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _img != null
              ? Image.file(_img!, cacheWidth: w, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.none)
              : ColoredBox(color: _placeholder(context), child: const Center(child: Icon(Icons.image_outlined, size: 28))),
        ),
      ),
    );
  }
}

class VideoTile extends StatefulWidget {
  final GItem item;
  final ValueNotifier<bool> fast;
  final VoidCallback onTap;
  const VideoTile({super.key, required this.item, required this.fast, required this.onTap});
  @override
  State<VideoTile> createState() => _VideoTileState();
}
class _VideoTileState extends State<VideoTile> {
  File? _thumb;
  bool _requested = false, _hover = false, _disposed = false;
  Timer? _hoverTimer;
  @override void initState() { super.initState(); widget.fast.addListener(_load); _load(); }
  void _load() {
    if (_requested || widget.fast.value) return;
    _requested = true;
    VideoThumbs.get(widget.item, () => _disposed).then((f) { if (mounted && f != null) setState(() => _thumb = f); });
  }
  @override void dispose() { _disposed = true; _hoverTimer?.cancel(); widget.fast.removeListener(_load); super.dispose(); }
  @override Widget build(BuildContext context) {
    final w = (200 * MediaQuery.devicePixelRatioOf(context)).round();
    return MouseRegion(
      onEnter: (_) {
        _hoverTimer?.cancel();
        _hoverTimer = Timer(const Duration(milliseconds: 300), () { if (mounted && !widget.fast.value) setState(() => _hover = true); });
      },
      onExit: (_) {
        _hoverTimer?.cancel();
        if (_hover) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(fit: StackFit.expand, children: [
            _thumb != null ? Image.file(_thumb!, cacheWidth: w, fit: BoxFit.cover, gaplessPlayback: true) : ColoredBox(color: _placeholder(context), child: const Center(child: Icon(Icons.movie_outlined, size: 28))),
            if (_hover) _PreviewPlayer(path: widget.item.path),
            if (!_hover) const Positioned(right: 6, bottom: 6, child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 24, shadows: [Shadow(color: Colors.black54, blurRadius: 6)])),
          ]),
        ),
      ),
    );
  }
}

class _PreviewPlayer extends StatefulWidget {
  final String path;
  const _PreviewPlayer({required this.path});
  @override State<_PreviewPlayer> createState() => _PreviewPlayerState();
}
class _PreviewPlayerState extends State<_PreviewPlayer> {
  late final Player _player = Player(configuration: const PlayerConfiguration(bufferSize: 4 * 1024 * 1024));
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<Duration>? _sub;
  bool _seeking = false;
  @override void initState() {
    super.initState();
    _player.setVolume(0); _player.setPlaylistMode(PlaylistMode.single); _player.open(Media(widget.path));
    _sub = _player.stream.position.listen((p) {
      if (p.inSeconds >= 5 && !_seeking) { _seeking = true; _player.seek(Duration.zero); } else if (p.inSeconds < 4) { _seeking = false; }
    });
  }
  @override void dispose() { _sub?.cancel(); _player.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Video(controller: _controller, fit: BoxFit.cover, controls: NoVideoControls, fill: Colors.black);
}

// ════════════════════════════════════════════════════════════════════
//  FULLSCREEN VIEWER
// ════════════════════════════════════════════════════════════════════
class FullscreenViewer extends StatefulWidget {
  final List<GItem> items;
  final int initialIndex;
  const FullscreenViewer({super.key, required this.items, required this.initialIndex});
  @override
  State<FullscreenViewer> createState() => _FullscreenViewerState();
}

class _FullscreenViewerState extends State<FullscreenViewer> {
  late final PageController _page;
  late int _current;
  final FocusNode _focus = FocusNode();

  @override void initState() { super.initState(); _current = widget.initialIndex; _page = PageController(initialPage: _current); _focus.requestFocus(); }
  @override void dispose() { _page.dispose(); _focus.dispose(); super.dispose(); }

  void _prev() { if (_current > 0) _page.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut); }
  void _next() { if (_current < widget.items.length - 1) _page.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut); }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0; double size = bytes.toDouble();
    while (size > 1024 && i < suffixes.length - 1) { size /= 1024; i++; }
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }

  void _showMetadata(GItem it) {
    final stat = File(it.path).statSync();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(it.isVideo ? 'Video Info' : 'Photo Info', style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name: ${it.path.split(Platform.pathSeparator).last}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text('Size: ${_formatSize(stat.size)}'),
            const SizedBox(height: 6),
            Text('Date: ${DateFormat('d MMM yyyy, h:mm a').format(stat.modified)}'),
            const SizedBox(height: 6),
            Text('Path: ${it.path}', style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final fgColor = isDark ? Colors.white : Colors.black87;
    final gradientStart = isDark ? Colors.black87 : Colors.white.withOpacity(0.9);
    final gradientEnd = isDark ? Colors.black.withOpacity(0.0) : Colors.white.withOpacity(0.0); // 👈 Theme Shadow Fix
    final arrowBg = isDark ? Colors.black54 : Colors.white70;

    return Scaffold(
      backgroundColor: bgColor,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) { _prev(); return KeyEventResult.handled; } 
            else if (event.logicalKey == LogicalKeyboardKey.arrowRight) { _next(); return KeyEventResult.handled; } 
            else if (event.logicalKey == LogicalKeyboardKey.escape) { Navigator.pop(context); return KeyEventResult.handled; }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            PageView.builder(
              controller: _page,
              onPageChanged: (i) => setState(() => _current = i),
              itemCount: widget.items.length,
              itemBuilder: (context, index) {
                final it = widget.items[index];
                if (it.isVideo) return _VideoPage(key: ValueKey(it.path), path: it.path, active: index == _current);
                if (it.isHeic) return _HeicPage(key: ValueKey(it.path), item: it); // 👈 HEIC Fullscreen 
                
                return RepaintBoundary( // 👈 CPU Fix
                  child: InteractiveViewer(
                    minScale: 1.0, maxScale: 4.0,
                    child: Center(child: Image.file(File(it.path), cacheWidth: 1920, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.none)),
                  ),
                );
              },
            ),
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [gradientStart, gradientEnd])),
                child: Row(children: [
                  IconButton(icon: Icon(Icons.arrow_back_rounded, color: fgColor), onPressed: () => Navigator.pop(context)),
                  Expanded(child: Text('${_current + 1} / ${widget.items.length}', style: TextStyle(color: fgColor, fontSize: 16, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                  IconButton(tooltip: 'Info', icon: Icon(Icons.info_outline_rounded, color: fgColor), onPressed: () => _showMetadata(widget.items[_current])),
                ]),
              ),
            ),
            if (_current > 0)
              Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.all(16), child: FloatingActionButton(heroTag: 'prev', backgroundColor: arrowBg, elevation: 0, onPressed: _prev, child: Icon(Icons.arrow_back_ios_new_rounded, color: fgColor)))),
            if (_current < widget.items.length - 1)
              Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.all(16), child: FloatingActionButton(heroTag: 'next', backgroundColor: arrowBg, elevation: 0, onPressed: _next, child: Icon(Icons.arrow_forward_ios_rounded, color: fgColor)))),
          ],
        ),
      ),
    );
  }
}

// ─── HEIC Fullscreen Page ───
class _HeicPage extends StatefulWidget {
  final GItem item;
  const _HeicPage({super.key, required this.item});
  @override State<_HeicPage> createState() => _HeicPageState();
}
class _HeicPageState extends State<_HeicPage> {
  File? _img;
  bool _disposed = false;
  @override void initState() {
    super.initState();
    HeicCache.get(widget.item, () => _disposed).then((f) { if (mounted && f != null) setState(() => _img = f); });
  }
  @override void dispose() { _disposed = true; super.dispose(); }
  @override Widget build(BuildContext context) {
    return RepaintBoundary(
      child: InteractiveViewer(
        minScale: 1.0, maxScale: 4.0,
        child: Center(
          child: _img != null
              ? Image.file(_img!, cacheWidth: 1920, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.none)
              : const CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  final String path;
  final bool active;
  const _VideoPage({super.key, required this.path, required this.active});
  @override State<_VideoPage> createState() => _VideoPageState();
}
class _VideoPageState extends State<_VideoPage> {
  Player? _player; VideoController? _controller;
  @override void initState() { super.initState(); if (widget.active) _start(); }
  @override void didUpdateWidget(covariant _VideoPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) { setState(_start); } else if (!widget.active && old.active) { setState(_stop); }
  }
  void _start() { _player = Player(); _controller = VideoController(_player!); _player!.open(Media(widget.path)); }
  void _stop() { _player?.dispose(); _player = null; _controller = null; }
  @override void dispose() { _player?.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    if (_controller == null) return const ColoredBox(color: Colors.black);
    return Video(controller: _controller!);
  }
}