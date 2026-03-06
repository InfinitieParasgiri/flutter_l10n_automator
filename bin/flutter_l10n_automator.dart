#!/usr/bin/env dart

import 'dart:io';
import 'dart:convert';
import 'package:args/args.dart';
import 'package:path/path.dart' as path;

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('dry-run',
        abbr: 'd', negatable: false, help: 'Preview changes without modifying files')
    ..addOption('arb-dir',
        defaultsTo: 'lib/l10n', help: 'Directory containing .arb files')
    ..addOption('import-path',
        defaultsTo: 'l10n/app_localizations.dart',
        help: 'Absolute import path for AppLocalizations (from lib/)')
    ..addOption('path',
        abbr: 'p', help: 'Specific file or directory to process')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');

  try {
    final results = parser.parse(arguments);
    if (results['help'] as bool) {
      _printHelp(parser);
      return;
    }

    final automator = L10nAutomator(
      projectRoot: Directory.current.path,
      arbDir: results['arb-dir'] as String,
      importPath: results['import-path'] as String,
      dryRun: results['dry-run'] as bool,
      specificPath: results['path'] as String?,
    );

    await automator.run();
  } catch (e) {
    print('Error: $e');
    _printHelp(parser);
    exit(1);
  }
}

void _printHelp(ArgParser parser) {
  print('Flutter L10n Automator - Automatic localization tool\n');
  print('Usage: dart run flutter_l10n_automator [options]\n');
  print('Options:');
  print(parser.usage);
}

// ─────────────────────────────────────────────────────────────────────────────
// Main automator class
// ─────────────────────────────────────────────────────────────────────────────

class L10nAutomator {
  final String projectRoot;
  final String arbDir;
  final String importPath;   // e.g. "l10n/app_localizations.dart" (from lib/)
  final bool dryRun;
  final String? specificPath;

  // key → value  (already in arb file)
  final Map<String, String> existingKeys = {};
  // value → key  (reverse lookup to reuse existing keys)
  final Map<String, String> existingValues = {};
  // NEW entries discovered this run
  final Map<String, String> newEntries = {};
  // VALIDATION 5 — duplicate values in arb: value → list of keys that share it
  final Map<String, List<String>> arbDuplicates = {};
  // VALIDATION 5 — keys removed from arb as duplicates (kept key → removed keys)
  final Map<String, List<String>> removedDuplicateKeys = {};

  L10nAutomator({
    required this.projectRoot,
    required this.arbDir,
    required this.importPath,
    required this.dryRun,
    this.specificPath,
  });

  // ── entry point ────────────────────────────────────────────────────────────

  Future<void> run() async {
    print('🚀 Flutter L10n Automation Tool\n${'=' * 50}');

    await _createBackup();

    final arbFile = File(path.join(projectRoot, arbDir, 'app_en.arb'));
    if (!await arbFile.exists()) {
      print('❌ Error: app_en.arb not found at ${arbFile.path}');
      exit(1);
    }

    print('📁 ARB file: ${path.relative(arbFile.path, from: projectRoot)}\n');
    await _loadExistingArb(arbFile);
    print('📚 Loaded ${existingKeys.length} existing keys\n');

    // VALIDATION 5 — deduplicate arb BEFORE scanning so reverse map is clean
    await _deduplicateArbFile(arbFile);

    print('🔍 Scanning Flutter project for hardcoded strings...\n');

    // VALIDATION 5 — replace any hardcoded strings that already exist in arb
    await _applyExistingArbToProject();

    final scanResults = await _scanProject();

    if (scanResults.isEmpty) {
      print('\n✨ No hardcoded strings found! Your project is already localized.');
      return;
    }

    print('\n${'=' * 50}');
    final totalStrings = scanResults.values.fold(0, (s, l) => s + l.length);
    print('📊 Found $totalStrings strings in ${scanResults.length} files\n');
    print('🔧 Processing strings...\n');

    for (final entry in scanResults.entries) {
      final dartFile = entry.key;
      final strings = entry.value;
      final replacements = <StringReplacement>[];

      for (final info in strings) {
        // VALIDATION 2 — reuse existing arb value if already present
        if (existingValues.containsKey(info.text)) {
          final key = existingValues[info.text]!;
          print('   ♻️  Reuse: $key → "${_truncate(info.text, 50)}"');
          replacements.add(StringReplacement(text: info.text, originalMatch: info.originalMatch, key: key));
        } else {
          final key = _generateKey(info.text);
          newEntries[key] = info.text;
          print('   ➕ New:   $key → "${_truncate(info.text, 50)}"');
          replacements.add(StringReplacement(text: info.text, originalMatch: info.originalMatch, key: key));
        }
      }

      if (replacements.isNotEmpty) {
        await _replaceStringsInFile(dartFile, replacements);
      }
    }

    print('\n${'=' * 50}');
    if (newEntries.isNotEmpty) {
      await _updateArbFile(arbFile);
    }

    if (!dryRun) {
      print('\n${'=' * 50}');
      print('🎨 Running flutter gen-l10n...\n');
      await _runFlutterGenL10n();
    }

    print('\n${'=' * 50}\n📈 SUMMARY');
    print('   • Files processed       : ${scanResults.length}');
    print('   • New keys added        : ${newEntries.length}');
    print('   • ARB duplicates removed: ${removedDuplicateKeys.values.fold(0, (s, l) => s + l.length)}');
    print('   • Total arb keys        : ${existingKeys.length + newEntries.length}');
    print('${'=' * 50}\n✨ Done!\n');
  }

  // ── ARB loading ────────────────────────────────────────────────────────────

  Future<void> _loadExistingArb(File arbFile) async {
    final data = jsonDecode(await arbFile.readAsString()) as Map<String, dynamic>;

    // Track all keys per value to detect duplicates
    final valueToKeys = <String, List<String>>{};

    for (final e in data.entries) {
      if (!e.key.startsWith('@')) {
        existingKeys[e.key] = e.value.toString();
        valueToKeys.putIfAbsent(e.value.toString(), () => []).add(e.key);
      }
    }

    // Build reverse map — pick the BEST canonical key for each value.
    // Prefer the key whose text most closely matches the value words,
    // avoiding obvious typos. Falls back to shortest key.
    for (final e in valueToKeys.entries) {
      final keys = e.value;
      final canonical = keys.length == 1 ? keys.first : _pickBestKey(keys, e.key);
      existingValues[e.key] = canonical;
      if (keys.length > 1) {
        final others = keys.where((k) => k != canonical).toList();
        arbDuplicates[e.key] = [canonical, ...others];
      }
    }
  }

  /// Picks the best ARB key from [keys] for a given [value].
  /// Scores each key by how many characters it shares with the
  /// expected key (derived from value). Prefers higher score, then shorter key.
  String _pickBestKey(List<String> keys, String value) {
    final expected = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '');

    int score(String key) {
      final k = key.toLowerCase().replaceAll('_', '');
      int matches = 0;
      final minLen = k.length < expected.length ? k.length : expected.length;
      for (int i = 0; i < minLen; i++) {
        if (k[i] == expected[i]) matches++;
      }
      return matches;
    }

    return keys.reduce((a, b) {
      final sa = score(a), sb = score(b);
      if (sa != sb) return sa > sb ? a : b;
      return a.length <= b.length ? a : b; // prefer shorter on tie
    });
  }

  // ── VALIDATION 5a — remove duplicate values from arb file ─────────────────
  // Keeps the FIRST key for each value, removes the rest, and rewrites all
  // dart files that used the removed keys to point at the canonical key.

  Future<void> _deduplicateArbFile(File arbFile) async {
    if (arbDuplicates.isEmpty) {
      print('✅ ARB file has no duplicate values\n');
      return;
    }

    print('🧹 Found ${arbDuplicates.length} duplicate value(s) in ARB — cleaning up...');

    for (final e in arbDuplicates.entries) {
      final value      = e.key;
      final allKeys    = e.value;           // [canonical, dup1, dup2, ...]
      final canonical  = allKeys.first;
      final dupeKeys   = allKeys.sublist(1);

      removedDuplicateKeys[canonical] = dupeKeys;

      print('   🔁 "$value"');
      print('      Keep    : $canonical');
      print('      Remove  : ${dupeKeys.join(', ')}');

      // Rewrite dart files that reference the duplicate keys
      await _replaceKeysInProject(dupeKeys, canonical);
    }

    // Rewrite arb without the duplicate keys
    await _backupFile(arbFile);
    final data = jsonDecode(await arbFile.readAsString()) as Map<String, dynamic>;

    for (final dupes in removedDuplicateKeys.values) {
      for (final dk in dupes) {
        data.remove(dk);
        data.remove('@$dk'); // also remove metadata entry if present
        existingKeys.remove(dk);
      }
    }

    if (!dryRun) {
      await arbFile.writeAsString(JsonEncoder.withIndent('  ').convert(data));
      final totalRemoved = removedDuplicateKeys.values.fold(0, (s, l) => s + l.length);
      print('✅ Removed $totalRemoved duplicate key(s) from ${path.basename(arbFile.path)}\n');
    } else {
      print('🔍 [DRY RUN] Would remove duplicate keys from ARB\n');
    }
  }

  /// Replace all usages of [oldKeys] with [newKey] across all dart files.
  Future<void> _replaceKeysInProject(List<String> oldKeys, String newKey) async {
    final libDir = Directory(path.join(projectRoot, 'lib'));
    await for (final entity in libDir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      var content = await entity.readAsString();
      var changed = false;

      for (final old in oldKeys) {
        // Match l10n!.oldKey  l10n?.oldKey  l10n.oldKey  AppLocalizations.of(ctx).oldKey
        final pattern = RegExp(r'(\b\w+[!?]?\.)' + RegExp.escape(old) + r'\b');
        if (pattern.hasMatch(content)) {
          content = content.replaceAllMapped(pattern, (m) => '${m.group(1)}$newKey');
          changed = true;
        }
      }

      if (changed) {
        if (!dryRun) {
          await _backupFile(entity);
          await entity.writeAsString(content);
          print('      ✅ Updated refs in: ${path.relative(entity.path, from: projectRoot)}');
        } else {
          print('      🔍 [DRY RUN] Would update: ${path.relative(entity.path, from: projectRoot)}');
        }
      }
    }
  }

  // Strings already applied from ARB — normal scan must skip these
  final Set<String> _appliedStrings = {};

  // ── VALIDATION 5b — apply existing arb keys directly into dart UI files ───
  // Scans all dart files for hardcoded strings that ALREADY exist in the arb,
  // and replaces them with the l10n reference — without adding any new keys.

  Future<void> _applyExistingArbToProject() async {
    if (existingKeys.isEmpty) return;

    print('🔗 Applying ${existingKeys.length} existing ARB keys to UI files...\n');

    final libDir = Directory(path.join(projectRoot, 'lib'));
    int filesUpdated = 0;

    await for (final entity in libDir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      var content = await entity.readAsString();
      final originalContent = content;
      final replacements = <StringReplacement>[];

      for (final entry in existingKeys.entries) {
        final key   = entry.key;
        final value = entry.value;

        if (value.length < 3) continue;
        if (_shouldSkipString(value)) continue;

        // Look for this exact string hardcoded in the file (single or double quotes)
        final escaped = RegExp.escape(value);
        final pattern = RegExp('''['"](${escaped})['"]\s*[,\\)]''');

        for (final match in pattern.allMatches(content)) {
          final fullMatch = match.group(0)!;

          // Skip if context is already localized
          final ctxStart = (match.start - 100).clamp(0, content.length);
          final ctxEnd   = (match.end + 100).clamp(0, content.length);
          final ctx = content.substring(ctxStart, ctxEnd);

          if (ctx.contains('AppLocalizations') ||
              ctx.contains('l10n!.')           ||
              ctx.contains('l10n?.')           ||
              ctx.contains('l10n.')            ||
              ctx.contains(r'${'))             continue;

          replacements.add(StringReplacement(
            text: value,
            originalMatch: fullMatch,
            key: key,
          ));
        }
      }

      if (replacements.isEmpty) continue;

      // Detect or default var name
      final existingVarMatch =
          RegExp(r'final\s+(\w+)\s*=\s*AppLocalizations\.of\(context\)\s*;')
              .firstMatch(content);
      final varName = existingVarMatch?.group(1) ?? 'l10n';

      // Apply replacements
      for (final r in replacements) {
        final localized = '$varName!.${r.key}';
        final newMatch  = r.originalMatch
            .replaceAll('"${r.text}"', localized)
            .replaceAll("'${r.text}'", localized);
        content = content.replaceAll(r.originalMatch, newMatch);
        _appliedStrings.add(r.text); // ← mark as handled so scan skips it
        print('   🔗 ${path.relative(entity.path, from: projectRoot)}: "${_truncate(r.text, 45)}" → $varName!.${r.key}');
      }

      if (content == originalContent) continue;

      // Inject l10n declaration into build methods if needed
      final buildPattern = RegExp(r'Widget\s+build\s*\(\s*BuildContext\s+context\s*\)\s*\{');
      for (final match in buildPattern.allMatches(content).toList().reversed) {
        final methodEnd  = _findMatchingBrace(content, match.end - 1);
        final methodBody = content.substring(match.start, methodEnd);
        final hasDecl    = RegExp(r'final\s+\w+\s*=\s*AppLocalizations\.of\(context\)\s*;')
            .hasMatch(methodBody);
        if (hasDecl) continue;

        var insertPos = match.end;
        while (insertPos < content.length && ' \n\t'.contains(content[insertPos])) {
          insertPos++;
        }
        final decl = '\n    final $varName = AppLocalizations.of(context);\n';
        content = content.substring(0, insertPos) + decl + content.substring(insertPos);
      }

      // Add import if missing
      if (!content.contains('app_localizations.dart')) {
        final relImport       = _resolveImportPath(entity);
        final importStatement = "import '$relImport';\n";
        final lastImport      = RegExp(r'^import\s+[^\n]+;$', multiLine: true)
            .allMatches(content).lastOrNull;

        if (lastImport != null) {
          content = content.substring(0, lastImport.end) +
              '\n$importStatement' +
              content.substring(lastImport.end);
        } else {
          content = '$importStatement\n$content';
        }
      }

      if (!dryRun) {
        await _backupFile(entity);
        await entity.writeAsString(content);
        filesUpdated++;
      } else {
        print('🔍 [DRY RUN] Would apply existing keys to: ${path.relative(entity.path, from: projectRoot)}');
        filesUpdated++;
      }
    }

    print('\n✅ Applied existing ARB keys to $filesUpdated file(s)\n');
  }

  // ── project scanning ───────────────────────────────────────────────────────

  Future<Map<File, List<StringInfo>>> _scanProject() async {
    final results = <File, List<StringInfo>>{};

    if (specificPath != null) {
      final targetPath = path.join(projectRoot, specificPath!);
      final type = FileSystemEntity.typeSync(targetPath);

      if (type == FileSystemEntityType.notFound) {
        print('❌ Path not found: $specificPath');
        return results;
      }

      if (type == FileSystemEntityType.file) {
        final file = File(targetPath);
        if (file.path.endsWith('.dart')) {
          final strings = await _extractStrings(file);
          if (strings.isNotEmpty) results[file] = strings;
        }
        return results;
      }

      await _scanDirectory(Directory(targetPath), results);
      return results;
    }

    await _scanDirectory(Directory(path.join(projectRoot, 'lib')), results);
    return results;
  }

  Future<void> _scanDirectory(Directory dir, Map<File, List<StringInfo>> results) async {
    const skipPatterns = [
      // models
      '_model.dart', 'model.dart', '_models.dart', 'models.dart',
      // bloc / cubit / state / event
      '_bloc.dart', 'bloc.dart', '_cubit.dart', 'cubit.dart',
      '_state.dart', 'state.dart', '_event.dart', 'event.dart',
      // data layer
      '_provider.dart', 'provider.dart',
      '_repository.dart', 'repository.dart',
      '_service.dart', 'service.dart',
      '_api.dart', 'api.dart',
      // generated
      '.g.dart', '.freezed.dart', 'generated',
      // misc non-UI
      '_response.dart', 'response.dart',
      '_request.dart',  'request.dart',
      '_dto.dart',      'dto.dart',
      '_entity.dart',   'entity.dart',
    ];

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lp = entity.path.toLowerCase();
      if (skipPatterns.any((p) => lp.contains(p))) continue;

      final strings = await _extractStrings(entity);
      if (strings.isNotEmpty) {
        results[entity] = strings;
        print('📄 ${path.relative(entity.path, from: projectRoot)}: ${strings.length} strings');
      }
    }
  }

  // ── string extraction ──────────────────────────────────────────────────────

  Future<List<StringInfo>> _extractStrings(File dartFile) async {
    final content = await dartFile.readAsString();
    final found = <StringInfo>[];
    final seen = <String>{};

    // VALIDATION 4 — skip files that are already heavily localized
    final l10nCallCount = 'AppLocalizations.of(context)'.allMatches(content).length;
    if (l10nCallCount > 10) return found;

    final patterns = [
      RegExp(r'''\?\?\s*['"]([^'"$\n]+)['"]'''),
      RegExp(r'''(?:const\s+)?Text\s*\(\s*['"]([^'"$\n]+)['"]\s*[,\)]'''),
      RegExp(r'''title\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$\n]+)['"]\s*\)'''),
      RegExp(r'''child\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$\n]+)['"]\s*[,\)]'''),
      RegExp(r'''hintText\s*:\s*['"]([^'"$\n]+)['"]'''),
      RegExp(r'''labelText\s*:\s*['"]([^'"$\n]+)['"]'''),
      RegExp(r'''helperText\s*:\s*['"]([^'"$\n]+)['"]'''),
      RegExp(r'''errorText\s*:\s*['"]([^'"$\n]+)['"]'''),
      RegExp(r'''tooltipMessage\s*:\s*['"]([^'"$\n]+)['"]'''),
      RegExp(r'''(?:ElevatedButton|TextButton|OutlinedButton|FilledButton)\s*\([^)]*child\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$\n]+)['"]'''),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(content)) {
        final text = match.group(1);
        if (text == null) continue;

        final fullMatch = match.group(0)!;

        // ── VALIDATION 4 ── skip anything with $ (interpolation)
        if (text.contains(r'$') || fullMatch.contains(r'${')) continue;

        // ── VALIDATION 4 ── skip if surrounding context already has AppLocalizations / l10n
        final ctxStart = (match.start - 120).clamp(0, content.length);
        final ctxEnd   = (match.end   + 120).clamp(0, content.length);
        final ctx = content.substring(ctxStart, ctxEnd);

        if (ctx.contains('AppLocalizations') ||
            ctx.contains('l10n!.')           ||
            ctx.contains('l10n?.')           ||
            ctx.contains(r'${')              ||
            ctx.contains("l10n.")) continue;

        // ── basic quality filters ──
        if (_shouldSkipString(text)) continue;

        // skip if already applied from existing ARB in phase 5b
        if (_appliedStrings.contains(text)) continue;

        // deduplicate within the same file
        if (seen.contains(text)) continue;
        seen.add(text);

        found.add(StringInfo(text: text, originalMatch: fullMatch));
      }
    }

    return found;
  }

  /// Returns true if the string should NOT be localized.
  bool _shouldSkipString(String text) {
    final t = text.trim();

    if (t.isEmpty || t.length < 3) return true;

    // VALIDATION 4 — already an l10n reference
    if (t.startsWith('AppLocalizations') ||
        t.startsWith('S.of')             ||
        t.startsWith('l10n'))             return true;

    // VALIDATION 4 — contains interpolation marker
    if (t.contains(r'$')) return true;

    // pure numbers  e.g. "1000", "0.3", "03"
    if (RegExp(r'^\d+(\.\d+)?$').hasMatch(t)) return true;

    // ALL_CAPS codes  e.g. "AD", "USD", "API_KEY"
    if (RegExp(r'^[A-Z0-9_]+$').hasMatch(t)) return true;

    // snake_case / camelCase identifiers — not display text
    if (RegExp(r'^[a-z][a-zA-Z0-9_]*$').hasMatch(t)) return true;

    // dot-notation  e.g. "font.ttf", "com.example.app"
    if (RegExp(r'^[\w]+\.[\w.]+$').hasMatch(t)) return true;

    // route paths  e.g. "/home", "/settings/profile"
    if (t.startsWith('/')) return true;

    // single word all lowercase (likely enum/constant)
    if (RegExp(r'^[a-z]+$').hasMatch(t)) return true;

    // hex colors
    if (RegExp(r'^#[0-9a-fA-F]{3,8}$').hasMatch(t)) return true;

    return false;
  }

  // ── key generation ─────────────────────────────────────────────────────────

  String _generateKey(String text) {
    // VALIDATION 2 — if value already exists, reuse key
    if (existingValues.containsKey(text)) return existingValues[text]!;

    // VALIDATION 3 — make key from first 4 meaningful words max
    var key = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')   // remove punctuation
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');

    final words = key.split('_').where((w) => w.isNotEmpty).toList();

    // VALIDATION 3 — cap at 4 words; if still >40 chars add short hash
    if (words.length > 4 || key.length > 40) {
      final shortWords = words.take(4).join('_');
      final hash = text.hashCode.abs().toRadixString(16).substring(0, 5);
      key = '${shortWords}_$hash';
    }

    // ensure uniqueness
    var finalKey = key;
    var counter = 1;
    while (existingKeys.containsKey(finalKey) || newEntries.containsKey(finalKey)) {
      finalKey = '${key}_$counter';
      counter++;
    }

    return finalKey;
  }

  // ── file rewriting ─────────────────────────────────────────────────────────

  Future<void> _replaceStringsInFile(File dartFile, List<StringReplacement> replacements) async {
    await _backupFile(dartFile);

    var content = await dartFile.readAsString();
    final originalContent = content;

    // ── detect existing l10n variable (if any) ──
    final existingVarMatch =
        RegExp(r'final\s+(\w+)\s*=\s*AppLocalizations\.of\(context\)\s*;')
            .firstMatch(content);
    final varName = existingVarMatch?.group(1) ?? 'l10n';

    // ── find build() methods that need the declaration injected ──
    final buildMethods = <_BuildMethodInfo>[];
    final buildPattern = RegExp(r'Widget\s+build\s*\(\s*BuildContext\s+context\s*\)\s*\{');

    for (final match in buildPattern.allMatches(content)) {
      final methodEnd = _findMatchingBrace(content, match.end - 1);
      final methodBody = content.substring(match.start, methodEnd);

      // VALIDATION 1 — only inject if declaration not already present
      final alreadyHas = RegExp(r'final\s+\w+\s*=\s*AppLocalizations\.of\(context\)\s*;')
          .hasMatch(methodBody);
      if (alreadyHas) continue;

      var insertPos = match.end;
      while (insertPos < content.length && ' \n\t'.contains(content[insertPos])) {
        insertPos++;
      }
      buildMethods.add(_BuildMethodInfo(insertPosition: insertPos, varName: varName));
    }

    // ── replace hardcoded strings ──
    // Process in reverse order so positions stay valid
    final sortedReplacements = List<StringReplacement>.from(replacements)
      ..sort((a, b) => content.lastIndexOf(b.originalMatch)
          .compareTo(content.lastIndexOf(a.originalMatch)));

    for (final r in sortedReplacements) {
      // VALIDATION 4 — double-check: skip if match context has $ or l10n
      final idx = content.lastIndexOf(r.originalMatch);
      if (idx == -1) continue;

      final ctxStart = (idx - 80).clamp(0, content.length);
      final ctxEnd   = (idx + r.originalMatch.length + 80).clamp(0, content.length);
      final ctx = content.substring(ctxStart, ctxEnd);

      if (ctx.contains('AppLocalizations') ||
          ctx.contains('l10n!.')           ||
          ctx.contains('l10n?.')           ||
          ctx.contains(r'${')) {
        print('   ⏭️  Skipping already-localized: ${_truncate(r.text, 50)}');
        continue;
      }

      final localized = '$varName!.${r.key}';
      final newMatch = r.originalMatch
          .replaceAll('"${r.text}"', localized)
          .replaceAll("'${r.text}'", localized);

      content = content.replaceAll(r.originalMatch, newMatch);
    }

    if (content == originalContent) return; // nothing changed

    // ── inject l10n declarations into build methods ──
    for (final bm in buildMethods.reversed) {
      final decl = '\n    final ${bm.varName} = AppLocalizations.of(context);\n';
      content = content.substring(0, bm.insertPosition) +
          decl +
          content.substring(bm.insertPosition);
    }

    // ── VALIDATION 1 ── add import only if missing
    if (!content.contains('app_localizations.dart')) {
      final relImport = _resolveImportPath(dartFile);
      final importStatement = "import '$relImport';\n";

      final lastImport = RegExp(r'^import\s+[^\n]+;$', multiLine: true)
          .allMatches(content)
          .lastOrNull;

      if (lastImport != null) {
        content = content.substring(0, lastImport.end) +
            '\n$importStatement' +
            content.substring(lastImport.end);
      } else {
        content = '$importStatement\n$content';
      }
    }

    if (!dryRun) {
      await dartFile.writeAsString(content);
      print('✅ Updated: ${path.relative(dartFile.path, from: projectRoot)}');
    } else {
      print('🔍 [DRY RUN] Would update: ${path.relative(dartFile.path, from: projectRoot)}');
    }
  }

  /// Compute the correct relative import path from a dart file to app_localizations.dart.
  ///
  /// importPath option is treated as relative to `projectRoot/lib/`.
  /// e.g. importPath = "l10n/app_localizations.dart"
  ///      dartFile   = projectRoot/lib/features/home/home_page.dart
  ///      result     = "../../l10n/app_localizations.dart"
  String _resolveImportPath(File dartFile) {
    final absoluteL10n = path.join(projectRoot, 'lib', importPath);
    final dartDir = dartFile.parent.path;
    return path.relative(absoluteL10n, from: dartDir);
  }

  // ── ARB update ─────────────────────────────────────────────────────────────

  Future<void> _updateArbFile(File arbFile) async {
    await _backupFile(arbFile);

    final data = jsonDecode(await arbFile.readAsString()) as Map<String, dynamic>;

    // VALIDATION 2 — only add keys that don't already exist
    for (final e in newEntries.entries) {
      if (!data.containsKey(e.key)) {
        data[e.key] = e.value;
      }
    }

    if (!dryRun) {
      await arbFile.writeAsString(JsonEncoder.withIndent('  ').convert(data));
      print('✅ Updated ${path.basename(arbFile.path)} (+${newEntries.length} keys)');
    } else {
      print('🔍 [DRY RUN] Would add ${newEntries.length} keys to ${path.basename(arbFile.path)}');
    }
  }

  // ── backup helpers ─────────────────────────────────────────────────────────

  Future<void> _createBackup() async {
    if (dryRun) return;
    final backupDir = Directory(path.join(projectRoot, '.l10n_backup'));
    if (await backupDir.exists()) await backupDir.delete(recursive: true);
    await backupDir.create(recursive: true);
    final meta = {'timestamp': DateTime.now().toIso8601String(), 'files': <String>[]};
    await File(path.join(backupDir.path, 'metadata.json'))
        .writeAsString(jsonEncode(meta));
    print('💾 Backup: ${backupDir.path}\n');
  }

  Future<void> _backupFile(File file) async {
    if (dryRun) return;
    final backupDir = Directory(path.join(projectRoot, '.l10n_backup'));
    final rel = path.relative(file.path, from: projectRoot);
    final dest = File(path.join(backupDir.path, rel));
    await dest.parent.create(recursive: true);
    await file.copy(dest.path);

    final metaFile = File(path.join(backupDir.path, 'metadata.json'));
    final meta = jsonDecode(await metaFile.readAsString());
    (meta['files'] as List).add(rel);
    await metaFile.writeAsString(jsonEncode(meta));
  }

  // ── misc ───────────────────────────────────────────────────────────────────

  int _findMatchingBrace(String content, int openPos) {
    var depth = 1;
    var pos = openPos + 1;
    while (pos < content.length && depth > 0) {
      if (content[pos] == '{') depth++;
      if (content[pos] == '}') depth--;
      pos++;
    }
    return pos;
  }

  Future<void> _runFlutterGenL10n() async {
    try {
      final result = await Process.run('flutter', ['gen-l10n'],
          workingDirectory: projectRoot);
      if (result.exitCode == 0) {
        print('✅ flutter gen-l10n succeeded');
      } else {
        print('⚠️  flutter gen-l10n warning:\n${result.stderr}');
      }
    } catch (_) {
      print("⚠️  Run 'flutter gen-l10n' manually.");
    }
  }

  String _truncate(String t, int max) =>
      t.length > max ? '${t.substring(0, max)}…' : t;
}

// ─────────────────────────────────────────────────────────────────────────────
// Data classes
// ─────────────────────────────────────────────────────────────────────────────

class _BuildMethodInfo {
  final int insertPosition;
  final String varName;
  _BuildMethodInfo({required this.insertPosition, required this.varName});
}

class StringInfo {
  final String text;
  final String originalMatch;
  StringInfo({required this.text, required this.originalMatch});
}

class StringReplacement {
  final String text;
  final String originalMatch;
  final String key;
  StringReplacement({required this.text, required this.originalMatch, required this.key});
}
