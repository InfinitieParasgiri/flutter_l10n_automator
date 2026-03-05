#!/usr/bin/env dart

import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

void main() async {
  final undoTool = UndoTool(projectRoot: Directory.current.path);
  await undoTool.run();
}

class UndoTool {
  final String projectRoot;

  UndoTool({required this.projectRoot});

  Future<void> run() async {
    print('🔄 Flutter L10n Undo Tool\n');
    print('=' * 50);

    final backupDir = Directory(path.join(projectRoot, '.l10n_backup'));

    if (!await backupDir.exists()) {
      print('❌ No backup found!');
      print('   Backup directory not found: ${backupDir.path}');
      print('   Cannot undo changes.\n');
      exit(1);
    }

    // Load metadata
    final metadataFile = File(path.join(backupDir.path, 'metadata.json'));
    if (!await metadataFile.exists()) {
      print('❌ Backup metadata not found!');
      print('   Cannot determine which files to restore.\n');
      exit(1);
    }

    final metadata = jsonDecode(await metadataFile.readAsString());
    final files = (metadata['files'] as List).cast<String>();
    final timestamp = metadata['timestamp'] as String;

    print('📦 Found backup from: $timestamp');
    print('📁 Files to restore: ${files.length}\n');

    // Confirm with user
    stdout.write('⚠️  This will restore ${files.length} files. Continue? (y/n): ');
    final response = stdin.readLineSync();

    if (response?.toLowerCase() != 'y') {
      print('\n❌ Undo cancelled.\n');
      exit(0);
    }

    print('\n🔄 Restoring files...\n');

    var restoredCount = 0;
    var errorCount = 0;

    for (final relativePath in files) {
      try {
        final backupFile = File(path.join(backupDir.path, relativePath));
        final originalFile = File(path.join(projectRoot, relativePath));

        if (await backupFile.exists()) {
          await originalFile.parent.create(recursive: true);
          await backupFile.copy(originalFile.path);
          print('✅ Restored: $relativePath');
          restoredCount++;
        } else {
          print('⚠️  Backup not found: $relativePath');
          errorCount++;
        }
      } catch (e) {
        print('❌ Error restoring $relativePath: $e');
        errorCount++;
      }
    }

    // Clean up backup directory
    print('\n🧹 Cleaning up backup...');
    await backupDir.delete(recursive: true);

    print('\n${'=' * 50}');
    print('📈 SUMMARY');
    print('   • Files restored: $restoredCount');
    if (errorCount > 0) {
      print('   • Errors: $errorCount');
    }
    print('=' * 50);

    if (restoredCount > 0) {
      print('\n✨ Undo complete! Your files have been restored.');
      print('💡 Run flutter gen-l10n to regenerate localization files.\n');
    } else {
      print('\n⚠️  No files were restored.\n');
    }
  }
}
