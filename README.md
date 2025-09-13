# Plant Scanner

Snap a photo or pick from gallery to identify plants or diagnose plant issues using Google Gemini. Get concise care guidance, translate results to your preferred language, and keep a searchable history.

## Features
- Identify plants or diagnose issues from photos with Google Gemini (model: gemini-1.5-flash).
- Camera and gallery import with runtime permission handling.
- Clear, labeled results:
  - Name, Light, Water, Soil, Temperature, Humidity, Fertilizer, Tips (Identify)
  - Disease, Cause, Symptoms, Severity, Treatment, Prevention, Tips (Diagnose)
- One-tap translation of results into selected UI language (English, Hindi, Spanish, French, German).
- Local scan history with favorites and JSON export.
- Share results via system share sheet.
- Material 3 UI with animated header, glass cards, recent carousel, and persistent system/light/dark theme.

## Screens & Flows
- Home: Start a scan from Gallery or Camera; view latest result and a recent carousel.
- Result sheet: View details, toggle favorite, translate, and share.
- History: Browse all results, clear all, export JSON.

## Tech Stack
- Flutter (Material 3)
- google_generative_ai
- image_picker, permission_handler
- shared_preferences, flutter_secure_storage
- path_provider, share_plus

## Setup
1. Requirements
   - Flutter SDK 3.8+ (see `pubspec.yaml` env `sdk: ^3.8.1`)
   - iOS/Android/Web/desktop toolchains as needed

2. Install
   - `flutter pub get`
   - `flutter run`

3. Google Gemini API key
   - Default: `kGlobalGeminiApiKey` in `lib/services/api.dart` (for development only).
   - Recommended: remove any hardcoded key before publishing and store it securely, e.g. using `ApiKeyStorage` (flutter_secure_storage) or build-time config.

## Permissions
- Android (`android/app/src/main/AndroidManifest.xml`)
  - Camera, Read Media Images, Internet
- iOS (`ios/Runner/Info.plist`)
  - NSCameraUsageDescription, NSPhotoLibraryUsageDescription, NSPhotoLibraryAddUsageDescription

## App Structure
- `lib/main.dart`
  - `MyApp`, `RootShell`: app scaffolding and navigation (Home, History)
  - Home page: animated header, quick actions (Gallery, Camera), latest result, recent carousel
  - History page: list, clear all, export JSON
- `lib/services/api.dart`
  - `GeminiService`: calls Google Gemini to identify/diagnose; supports translation
  - `PlantScanResult`: result model with JSON serialization
  - `HistoryRepository`: persists history in `shared_preferences`
  - `ApiKeyStorage`: secure key storage helper

## Security Note
Do not commit real API keys. Replace the hardcoded `kGlobalGeminiApiKey` with a secure solution before releasing publicly.

## License
Add your preferred license here.
