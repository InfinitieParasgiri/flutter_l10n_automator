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

    // Create backup
    await _createBackup();

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
          print('   ➕ New: $key = \'${_truncate(stringInfo.text, 50)}\'');
        }

        replacements.add(StringReplacement(
          text: stringInfo.text,
          originalMatch: stringInfo.originalMatch,
          key: key,
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
    print('💡 Tip: Review the changes and test your app thoroughly.');
    print('🔄 To undo changes: dart run flutter_l10n_automator:undo\n');
  }

  Future<void> _createBackup() async {
    if (dryRun) return;

    final backupDir = Directory(path.join(projectRoot, '.l10n_backup'));
    if (await backupDir.exists()) {
      await backupDir.delete(recursive: true);
    }
    await backupDir.create(recursive: true);

    // Save metadata
    final metadata = {
      'timestamp': DateTime.now().toIso8601String(),
      'files': <String>[],
    };

    final metadataFile = File(path.join(backupDir.path, 'metadata.json'));
    await metadataFile.writeAsString(jsonEncode(metadata));

    print('💾 Backup created at: ${backupDir.path}\n');
  }

  Future<void> _backupFile(File file) async {
    if (dryRun) return;

    final backupDir = Directory(path.join(projectRoot, '.l10n_backup'));
    final relativePath = path.relative(file.path, from: projectRoot);
    final backupFile = File(path.join(backupDir.path, relativePath));

    await backupFile.parent.create(recursive: true);
    await file.copy(backupFile.path);

    // Update metadata
    final metadataFile = File(path.join(backupDir.path, 'metadata.json'));
    final metadata = jsonDecode(await metadataFile.readAsString());
    (metadata['files'] as List).add(relativePath);
    await metadataFile.writeAsString(jsonEncode(metadata));
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

    if (!await libDir.exists()) {
      print('❌ Error: lib directory not found');
      return results;
    }

    // Files to skip (non-UI files)
    final skipPatterns = [
      'model.dart',
      '_model.dart',
      'bloc.dart',
      '_bloc.dart',
      'cubit.dart',
      '_cubit.dart',
      'provider.dart',
      '_provider.dart',
      'repository.dart',
      '_repository.dart',
      'service.dart',
      '_service.dart',
      'api.dart',
      '_api.dart',
      '.g.dart',
      'generated',
    ];

    await for (final entity in libDir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.dart')) {
        final filePath = entity.path.toLowerCase();
        
        // Skip non-UI files
        if (skipPatterns.any((pattern) => filePath.contains(pattern))) {
          continue;
        }

        final strings = await _extractStringsFromFile(entity);
        if (strings.isNotEmpty) {
          results[entity] = strings;
          print('📄 ${path.relative(entity.path, from: projectRoot)}: ${strings.length} strings');
        }
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

    // Patterns to detect hardcoded strings - [^'"$]+ excludes $ to avoid interpolation
    final patterns = [
      // Null coalescing FIRST (highest priority) - catch ?? 'value' anywhere
      RegExp(r'''\?\?\s*['"]([^'"$]+)['"]'''),
      // Text widget patterns (including const Text)
      RegExp(r'''(?:const\s+)?Text\s*\(\s*['"]([^'"$]+)['"]\s*[,\)]'''),
      RegExp(r'''title\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$]+)['"]\s*\)'''),
      RegExp(r'''child\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$]+)['"]\s*[,\)]'''),
      RegExp(r'''hintText\s*:\s*['"]([^'"$]+)['"]'''),
      RegExp(r'''labelText\s*:\s*['"]([^'"$]+)['"]'''),
      RegExp(r'''(?:ElevatedButton|TextButton|OutlinedButton)\s*\([^)]*child\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$]+)['"]'''),
    ];

    for (final pattern in patterns) {
      for (final match in pattern.allMatches(content)) {
        final text = match.group(1);
        final fullMatch = match.group(0)!;
        
        if (text == null) continue;

        // CRITICAL: Skip if the full match context contains interpolation or AppLocalizations
        // Check the surrounding context (100 chars before and after)
        final matchStart = match.start;
        final matchEnd = match.end;
        final contextStart = matchStart > 100 ? matchStart - 100 : 0;
        final contextEnd = matchEnd + 100 < content.length ? matchEnd + 100 : content.length;
        final surroundingContext = content.substring(contextStart, contextEnd);
        
        // Skip if context shows this is part of interpolation or already localized
        if (surroundingContext.contains(r'${') || 
            surroundingContext.contains('AppLocalizations') ||
            surroundingContext.contains('l10n!.') ||
            surroundingContext.contains('l10n?.')) {
          print('   ⏭️  Skipping (interpolation/localized): ${_truncate(text, 50)}');
          continue;
        }

        // Skip strings with $ character (interpolation marker)
        if (text.contains(r'$')) {
          print('   ⏭️  Skipping interpolated string: ${_truncate(text, 50)}');
          continue;
        }

        // Skip if already localized or invalid
        if (text.startsWith('AppLocalizations') ||
            text.startsWith('S.of') ||
            text.startsWith('l10n') ||
            text.length < 2 ||
            text.trim().isEmpty ||
            RegExp(r'^[a-z_]+$').hasMatch(text)) {
          continue;
        }

        found.add(StringInfo(
          text: text,
          originalMatch: fullMatch,
        ));
      }
    }

    return found;
  }

  String _generateKey(String text) {
    if (existingValues.containsKey(text)) {
      return existingValues[text]!;
    }

    var key = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), '_');

    final words = key.split('_');
    if (words.length > 5 || key.length > 50) {
      key = '${words.take(3).join('_')}_${text.hashCode.abs().toRadixString(16).substring(0, 6)}';
    }

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
    
    // Backup file before modifying
    await _backupFile(dartFile);

    var content = await dartFile.readAsString();
    final originalContent = content;

    // Find ALL build methods in the file
    final buildMethods = <BuildMethodInfo>[];
    final buildPattern = RegExp(
      r'Widget\s+build\s*\(\s*BuildContext\s+context\s*\)\s*\{',
    );

    for (final match in buildPattern.allMatches(content)) {
      // Check if this build method already has l10n declaration
      final methodStart = match.start;
      final methodEnd = _findMatchingBrace(content, match.end - 1);
      
      final methodContent = content.substring(methodStart, methodEnd);
      final hasDeclaration = RegExp(
        r'final\s+(\w+)\s*=\s*AppLocalizations\.of\(context\)\s*;'
      ).hasMatch(methodContent);

      if (!hasDeclaration) {
        final varName = 'l10n';
        var insertPos = match.end;
        
        // Skip whitespace
        while (insertPos < content.length && ' \n\t'.contains(content[insertPos])) {
          insertPos++;
        }

        buildMethods.add(BuildMethodInfo(
          start: match.start,
          insertPosition: insertPos,
          varName: varName,
        ));
      }
    }

    // Detect existing localization variable name
    final existingVarMatch = RegExp(r'final\s+(\w+)\s*=\s*AppLocalizations\.of\(context\)\s*;')
        .firstMatch(content);
    final varName = existingVarMatch?.group(1) ?? 'l10n';

    // Sort replacements by position (reverse)
    replacements.sort((a, b) => content.lastIndexOf(b.originalMatch)
        .compareTo(content.lastIndexOf(a.originalMatch)));

    // Replace strings
    for (final replacement in replacements) {
      final localized = '$varName!.${replacement.key}';
      final newMatch = replacement.originalMatch
          .replaceAll('"${replacement.text}"', localized)
          .replaceAll("'${replacement.text}'", localized);
      content = content.replaceAll(replacement.originalMatch, newMatch);
    }

    // Add l10n declarations to all build methods that need them
    for (final buildMethod in buildMethods.reversed) {
      final declaration = '\n    final ${buildMethod.varName} = AppLocalizations.of(context);\n';
      content = content.substring(0, buildMethod.insertPosition) + 
                declaration + 
                content.substring(buildMethod.insertPosition);
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

  int _findMatchingBrace(String content, int openBracePos) {
    var depth = 1;
    var pos = openBracePos + 1;

    while (pos < content.length && depth > 0) {
      if (content[pos] == '{') depth++;
      if (content[pos] == '}') depth--;
      pos++;
    }

    return pos;
  }

  Future<void> _updateArbFile(File arbFile) async {
    await _backupFile(arbFile);

    final content = await arbFile.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

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

class BuildMethodInfo {
  final int start;
  final int insertPosition;
  final String varName;

  BuildMethodInfo({
    required this.start,
    required this.insertPosition,
    required this.varName,
  });
}

class StringInfo {
  final String text;
  final String originalMatch;

  StringInfo({
    required this.text,
    required this.originalMatch,
  });
}

class StringReplacement {
  final String text;
  final String originalMatch;
  final String key;

  StringReplacement({
    required this.text,
    required this.originalMatch,
    required this.key,
  });
}
