#!/usr/bin/env dart

import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

void main(List<String> arguments) async {
  final undoTool = UndoTool(projectRoot: Directory.current.path);
  await undoTool.run();
}

// ─────────────────────────────────────────────────────────────────────────────

class UndoTool {
  final String projectRoot;
  UndoTool({required this.projectRoot});

  Future<void> run() async {
    print('🔄 Flutter L10n Undo Tool');
    print('=' * 50);

    final backupDir = Directory(path.join(projectRoot, '.l10n_backup'));

    // ── 1. Check backup exists ─────────────────────────────────────────────
    if (!await backupDir.exists()) {
      print('\n❌ No backup found.');
      print('   The automator must be run (without --dry-run) before you can undo.');
      print('   Backup expected at: ${backupDir.path}\n');
      exit(1);
    }

    final metadataFile = File(path.join(backupDir.path, 'metadata.json'));
    if (!await metadataFile.exists()) {
      print('\n❌ Backup metadata not found — cannot determine what to restore.');
      print('   Try deleting .l10n_backup/ and running the automator again.\n');
      exit(1);
    }

    // ── 2. Load metadata ───────────────────────────────────────────────────
    final metadata  = jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    final files     = (metadata['files']    as List? ?? []).cast<String>();
    final newFiles  = (metadata['newFiles'] as List? ?? []).cast<String>();
    final timestamp = metadata['timestamp'] as String? ?? 'unknown';

    print('\n📦 Backup created  : $timestamp');
    print('📝 Files to restore: ${files.length}');
    if (newFiles.isNotEmpty) {
      print('🗑  Files to delete : ${newFiles.length} (created by automator)');
    }

    // ── 3. Show full preview ───────────────────────────────────────────────
    print('\n─── Files that will be RESTORED ───────────────────────────────');
    if (files.isEmpty) {
      print('   (none)');
    } else {
      for (final f in files) print('   ↩️  $f');
    }

    if (newFiles.isNotEmpty) {
      print('\n─── Files that will be DELETED (added by automator) ───────────');
      for (final f in newFiles) print('   🗑  $f');
    }

    // ── 4. Confirm ─────────────────────────────────────────────────────────
    print('\n' + '─' * 50);
    stdout.write('⚠️  Undo all l10n changes? (y/n): ');
    final response = stdin.readLineSync();

    if (response?.toLowerCase() != 'y') {
      print('\n❌ Undo cancelled. No changes were made.\n');
      exit(0);
    }

    print('\n🔄 Restoring...\n');

    var restoredCount = 0;
    var deletedCount  = 0;
    var errorCount    = 0;

    // ── 5. Restore each backed-up file ─────────────────────────────────────
    for (final relativePath in files) {
      try {
        final backupFile   = File(path.join(backupDir.path, relativePath));
        final originalFile = File(path.join(projectRoot, relativePath));

        if (await backupFile.exists()) {
          await originalFile.parent.create(recursive: true);
          await backupFile.copy(originalFile.path);
          print('   ✅ Restored : $relativePath');
          restoredCount++;
        } else {
          print('   ⚠️  Missing backup for: $relativePath');
          errorCount++;
        }
      } catch (e) {
        print('   ❌ Error restoring $relativePath: $e');
        errorCount++;
      }
    }

    // ── 6. Delete any new files the automator created ──────────────────────
    for (final relativePath in newFiles) {
      try {
        final file = File(path.join(projectRoot, relativePath));
        if (await file.exists()) {
          await file.delete();
          print('   🗑  Deleted  : $relativePath');
          deletedCount++;
        }
      } catch (e) {
        print('   ❌ Error deleting $relativePath: $e');
        errorCount++;
      }
    }

    // ── 7. Delete the backup directory ─────────────────────────────────────
    print('\n🧹 Cleaning up backup...');
    try {
      await backupDir.delete(recursive: true);
      print('   ✅ Backup removed');
    } catch (e) {
      print('   ⚠️  Could not remove backup: $e');
    }

    // ── 8. Re-run flutter gen-l10n so generated files match restored ARB ───
    print('\n🎨 Regenerating localization files...');
    try {
      final result = await Process.run(
        'flutter', ['gen-l10n'],
        workingDirectory: projectRoot,
      );
      if (result.exitCode == 0) {
        print('   ✅ flutter gen-l10n succeeded');
      } else {
        print('   ⚠️  flutter gen-l10n had issues:');
        if ((result.stderr as String).isNotEmpty) print(result.stderr);
        print("   Run 'flutter gen-l10n' manually to finish.");
      }
    } catch (_) {
      print("   ⚠️  Flutter not in PATH. Run 'flutter gen-l10n' manually.");
    }

    // ── 9. Summary ─────────────────────────────────────────────────────────
    print('\n${'=' * 50}');
    print('📈 SUMMARY');
    print('   • Files restored : $restoredCount');
    if (deletedCount > 0) print('   • Files deleted  : $deletedCount');
    if (errorCount   > 0) print('   • Errors         : $errorCount');
    print('=' * 50);

    if (errorCount == 0) {
      print('\n✨ Undo complete! Your project is fully restored to its previous state.\n');
    } else {
      print('\n⚠️  Undo finished with $errorCount error(s). Review the output above.\n');
    }
  }
}
