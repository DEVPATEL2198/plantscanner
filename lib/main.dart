import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plantscanner/services/api.dart';

// Build-time injected API key (legacy constant; unused)
const String kEnvApiKey = String.fromEnvironment('GEMINI_KEY');

// Quick action the Home can request from the Scan page.
enum ScanIntent { gallery, camera }

// Persisted theme mode controller
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

// Persisted language selection
final ValueNotifier<String> languageNotifier = ValueNotifier<String>('English');

class LanguagePrefs {
  static const _key = 'language_v1';

  static Future<void> save(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, name);
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getString(_key);
    if (val != null && val.isNotEmpty) {
      languageNotifier.value = val;
    }
  }
}

class ThemePrefs {
  static const _key = 'theme_mode_v1';

  static Future<void> save(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  static Future<ThemeMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    return switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.system,
    };
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load saved theme preference before building the app
  themeModeNotifier.value = await ThemePrefs.load();
  // Load persisted language preference
  // LanguagePrefs.load(); // Disabled: always default to English on startup
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Plant Scanner',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.green,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: mode,
          home: const RootShell(),
        );
      },
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;
  final _historyRepo = HistoryRepository();
  // Scan tab removed; scans are initiated from Home.

  @override
  void initState() {
    super.initState();
    _historyRepo.load();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _HomePage(
        historyRepository: _historyRepo,
        onSeeAllHistory: () => setState(() => _index = 1),
      ),
      HistoryPage(historyRepository: _historyRepo),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plant Scanner'),
        actions: [
          // Language selection menu
          ValueListenableBuilder<String>(
            valueListenable: languageNotifier,
            builder: (context, lang, _) => PopupMenuButton<String>(
              tooltip: 'Language: $lang',
              onSelected: (value) async {
                languageNotifier.value = value;
                // await LanguagePrefs.save(value); // Disabled: do not persist language
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'English', child: Text('English')),
                PopupMenuItem(value: 'Hindi', child: Text('Hindi')),
                PopupMenuItem(value: 'Spanish', child: Text('Spanish')),
                PopupMenuItem(value: 'French', child: Text('French')),
                PopupMenuItem(value: 'German', child: Text('German')),
              ],
              icon: const Icon(Icons.translate),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Theme',
            onSelected: (value) async {
              switch (value) {
                case 'system':
                  themeModeNotifier.value = ThemeMode.system;
                  break;
                case 'light':
                  themeModeNotifier.value = ThemeMode.light;
                  break;
                case 'dark':
                  themeModeNotifier.value = ThemeMode.dark;
                  break;
              }
              await ThemePrefs.save(themeModeNotifier.value);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'system', child: Text('System Theme')),
              const PopupMenuItem(value: 'light', child: Text('Light Theme')),
              const PopupMenuItem(value: 'dark', child: Text('Dark Theme')),
            ],
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
        ],
      ),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage({
    required this.historyRepository,
    required this.onSeeAllHistory,
    super.key,
  });

  final HistoryRepository historyRepository;
  final VoidCallback onSeeAllHistory;

  @override
  State<_HomePage> createState() => __HomePageState();
}

class __HomePageState extends State<_HomePage> {
  late final PageController _pageController;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: 0.82);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _scanFromGallery() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (image == null) {
        setState(() => _busy = false);
        return;
      }
      final bytes = await image.readAsBytes();
      final service = GeminiService();
      final result = await service.identifyPlant(
        bytes,
        imagePath: image.path,
        languageName: languageNotifier.value,
      );
      await widget.historyRepository.add(result);
      if (!mounted) return;
      await _showResult(result);
      setState(() {});
    } catch (e) {
      setState(() => _error = e.toString());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_error ?? 'Scan failed')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanFromCamera() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        throw PlatformException(
          code: 'camera_permission_denied',
          message: 'Camera permission is required.',
        );
      }
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (image == null) {
        setState(() => _busy = false);
        return;
      }
      final bytes = await image.readAsBytes();
      final service = GeminiService();
      final result = await service.identifyPlant(
        bytes,
        imagePath: image.path,
        languageName: languageNotifier.value,
      );
      await widget.historyRepository.add(result);
      if (!mounted) return;
      await _showResult(result);
      setState(() {});
    } catch (e) {
      setState(() => _error = e.toString());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_error ?? 'Scan failed')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showResult(PlantScanResult result) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, controller) => _ResultView(
          result: result,
          scrollController: controller,
          onToggleFavorite: () {
            final idx = widget.historyRepository.items.indexWhere(
              (e) =>
                  e.timestamp == result.timestamp &&
                  e.imagePath == result.imagePath,
            );
            if (idx != -1) {
              final current = widget.historyRepository.items[idx];
              final updated = PlantScanResult(
                plantName: current.plantName,
                summary: current.summary,
                timestamp: current.timestamp,
                imagePath: current.imagePath,
                isFavorite: !current.isFavorite,
                tags: current.tags,
              );
              widget.historyRepository.items[idx] = updated;
              widget.historyRepository.save();
              setState(() {});
              return updated.isFavorite;
            }
            return result.isFavorite;
          },
          onTranslate: (newSummary) async {
            final idx = widget.historyRepository.items.indexWhere(
              (e) =>
                  e.timestamp == result.timestamp &&
                  e.imagePath == result.imagePath,
            );
            if (idx != -1) {
              final current = widget.historyRepository.items[idx];
              widget.historyRepository.items[idx] = PlantScanResult(
                plantName: current.plantName,
                summary: newSummary,
                timestamp: current.timestamp,
                imagePath: current.imagePath,
                isFavorite: current.isFavorite,
                tags: current.tags,
              );
              await widget.historyRepository.save();
              setState(() {});
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final latest = widget.historyRepository.items.isNotEmpty
        ? widget.historyRepository.items.first
        : null;
    final recent = widget.historyRepository.items.take(5).toList();

    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _HomeBackgroundPainter(
              primary: Theme.of(context).colorScheme.primary,
              secondary: Theme.of(context).colorScheme.secondary,
              surface: Theme.of(context).colorScheme.surface,
            ),
          ),
        ),
        ListView(
          padding: EdgeInsets.zero,
          children: [
            // Curved wave header with glowing orb
            SizedBox(
              height: 220,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _WaveHeaderPainter(
                        color: Theme.of(context).colorScheme.primary,
                        secondary: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ),
                  Positioned(
                    right: -30,
                    top: 20,
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.45),
                            Colors.transparent,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withOpacity(0.35),
                            blurRadius: 40,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    top: 36,
                    right: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Plant Scanner',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onPrimary,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Snap • Identify • Care',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimary.withOpacity(0.9),
                              ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _ActionPill(
                                label: 'Gallery',
                                icon: Icons.photo_library,
                                onTap: _scanFromGallery,
                                gradient: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.tertiaryContainer,
                                  Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _ActionPill(
                                label: 'Camera',
                                icon: Icons.photo_camera,
                                onTap: _scanFromCamera,
                                gradient: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.secondaryContainer,
                                  Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Latest result card (glass)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                'Latest result',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (latest != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _GlassCard(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(12),
                    leading: latest.imagePath != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              File(latest.imagePath!),
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            ),
                          )
                        : CircleAvatar(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            child: const Icon(Icons.local_florist),
                          ),
                    title: Text(latest.plantName ?? 'Unknown plant'),
                    subtitle: Text(
                      latest.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.expand_more),
                    onTap: () => _showResult(latest),
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('No scans yet. Try starting one above.'),
              ),

            // Stylized recent carousel
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    'Recent',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: widget.onSeeAllHistory,
                    child: const Text('See all'),
                  ),
                ],
              ),
            ),
            if (recent.isNotEmpty)
              SizedBox(
                height: 190,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: recent.length,
                  padEnds: false,
                  itemBuilder: (context, index) {
                    final item = recent[index];
                    final page =
                        _pageController.hasClients &&
                            _pageController.positions.isNotEmpty
                        ? _pageController.page ??
                              _pageController.initialPage.toDouble()
                        : _pageController.initialPage.toDouble();
                    final delta = (index - page).abs();
                    final scale = (1 - (delta * 0.12)).clamp(0.86, 1.0);
                    final opacity = (1 - (delta * 0.5)).clamp(0.3, 1.0);
                    return Opacity(
                      opacity: opacity,
                      child: Transform.scale(
                        scale: scale,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: GestureDetector(
                            onTap: () {
                              showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surface,
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(16),
                                  ),
                                ),
                                builder: (context) => DraggableScrollableSheet(
                                  expand: false,
                                  initialChildSize: 0.8,
                                  minChildSize: 0.4,
                                  maxChildSize: 0.95,
                                  builder: (context, controller) => _ResultView(
                                    result: item,
                                    scrollController: controller,
                                    onToggleFavorite: () {
                                      final current =
                                          widget.historyRepository.items[index];
                                      final updated = PlantScanResult(
                                        plantName: current.plantName,
                                        summary: current.summary,
                                        timestamp: current.timestamp,
                                        imagePath: current.imagePath,
                                        isFavorite: !current.isFavorite,
                                        tags: current.tags,
                                      );
                                      widget.historyRepository.items[index] =
                                          updated;
                                      widget.historyRepository.save();
                                      setState(() {});
                                      return updated.isFavorite;
                                    },
                                    onTranslate: (newSummary) async {
                                      final current =
                                          widget.historyRepository.items[index];
                                      widget.historyRepository.items[index] =
                                          PlantScanResult(
                                            plantName: current.plantName,
                                            summary: newSummary,
                                            timestamp: current.timestamp,
                                            imagePath: current.imagePath,
                                            isFavorite: current.isFavorite,
                                            tags: current.tags,
                                          );
                                      await widget.historyRepository.save();
                                      setState(() {});
                                    },
                                  ),
                                ),
                              );
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: item.imagePath != null
                                        ? Image.file(
                                            File(item.imagePath!),
                                            fit: BoxFit.cover,
                                          )
                                        : Container(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.surfaceVariant,
                                          ),
                                  ),
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.bottomCenter,
                                          end: Alignment.topCenter,
                                          colors: [
                                            Colors.black.withOpacity(0.6),
                                            Colors.transparent,
                                          ],
                                        ),
                                      ),
                                      child: Text(
                                        item.plantName ?? 'Unknown plant',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('No history yet'),
              ),

            const SizedBox(height: 24),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.gradient,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final List<Color> gradient;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.04,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(
              colors: gradient,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Transform.rotate(
            angle: 0.04,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveHeaderPainter extends CustomPainter {
  _WaveHeaderPainter({required this.color, required this.secondary});
  final Color color;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()..color = color.withOpacity(0.85);
    final accent = Paint()..color = secondary.withOpacity(0.35);

    final path1 = Path()
      ..lineTo(0, size.height * 0.55)
      ..quadraticBezierTo(
        size.width * 0.25,
        size.height * 0.70,
        size.width * 0.5,
        size.height * 0.58,
      )
      ..quadraticBezierTo(
        size.width * 0.8,
        size.height * 0.45,
        size.width,
        size.height * 0.62,
      )
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path1, base);

    final path2 = Path()
      ..lineTo(0, size.height * 0.40)
      ..quadraticBezierTo(
        size.width * 0.28,
        size.height * 0.55,
        size.width * 0.55,
        size.height * 0.44,
      )
      ..quadraticBezierTo(
        size.width * 0.82,
        size.height * 0.32,
        size.width,
        size.height * 0.46,
      )
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path2, accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({required this.historyRepository, super.key});

  final HistoryRepository historyRepository;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text('This will remove all saved scan results.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.historyRepository.clear();
      if (mounted) setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('History cleared')));
      }
    }
  }

  Future<void> _exportHistory() async {
    try {
      final items = widget.historyRepository.items;
      final jsonList = items.map((e) => e.toJson()).toList();
      final content = const JsonEncoder.withIndent('  ').convert(jsonList);
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/plant_history_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(content);
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'application/json'),
      ], text: 'Plant Scanner – exported history');
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          Row(
            children: [
              Text('History', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: widget.historyRepository.items.isEmpty
                    ? null
                    : _exportHistory,
                icon: const Icon(Icons.ios_share),
                label: const Text('Export'),
              ),
              TextButton.icon(
                onPressed: widget.historyRepository.items.isEmpty
                    ? null
                    : _confirmClearAll,
                icon: const Icon(Icons.delete_sweep),
                label: const Text('Clear all'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _HistoryList(
              historyRepository: widget.historyRepository,
              onChanged: () => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.historyRepository, this.onChanged});

  final HistoryRepository historyRepository;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final items = historyRepository.items;
    if (items.isEmpty) {
      return const Center(child: Text('No history yet'));
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final item = items[index];
        return Dismissible(
          key: ValueKey(
            '${item.timestamp.toIso8601String()}_${item.imagePath ?? ''}',
          ),
          direction: DismissDirection.endToStart,
          background: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Icon(
              Icons.delete,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          onDismissed: (dir) async {
            final removed = item;
            final removedIndex = index;
            historyRepository.items.removeAt(index);
            await historyRepository.save();
            onChanged?.call();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Deleted from history'),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () async {
                    historyRepository.items.insert(removedIndex, removed);
                    await historyRepository.save();
                    onChanged?.call();
                  },
                ),
              ),
            );
          },
          child: Card(
            child: ListTile(
              leading: item.imagePath != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(item.imagePath!),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      ),
                    )
                  : const Icon(Icons.local_florist),
              title: Text(item.plantName ?? 'Unknown plant'),
              subtitle: Text(
                item.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(item.timestamp),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: item.isFavorite ? 'Unfavorite' : 'Favorite',
                    icon: Icon(
                      item.isFavorite ? Icons.star : Icons.star_border,
                      color: item.isFavorite
                          ? Theme.of(context).colorScheme.tertiary
                          : null,
                    ),
                    onPressed: () async {
                      final updated = PlantScanResult(
                        plantName: item.plantName,
                        summary: item.summary,
                        timestamp: item.timestamp,
                        imagePath: item.imagePath,
                        isFavorite: !item.isFavorite,
                        tags: item.tags,
                      );
                      historyRepository.items[index] = updated;
                      await historyRepository.save();
                      onChanged?.call();
                    },
                  ),
                ],
              ),
              onTap: () {
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  builder: (context) => DraggableScrollableSheet(
                    expand: false,
                    initialChildSize: 0.8,
                    minChildSize: 0.4,
                    maxChildSize: 0.95,
                    builder: (context, controller) => _ResultView(
                      result: item,
                      scrollController: controller,
                      onToggleFavorite: () {
                        final current = historyRepository.items[index];
                        final updated = PlantScanResult(
                          plantName: current.plantName,
                          summary: current.summary,
                          timestamp: current.timestamp,
                          imagePath: current.imagePath,
                          isFavorite: !current.isFavorite,
                          tags: current.tags,
                        );
                        historyRepository.items[index] = updated;
                        historyRepository.save();
                        onChanged?.call();
                        return updated.isFavorite;
                      },
                      onTranslate: (newSummary) async {
                        final current = historyRepository.items[index];
                        historyRepository.items[index] = PlantScanResult(
                          plantName: current.plantName,
                          summary: newSummary,
                          timestamp: current.timestamp,
                          imagePath: current.imagePath,
                          isFavorite: current.isFavorite,
                          tags: current.tags,
                        );
                        await historyRepository.save();
                        onChanged?.call();
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

class _ResultView extends StatefulWidget {
  const _ResultView({
    required this.result,
    required this.scrollController,
    this.onToggleFavorite,
    this.onTranslate,
  });

  final PlantScanResult result;
  final ScrollController scrollController;
  final bool Function()? onToggleFavorite;
  final Future<void> Function(String newSummary)? onTranslate;

  @override
  State<_ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<_ResultView> {
  late bool _fav;
  late String _summary; // locally updated (e.g., after translate)
  bool _translating = false;

  @override
  void initState() {
    super.initState();
    _fav = widget.result.isFavorite;
    _summary = widget.result.summary;
  }

  Map<String, String> _parseFields(String summary) {
    final map = <String, String>{};
    for (final raw in const LineSplitter().convert(summary)) {
      final line = raw.trim();
      final idx = line.indexOf(':');
      if (idx > 0) {
        final key = line.substring(0, idx).trim();
        final value = line.substring(idx + 1).trim();
        if (key.isNotEmpty && value.isNotEmpty) {
          map[key] = value;
        }
      }
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final fields = _parseFields(_summary);
    final title = widget.result.plantName ?? fields['Name'] ?? 'Scan Result';
    final chips = <Widget>[];
    for (final key in [
      'Light',
      'Water',
      'Soil',
      'Temperature',
      'Humidity',
      'Fertilizer',
    ]) {
      final v = fields[key];
      if (v != null && v.isNotEmpty) {
        chips.add(
          Chip(
            label: Text('$key: $v'),
            avatar: Icon(
              key == 'Light'
                  ? Icons.wb_sunny
                  : key == 'Water'
                  ? Icons.water_drop
                  : key == 'Soil'
                  ? Icons.grass
                  : key == 'Temperature'
                  ? Icons.thermostat
                  : key == 'Humidity'
                  ? Icons.invert_colors
                  : Icons.local_florist,
            ),
          ),
        );
      }
    }

    final tips = fields['Tips'];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: ListView(
          controller: widget.scrollController,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ValueListenableBuilder<String>(
                  valueListenable: languageNotifier,
                  builder: (context, lang, _) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      lang,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _translating
                      ? 'Translating…'
                      : 'Translate to ${languageNotifier.value}',
                  icon: _translating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.translate),
                  onPressed: _translating
                      ? null
                      : () async {
                          try {
                            setState(() => _translating = true);
                            final svc = GeminiService();
                            final newSummary = await svc.translateSummary(
                              _summary,
                              languageNotifier.value,
                            );
                            // Persist change via callback if provided
                            if (widget.onTranslate != null) {
                              await widget.onTranslate!(newSummary);
                            }
                            setState(() => _summary = newSummary);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Translated to ${languageNotifier.value}',
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Translate failed: $e')),
                              );
                            }
                          } finally {
                            if (mounted) setState(() => _translating = false);
                          }
                        },
                ),
                IconButton(
                  tooltip: 'Share',
                  icon: const Icon(Icons.ios_share),
                  onPressed: () async {
                    try {
                      final buffer = StringBuffer();
                      buffer.writeln(title);
                      for (final k in [
                        'Light',
                        'Water',
                        'Soil',
                        'Temperature',
                        'Humidity',
                        'Fertilizer',
                      ]) {
                        final v = fields[k];
                        if (v != null && v.isNotEmpty) buffer.writeln('$k: $v');
                      }
                      if (tips != null && tips.isNotEmpty) {
                        buffer.writeln('\nTips:');
                        for (final part in tips.split(';')) {
                          final t = part.trim();
                          if (t.isNotEmpty) buffer.writeln('- $t');
                        }
                      }
                      final text = buffer.toString().trim();

                      final imagePath = widget.result.imagePath;
                      if (imagePath != null && await File(imagePath).exists()) {
                        await Share.shareXFiles([XFile(imagePath)], text: text);
                      } else {
                        await Share.share(text);
                      }
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Share failed: $e')),
                      );
                    }
                  },
                ),
                IconButton(
                  tooltip: _fav ? 'Unfavorite' : 'Favorite',
                  icon: Icon(
                    _fav ? Icons.star : Icons.star_border,
                    color: _fav ? Theme.of(context).colorScheme.tertiary : null,
                  ),
                  onPressed: () {
                    if (widget.onToggleFavorite != null) {
                      final newVal = widget.onToggleFavorite!();
                      setState(() => _fav = newVal);
                    }
                  },
                ),
                Text(
                  _formatTime(widget.result.timestamp),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.result.imagePath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(widget.result.imagePath!),
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
            const SizedBox(height: 12),
            if (tips != null && tips.isNotEmpty) ...[
              Text('Tips', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              _TipsList(text: tips),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Full description'),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        _summary,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _summary));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Description copied')),
                          );
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.check),
              label: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

class _TipsList extends StatelessWidget {
  const _TipsList({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    // Tips are semicolon-separated per prompt
    final parts = text
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in parts)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• '),
              Expanded(child: Text(p)),
            ],
          ),
      ],
    );
  }
}

class _HomeBackgroundPainter extends CustomPainter {
  _HomeBackgroundPainter({
    required this.primary,
    required this.secondary,
    required this.surface,
  });
  final Color primary;
  final Color secondary;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    // Soft vertical gradient base
    final rect = Offset.zero & size;
    final gradient = ui.Gradient.linear(Offset(0, 0), Offset(0, size.height), [
      surface,
      surface.withOpacity(0.98),
      surface.withOpacity(0.96),
    ]);
    final bg = Paint()..shader = gradient;
    canvas.drawRect(rect, bg);

    // Organic blobs
    final blob1 = Paint()..color = primary.withOpacity(0.06);
    final blob2 = Paint()..color = secondary.withOpacity(0.05);
    final blob3 = Paint()..color = primary.withOpacity(0.04);

    canvas.drawCircle(
      Offset(size.width * 0.15, size.height * 0.35),
      120,
      blob1,
    );
    canvas.drawCircle(
      Offset(size.width * 0.85, size.height * 0.55),
      140,
      blob2,
    );
    canvas.drawCircle(
      Offset(size.width * 0.40, size.height * 0.85),
      160,
      blob3,
    );

    // Subtle diagonal wave
    final wave = Paint()..color = primary.withOpacity(0.03);
    final path = Path()
      ..moveTo(0, size.height * 0.72)
      ..quadraticBezierTo(
        size.width * 0.35,
        size.height * 0.66,
        size.width * 0.7,
        size.height * 0.58,
      )
      ..quadraticBezierTo(
        size.width * 0.9,
        size.height * 0.85,
        size.width,
        size.height * 0.80,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, wave);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Theme.of(context).colorScheme.surface.withOpacity(0.6),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outlineVariant.withOpacity(0.3),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

