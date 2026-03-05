# Quick Start Guide 🚀

## For Your Project (Using GitHub)

### Step 1: Add to pubspec.yaml

```yaml
dev_dependencies:
  flutter_l10n_automator:
    git:
      url: https://github.com/yourusername/flutter_l10n_automator.git
      # Or your actual GitHub URL
```

### Step 2: Get the package

```bash
flutter pub get
```

### Step 3: Run it!

```bash
# Preview first (safe)
dart run flutter_l10n_automator --dry-run

# If good, apply changes
dart run flutter_l10n_automator
```

---

## To Publish on GitHub

### 1. Create a new repository on GitHub
```
Name: flutter_l10n_automator
Description: Automatic localization tool for Flutter apps
```

### 2. Upload the package

```bash
cd flutter_l10n_automator
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/yourusername/flutter_l10n_automator.git
git push -u origin main
```

### 3. Share the URL

Anyone can now use it by adding to their `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_l10n_automator:
    git:
      url: https://github.com/yourusername/flutter_l10n_automator.git
```

---

## Usage Examples

### Basic Usage
```bash
dart run flutter_l10n_automator
```

### With Options
```bash
dart run flutter_l10n_automator --dry-run --arb-dir lib/localization
```

### Cleanup Issues
```bash
dart run flutter_l10n_automator:cleanup
```

---

## What Gets Localized?

✅ Text widgets
✅ TextField hints and labels
✅ AppBar titles
✅ Button text
✅ SnackBar content
✅ AlertDialog content

---

## No More Manual Work!

Before: 😫
1. Find hardcoded string
2. Add to .arb file manually
3. Generate key name
4. Replace in code
5. Add import
6. Run flutter gen-l10n
7. Repeat 100 times...

After: 😎
```bash
dart run flutter_l10n_automator
```

Done! ✨

---

## Tips

💡 Always run `--dry-run` first
💡 Commit your code before running
💡 Review the generated keys
💡 Test your app after localization
💡 Use cleanup tool if issues occur

---

## Need Help?

Check the full README.md for detailed documentation!
