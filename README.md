# Flutter L10n Automator 🚀

Automatically extract hardcoded strings from your Flutter app and generate localization files - **Pure Dart, no Python needed!**

## ✨ Features

- 🔍 Scans all `.dart` files for hardcoded strings
- 🎯 Detects Text, TextField, AppBar, Buttons, and more
- 🔑 Auto-generates smart keys (shortened for long text)
- 📝 Updates `.arb` files automatically
- 🔄 Replaces strings with `l10n!.keyName`
- ✅ Removes `const` from widgets using localization
- 📦 Pure Dart - no Python required!
- 🌐 Can be added directly from GitHub!

---

## 🚀 Installation

### Option 1: From GitHub (Recommended)

Add to your `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_l10n_automator:
    git:
      url: https://github.com/yourusername/flutter_l10n_automator.git
```

Then run:
```bash
flutter pub get
```

### Option 2: Local Installation

1. Clone or download this package
2. Add to your `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_l10n_automator:
    path: ../path/to/flutter_l10n_automator
```

---

## 📖 Usage

### Automated Localization

Run from your Flutter project root:

```bash
# Preview changes (dry run)
dart run flutter_l10n_automator --dry-run

# Apply changes
dart run flutter_l10n_automator

# Custom ARB directory
dart run flutter_l10n_automator --arb-dir lib/localization

# Custom import path
dart run flutter_l10n_automator --import-path localization/app_localizations.dart
```

### Cleanup Existing Issues

If you have wrong imports or const issues:

```bash
dart run flutter_l10n_automator:cleanup
```

This fixes:
- ❌ Wrong import paths
- ❌ `const` keyword issues
- ❌ Nullable `?.` vs non-null `!.`
- ❌ Wrong variable declarations

---

## 📋 Example

### Before:
```dart
class LoginPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Login'),
      ),
      body: Column(
        children: [
          TextField(
            decoration: InputDecoration(
              hintText: 'Enter your email',
              labelText: 'Email',
            ),
          ),
          ElevatedButton(
            onPressed: () {},
            child: Text('Sign In'),
          ),
        ],
      ),
    );
  }
}
```

### After Running Tool:
```dart
import 'l10n/app_localizations.dart';

class LoginPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n!.login),
      ),
      body: Column(
        children: [
          TextField(
            decoration: InputDecoration(
              hintText: l10n!.enterYourEmail,
              labelText: l10n!.email,
            ),
          ),
          ElevatedButton(
            onPressed: () {},
            child: Text(l10n!.signIn),
          ),
        ],
      ),
    );
  }
}
```

### app_en.arb (Auto-generated):
```json
{
  "login": "Login",
  "enterYourEmail": "Enter your email",
  "email": "Email",
  "signIn": "Sign In"
}
```

---

## ⚙️ Options

```bash
--dry-run, -d          Preview changes without modifying files
--arb-dir              Directory containing .arb files (default: lib/l10n)
--import-path          Import path for AppLocalizations (default: l10n/app_localizations.dart)
--help, -h             Show usage
```

---

## 🔧 How It Works

1. **Scans** all `.dart` files in `lib/`
2. **Extracts** hardcoded strings from Text(), TextField(), etc.
3. **Detects** existing localization patterns
4. **Generates** smart keys (shortened for long text)
5. **Updates** `app_en.arb` with new entries
6. **Replaces** strings with `l10n!.keyName`
7. **Adds** `final l10n = AppLocalizations.of(context);` if missing
8. **Removes** `const` from widgets using localization
9. **Runs** `flutter gen-l10n` automatically

---

## 📦 Setup Requirements

Your Flutter project needs standard l10n setup:

### pubspec.yaml
```yaml
flutter:
  generate: true

dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter
```

### l10n.yaml (optional, uses defaults)
```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
```

---

## 🎯 Common Workflows

### First Time Setup
```bash
# 1. Add to pubspec.yaml
dev_dependencies:
  flutter_l10n_automator:
    git: https://github.com/yourusername/flutter_l10n_automator.git

# 2. Get package
flutter pub get

# 3. Preview changes
dart run flutter_l10n_automator --dry-run

# 4. Apply localization
dart run flutter_l10n_automator

# 5. Test your app
flutter run
```

### After Adding New Strings
```bash
# Just run the tool again!
dart run flutter_l10n_automator
```

### Fix Existing Issues
```bash
# Clean up wrong imports/const issues
dart run flutter_l10n_automator:cleanup

# Then regenerate
flutter gen-l10n
```

---

## 🛠️ Troubleshooting

### "app_en.arb not found"
Make sure your `.arb` file exists at `lib/l10n/app_en.arb` or specify with `--arb-dir`

### "Flutter command not found"
Ensure Flutter SDK is in your PATH. You can manually run `flutter gen-l10n` after.

### Import path issues
Use `--import-path` to specify your custom import path:
```bash
dart run flutter_l10n_automator --import-path your/custom/path.dart
```

### const errors
Run the cleanup tool:
```bash
dart run flutter_l10n_automator:cleanup
```

---

## 🌍 Multiple Languages

After running the tool, copy entries to other language files:

```bash
# Tool updates app_en.arb
# Copy to other languages:
cp lib/l10n/app_en.arb lib/l10n/app_es.arb
cp lib/l10n/app_en.arb lib/l10n/app_fr.arb

# Then translate the values manually
```

---

## 📝 Key Generation

The tool generates intelligent keys:

| Original Text | Generated Key |
|--------------|---------------|
| "Login" | `login` |
| "Enter your email" | `enter_your_email` |
| "This is a very long text..." | `this_is_a_very_a1b2c3` |

Long text gets shortened with a hash to keep keys readable!

---

## 💡 Tips

1. **Always run --dry-run first** to preview changes
2. **Commit before running** so you can review diffs
3. **Review generated keys** - some might need renaming
4. **Test thoroughly** after localization
5. **Run cleanup** if you encounter const or import issues

---

## 🤝 Contributing

Contributions welcome! Feel free to:
- Report bugs
- Suggest features
- Submit pull requests

---

## 📄 License

MIT License - Free to use and modify

---

## 🙏 Credits

Made with ❤️ for Flutter developers who want to automate localization

---

## 🔗 Links

- GitHub: https://github.com/yourusername/flutter_l10n_automator
- Issues: https://github.com/yourusername/flutter_l10n_automator/issues
- Flutter l10n docs: https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization

---

**No Python, No Manual Work, Just Pure Dart Magic! 🎩✨**
