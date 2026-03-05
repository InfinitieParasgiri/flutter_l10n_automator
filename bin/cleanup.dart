#!/usr/bin/env dart

import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:glob/glob.dart';

void main() async {
  print('🧹 Flutter L10n Cleanup Tool\n');
  print('=' * 50);
  print('Fixing:');
  print('  1. Wrong import paths');
  print('  2. const keyword issues');
  print('  3. Nullable vs non-null assertions');
  print('  4. Variable declarations');
  print('=' * 50);
  print('');

  final projectRoot = Directory.current.path;
  final libDir = Directory(path.join(projectRoot, 'lib'));

  if (!await libDir.exists()) {
    print('❌ Error: lib directory not found');
    exit(1);
  }

  final dartFiles = Glob('**/*.dart')
      .listSync(root: libDir.path)
      .whereType<File>()
      .where((f) => !f.path.contains('.g.dart') && !f.path.contains('generated'));

  var fixedCount = 0;

  for (final dartFile in dartFiles) {
    if (await _fixFile(dartFile, projectRoot)) {
      fixedCount++;
    }
  }

  print('\n${'=' * 50}');
  if (fixedCount > 0) {
    print('✨ Fixed $fixedCount files!');
  } else {
    print('✨ No files needed fixing!');
  }
  print('=' * 50);
  print('');
  print('💡 Next steps:');
  print('   1. Run: flutter gen-l10n');
  print('   2. Test your app');
  print('   3. Check for any remaining issues\n');
}

Future<bool> _fixFile(File dartFile, String projectRoot) async {
  var content = await dartFile.readAsString();
  final originalContent = content;

  // Fix 1: Wrong import path
  content = content.replaceAll(
    "import 'package:flutter_gen/gen_l10n/app_localizations.dart';",
    "import 'l10n/app_localizations.dart';",
  );

  // Fix 2: Remove const from widgets using localization
  final constWidgetPattern = RegExp(r'const\s+\w+\([^)]*\)');
  content = content.replaceAllMapped(constWidgetPattern, (match) {
    final widgetContent = match.group(0)!;
    if (widgetContent.contains('l10n') ||
        widgetContent.contains('AppLocalizations')) {
      return widgetContent.replaceFirst('const ', '');
    }
    return widgetContent;
  });

  // Fix 3: Change l10n?.key to l10n!.key
  content = content.replaceAllMapped(
    RegExp(r'(\w+)\?\.(\w+)'),
    (match) {
      final varName = match.group(1)!;
      final property = match.group(2)!;
      // Only replace if it looks like a localization variable
      if (varName == 'l10n' ||
          varName == 'localizations' ||
          varName == 'appLoc' ||
          varName.contains('l10n')) {
        return '$varName!.$property';
      }
      return match.group(0)!;
    },
  );

  // Fix 4: Ensure final instead of const for AppLocalizations
  content = content.replaceAllMapped(
    RegExp(r'const\s+(\w+)\s*=\s*AppLocalizations\.of\(context\)'),
    (match) => 'final ${match.group(1)} = AppLocalizations.of(context)',
  );

  if (content != originalContent) {
    await dartFile.writeAsString(content);
    print('✅ Fixed: ${path.relative(dartFile.path, from: projectRoot)}');
    return true;
  }

  return false;
}
