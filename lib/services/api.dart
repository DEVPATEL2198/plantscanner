import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Global API key to use across the app. Leave empty to use env/secure storage.
const String kGlobalGeminiApiKey = 'AIzaSyDwbFU59nghnDd2Db-h7Uwqaq7Erg2O888';

/// Mode of scanning – normal identification or disease diagnosis.
enum ScanMode { identify, diagnose }

/// Result of a plant scan using Gemini.
class PlantScanResult {
  final String? plantName;
  final String summary; // includes name + conditions in readable text
  final DateTime timestamp;
  final String? imagePath; // local file path of the scanned image
  final bool isFavorite;
  final List<String> tags;

  PlantScanResult({
    required this.plantName,
    required this.summary,
    required this.timestamp,
    this.imagePath,
    this.isFavorite = false,
    List<String>? tags,
  }) : tags = tags ?? const [];

  Map<String, dynamic> toJson() => {
    'plantName': plantName,
    'summary': summary,
    'timestamp': timestamp.toIso8601String(),
    'imagePath': imagePath,
    'isFavorite': isFavorite,
    'tags': tags,
  };

  factory PlantScanResult.fromJson(Map<String, dynamic> json) =>
      PlantScanResult(
        plantName: json['plantName'] as String?,
        summary: json['summary'] as String? ?? '',
        timestamp:
            DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
        imagePath: json['imagePath'] as String?,
        isFavorite: (json['isFavorite'] as bool?) ?? false,
        tags: (json['tags'] is List)
            ? (json['tags'] as List).whereType<String>().toList()
            : const [],
      );
}

/// Service wrapper around the Google Generative AI SDK for plant identification.
class GeminiService {
  final String apiKey;
  final GenerationConfig _generationConfig;
  // If no apiKey is provided, default to the global constant above.
  GeminiService({String? apiKey})
    : apiKey = apiKey ?? kGlobalGeminiApiKey,
      _generationConfig = GenerationConfig(
        temperature: 0.2, // lower = more deterministic
        topP: 0.9,
        topK: 40,
        candidateCount: 1,
      );

  Future<PlantScanResult> identifyPlant(
    List<int> imageBytes, {
    String? imagePath,
    String languageName = 'English', // ignored; always force English
    ScanMode mode = ScanMode.identify,
  }) async {
    final model = GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: apiKey,
      generationConfig: _generationConfig,
    );

    final prompt = mode == ScanMode.identify
        ? TextPart(
            'You are a plant identification assistant. Given an image of a plant, identify the most likely common name and scientific name. Then provide concise growing guidance.\n\n'
            'Respond fully in English (use only English in your wording).\n'
            'IMPORTANT: Keep the labels EXACTLY in English as specified below, and write all field VALUES (and Tips) in English.\n\n'
            'Respond in this exact labeled format (one field per line):\n'
            'Name: <common name in English> (<scientific name, Latin>)\n'
            'Light: <brief guidance in English>\n'
            'Water: <brief guidance in English>\n'
            'Soil: <brief guidance in English>\n'
            'Temperature: <brief guidance in English>\n'
            'Humidity: <optional, brief in English>\n'
            'Fertilizer: <optional, brief in English>\n'
            'Tips: <bullet-like short tips separated by semicolons in English>',
          )
        : TextPart(
            'You are a plant disease diagnosis assistant. Given an image of a plant, identify any likely diseases or issues (fungal, bacterial, pest, nutrient deficiency, environmental stress) and provide actionable treatment and prevention steps.\n\n'
            'Respond fully in English (use only English in your wording).\n'
            'IMPORTANT: Keep the labels EXACTLY in English as specified below, and write all field VALUES (and Tips) in English.\n\n'
            'Respond in this exact labeled format (one field per line):\n'
            'Disease: <likely disease or issue in English>\n'
            'Cause: <brief cause in English>\n'
            'Symptoms: <key visible symptoms in English>\n'
            'Severity: <low/medium/high in English>\n'
            'Treatment: <concise, safe treatment steps in English>\n'
            'Prevention: <concise prevention steps in English>\n'
            'Tips: <short bullet-like tips separated by semicolons in English>',
          );

    final content = Content.multi([
      prompt,
      DataPart('image/jpeg', Uint8List.fromList(imageBytes)),
    ]);

    final response = await model.generateContent([content]);
    final text = response.text?.trim() ?? 'No description available.';

    // Try to parse plant name from the first line if present (identify mode)
    String? plantName;
    if (mode == ScanMode.identify) {
      final lines = const LineSplitter().convert(text);
      final firstLine = lines.isNotEmpty ? lines.first : text;
      final nameMatch = RegExp(
        r'^Name:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(firstLine);
      if (nameMatch != null) {
        plantName = nameMatch.group(1)?.trim();
      }
    }

    return PlantScanResult(
      plantName: plantName,
      summary: text,
      timestamp: DateTime.now(),
      imagePath: imagePath,
    );
  }

  /// Translate an already generated summary into [languageName].
  /// Keeps the labels (Name, Light, Water, Soil, Temperature, Humidity, Fertilizer, Tips)
  /// in English while translating VALUES to the target language.
  Future<String> translateSummary(String summary, String languageName) async {
    final model = GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: apiKey,
      generationConfig: _generationConfig,
    );

    final instruction = TextPart(
      'Translate the following plant description into "$languageName".\n'
      'IMPORTANT:\n'
      '- Keep the labels EXACTLY in English: Name, Light, Water, Soil, Temperature, Humidity, Fertilizer, Tips, Disease, Cause, Symptoms, Severity, Treatment, Prevention.\n'
      '- Translate only the VALUES after the colon for each label.\n'
      '- Keep the overall format identical; one field per line; Tips separated by semicolons.\n'
      'Do not add commentary. Output only the translated text.',
    );

    final input = TextPart('<content>\n$summary\n</content>');
    final response = await model.generateContent([
      Content.text(instruction.text!),
      Content.text(input.text!),
    ]);
    return response.text?.trim() ?? summary;
  }
}

// Simple repository to persist and retrieve scan history locally.
class HistoryRepository {
  static const _prefsKey = 'scan_history_v1';

  List<PlantScanResult> items = [];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_prefsKey) ?? [];
    items = list
        .map(
          (e) =>
              PlantScanResult.fromJson(json.decode(e) as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = items.map((e) => json.encode(e.toJson())).toList();
    await prefs.setStringList(_prefsKey, list);
  }

  Future<void> add(PlantScanResult result) async {
    items.insert(0, result);
    await save();
  }

  Future<void> clear() async {
    items.clear();
    await save();
  }
}

// Secure storage for the Gemini API key.
class ApiKeyStorage {
  static const _key = 'gemini_api_key_v1';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<void> saveKey(String apiKey) async {
    await _storage.write(key: _key, value: apiKey);
  }

  Future<String?> readKey() async {
    return _storage.read(key: _key);
  }

  Future<void> deleteKey() async {
    await _storage.delete(key: _key);
  }
}
