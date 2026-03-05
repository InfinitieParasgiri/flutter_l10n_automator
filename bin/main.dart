#!/usr/bin/env dart

import 'dart:io';
import 'dart:convert';
import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:glob/glob.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('dry-run',
        abbr: 'd', negatable: false, help: 'Preview changes without modifying files')
    ..addOption('arb-dir',
        defaultsTo: 'lib/l10n', help: 'Directory containing .arb files')
    ..addOption('import-path',
        defaultsTo: 'l10n/app_localizations.dart',
        help: 'Import path for AppLocalizations')
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
  print('\nExample:');
  print('  dart run flutter_l10n_automator');
  print('  dart run flutter_l10n_automator --dry-run');
}

class L10nAutomator {
  final String projectRoot;
  final String arbDir;
  final String importPath;
  final bool dryRun;

  final Map<String, String> existingKeys = {};
  final Map<String, String> existingValues = {};
  final Map<String, String> newEntries = {};

  L10nAutomator({
    required this.projectRoot,
    required this.arbDir,
    required this.importPath,
    required this.dryRun,
  });

  Future<void> run() async {
    print('🚀 Flutter L10n Automation Tool\n');
    print('=' * 50);

    // Find ARB file
    final arbFile = File(path.join(projectRoot, arbDir, 'app_en.arb'));
    if (!await arbFile.exists()) {
      print('❌ Error: app_en.arb not found in $arbDir');
      exit(1);
    }

    print('📁 ARB file: ${path.relative(arbFile.path, from: projectRoot)}\n');

    // Load existing entries
    await _loadExistingArb(arbFile);
    print('📚 Loaded ${existingKeys.length} existing keys\n');

    // Scan project
    print('🔍 Scanning Flutter project for hardcoded strings...\n');
    final scanResults = await _scanProject();

    if (scanResults.isEmpty) {
      print('\n✨ No hardcoded strings found! Your project is already localized.');
      return;
    }

    print('\n${'=' * 50}');
    final totalStrings =
        scanResults.values.fold(0, (sum, list) => sum + list.length);
    print('📊 Found $totalStrings total strings in ${scanResults.length} files\n');

    print('🔧 Processing strings...\n');

    // Process each file
    for (final entry in scanResults.entries) {
      final dartFile = entry.key;
      final strings = entry.value;

      final replacements = <StringReplacement>[];

      for (final stringInfo in strings) {
        String key;
        if (existingValues.containsKey(stringInfo.text)) {
          key = existingValues[stringInfo.text]!;
          print('   ♻️  Reusing key: $key for \'${_truncate(stringInfo.text, 50)}\'');
        } else {
          key = _generateKey(stringInfo.text);
          newEntries[key] = stringInfo.text;
          final constMarker = stringInfo.isConst ? ' [CONST]' : '';
          print('   ➕ New: $key = \'${_truncate(stringInfo.text, 50)}\'$constMarker');
        }

        replacements.add(StringReplacement(
          text: stringInfo.text,
          originalMatch: stringInfo.originalMatch,
          key: key,
          isConst: stringInfo.isConst,
        ));
      }

      if (replacements.isNotEmpty) {
        await _replaceStringsInFile(dartFile, replacements);
      }
    }

    // Update ARB file
    print('\n${'=' * 50}');
    if (newEntries.isNotEmpty) {
      await _updateArbFile(arbFile);
    }

    // Run flutter gen-l10n
    if (!dryRun) {
      print('\n${'=' * 50}');
      print('🎨 Running flutter gen-l10n...\n');
      await _runFlutterGenL10n();
    }

    // Summary
    print('\n${'=' * 50}');
    print('📈 SUMMARY');
    print('   • Files processed: ${scanResults.length}');
    print('   • New keys added: ${newEntries.length}');
    print('   • Total keys in .arb: ${existingKeys.length + newEntries.length}');
    print('=' * 50);
    print('\n✨ Done! Your Flutter app is now localized.');
    print('💡 Tip: Review the changes and test your app thoroughly.\n');
  }

  Future<void> _loadExistingArb(File arbFile) async {
    final content = await arbFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

    for (final entry in data.entries) {
      if (!entry.key.startsWith('@')) {
        existingKeys[entry.key] = entry.value.toString();
        existingValues[entry.value.toString()] = entry.key;
      }
    }
  }

  Future<Map<File, List<StringInfo>>> _scanProject() async {
    final results = <File, List<StringInfo>>{};
    final libDir = Directory(path.join(projectRoot, 'lib'));

    final dartFiles = Glob('**/*.dart')
        .listSync(root: libDir.path)
        .whereType<File>()
        .where((f) =>
            !f.path.contains('.g.dart') && !f.path.contains('generated'));

    for (final dartFile in dartFiles) {
      final strings = await _extractStringsFromFile(dartFile);
      if (strings.isNotEmpty) {
        results[dartFile] = strings;
        print('📄 ${path.relative(dartFile.path, from: projectRoot)}: ${strings.length} strings');
      }
    }

    return results;
  }

  Future<List<StringInfo>> _extractStringsFromFile(File dartFile) async {
    final content = await dartFile.readAsString();
    final found = <StringInfo>[];

    // Skip if already heavily localized
    if (content.contains('AppLocalizations.of(context)') &&
        'AppLocalizations.of(context)'.allMatches(content).length > 10) {
      return found;
    }

    // Patterns to detect hardcoded strings
    final patterns = [
      RegExp(r"Text\s*\(\s*['\"]([^'\"]+)['\"]\s*[,\)]"),
      RegExp(r"title\s*:\s*Text\s*\(\s*['\"]([^'\"]+)['\"]\s*\)"),
      RegExp(r"hintText\s*:\s*['\"]([^'\"]+)['\"]"),
      RegExp(r"labelText\s*:\s*['\"]([^'\"]+)['\"]"),
      RegExp(
          r"(?:ElevatedButton|TextButton|OutlinedButton)\s*\([^)]*child\s*:\s*Text\s*\(\s*['\"]([^'\"]+)['\"]"),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(content)) {
        final text = match.group(1)!;

        // Skip if already localized or invalid
        if (text.startsWith('AppLocalizations') ||
            text.startsWith('S.of') ||
            text.length < 2 ||
            text.trim().isEmpty ||
            RegExp(r'^[a-z_]+$').hasMatch(text)) {
          continue;
        }

        final isConst = _isInConstContext(content, match.start);
        found.add(StringInfo(
          text: text,
          originalMatch: match.group(0)!,
          isConst: isConst,
        ));
      }
    }

    return found;
  }

  bool _isInConstContext(String content, int position) {
    final lookBack = content.substring(
        position > 200 ? position - 200 : 0, position);
    return lookBack.contains(RegExp(r'\bconst\s+\w+\s*\(')) ||
        lookBack.contains(RegExp(r'\bconst\s*\['));
  }

  String _generateKey(String text) {
    // Check if already exists
    if (existingValues.containsKey(text)) {
      return existingValues[text]!;
    }

    // Clean and convert to snake_case
    var key = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), '_');

    // Shorten if too long
    final words = key.split('_');
    if (words.length > 5 || key.length > 50) {
      key = '${words.take(3).join('_')}_${text.hashCode.abs().toRadixString(16).substring(0, 6)}';
    }

    // Ensure uniqueness
    var finalKey = key;
    var counter = 1;
    while (existingKeys.containsKey(finalKey) ||
        newEntries.containsKey(finalKey)) {
      finalKey = '${key}_$counter';
      counter++;
    }

    return finalKey;
  }

  Future<void> _replaceStringsInFile(
      File dartFile, List<StringReplacement> replacements) async {
    var content = await dartFile.readAsString();
    final originalContent = content;

    // Detect localization pattern
    final varNameMatch = RegExp(r'final\s+(\w+)\s*=\s*AppLocalizations\.of\(context\)\s*;')
        .firstMatch(content);
    final varName = varNameMatch?.group(1) ?? 'l10n';
    final hasDeclaration = varNameMatch != null;

    // Sort replacements by position (reverse)
    replacements.sort((a, b) => content.lastIndexOf(b.originalMatch)
        .compareTo(content.lastIndexOf(a.originalMatch)));

    // Replace strings
    for (final replacement in replacements) {
      final localized = '$varName!.${replacement.key}';

      // Remove const if needed
      if (replacement.isConst) {
        final matchPos = content.lastIndexOf(replacement.originalMatch);
        final lookBackStart = matchPos > 100 ? matchPos - 100 : 0;
        final lookBack = content.substring(lookBackStart, matchPos);

        final constMatch = RegExp(r'\bconst\s+(\w+\s*\()').firstMatch(lookBack);
        if (constMatch != null) {
          final constPos = lookBackStart + constMatch.start;
          content = content.substring(0, constPos) +
              content.substring(constPos).replaceFirst('const ', '');
        }
      }

      final newMatch = replacement.originalMatch
          .replaceAll('"${replacement.text}"', localized)
          .replaceAll("'${replacement.text}'", localized);
      content = content.replaceAll(replacement.originalMatch, newMatch);
    }

    // Add variable declaration if needed
    if (content != originalContent && !hasDeclaration) {
      final buildMatch = RegExp(r'Widget\s+build\s*\(\s*BuildContext\s+context\s*\)\s*\{')
          .firstMatch(content);

      if (buildMatch != null) {
        var pos = buildMatch.end;
        while (pos < content.length && ' \n\t'.contains(content[pos])) {
          pos++;
        }

        final declaration = '\n    final $varName = AppLocalizations.of(context);\n';
        content = content.substring(0, pos) + declaration + content.substring(pos);
      }
    }

    // Add import if needed
    if (content != originalContent && !content.contains(importPath)) {
      final importStatement = "import '$importPath';\n";
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

    // Write file
    if (!dryRun) {
      await dartFile.writeAsString(content);
      print('✅ Updated ${path.relative(dartFile.path, from: projectRoot)} (using $varName!.keyName)');
    } else {
      print('🔍 [DRY RUN] Would update ${path.relative(dartFile.path, from: projectRoot)} (using $varName!.keyName)');
    }
  }

  Future<void> _updateArbFile(File arbFile) async {
    final content = await arbFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

    // Add new entries
    for (final entry in newEntries.entries) {
      data[entry.key] = entry.value;
    }

    if (!dryRun) {
      final encoder = JsonEncoder.withIndent('  ');
      await arbFile.writeAsString(encoder.convert(data));
      print('✅ Updated ${path.basename(arbFile.path)} with ${newEntries.length} new entries');
    } else {
      print('🔍 [DRY RUN] Would update ${path.basename(arbFile.path)} with ${newEntries.length} new entries');
    }
  }

  Future<void> _runFlutterGenL10n() async {
    try {
      final result = await Process.run(
        'flutter',
        ['gen-l10n'],
        workingDirectory: projectRoot,
      );

      if (result.exitCode == 0) {
        print('✅ Successfully generated localization files!');
        if (result.stdout.toString().isNotEmpty) {
          print(result.stdout);
        }
      } else {
        print('⚠️  Warning: flutter gen-l10n encountered issues:');
        print(result.stderr);
      }
    } catch (e) {
      print('⚠️  Flutter command not found. Please run \'flutter gen-l10n\' manually.');
    }
  }

  String _truncate(String text, int maxLength) {
    return text.length > maxLength
        ? '${text.substring(0, maxLength)}...'
        : text;
  }
}

class StringInfo {
  final String text;
  final String originalMatch;
  final bool isConst;

  StringInfo({
    required this.text,
    required this.originalMatch,
    required this.isConst,
  });
}

class StringReplacement {
  final String text;
  final String originalMatch;
  final String key;
  final bool isConst;

  StringReplacement({
    required this.text,
    required this.originalMatch,
    required this.key,
    required this.isConst,
  });
}
