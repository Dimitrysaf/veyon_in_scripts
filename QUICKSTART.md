# Quick Start Guide

## 🚀 Get Started in 3 Steps

### Step 1: Install Python Dependencies

```bash
pip install -r requirements.txt
```

### Step 2: Run the Menu

```bash
python menu.py
```

### Step 3: Choose Your Installation

- **Option 1**: Install on teacher/supervisor computer (gets both private + public keys)
- **Option 2**: Install on student computers (gets public keys only)

---

## 📋 What Happens During Installation?

### Teacher Installation (Option 1)

1. ✅ Downloads latest Veyon from GitHub
2. ✅ Verifies SHA256 checksum
3. ✅ Installs silently
4. ✅ Copies **private + public keys** to `keys/` directory
5. ✅ Logs everything to `logs/` directory

**Result**: You get both keys in these locations:
```
keys/private/supervisor/key  ← Keep secure!
keys/public/supervisor/key   ← Distribute to students
```

### Student Installation (Option 2)

1. ✅ Downloads latest Veyon from GitHub
2. ✅ Verifies SHA256 checksum
3. ✅ Installs silently
4. ✅ Copies **public keys only** to `keys/` directory
5. ✅ Logs everything to `logs/` directory

**Next Step**: You need to import the teacher's public key using Veyon Configurator

---

## 🔑 Key Management Workflow

### On Teacher Computer:

```bash
# Run installer
python menu.py
# Choose option 1

# After installation, copy the public key
# Location: keys/public/supervisor/key
```

### On Each Student Computer:

**Option A - Use this installer:**
```bash
# Run installer
python menu.py
# Choose option 2

# Then copy teacher's public key to:
# keys/public/supervisor/key
```

**Option B - Manual with Veyon Configurator:**
1. Install Veyon (option 2)
2. Open Veyon Configurator
3. Import teacher's public key

---

## 📝 Example Session

```
+===========================================================================+
|                        Veyon Installer Suite                              |
+===========================================================================+

Available Scripts (lib):
  1) install_teacher.py         - Veyon Teacher Installation Script
  2) install_student.py         - Veyon Student Installation Script

  r) Reload menu
  e) Run external script by path
  0) Exit

Choose an option (number/r/e/0): 1

[INFO] install_teacher: Starting
[DEBUG] Querying GitHub API: https://api.github.com/repos/veyon/veyon/releases/latest
[INFO] Latest release: v4.10.0
[INFO] Found asset: veyon-4.10.0.0-win64-setup.exe
[INFO] Remote SHA256: e0cb164a6b5f73e9055b84753783a691bd4f57ff2a92e6124328956ba84eb618
[INFO] Downloading...
Downloading: 100% (45.2 MB / 45.2 MB)
[INFO] Download complete
[INFO] Local SHA256: e0cb164a6b5f73e9055b84753783a691bd4f57ff2a92e6124328956ba84eb618
[INFO] SHA256 verified successfully - checksums match!
[INFO] Starting silent installation
[INFO] Installer exited with code 0
[INFO] Successfully copied 2 key(s)
[INFO] install_teacher: Completed successfully

Press Enter to continue...
```

---

## ❓ Common Issues

### "Module not found: requests"
```bash
pip install requests colorama
```

### "No keys found after installation"
**Solution**: Run Veyon Configurator and generate keys manually, then re-run the script.

### "Permission denied" (Windows)
**Solution**: Right-click `menu.py` → "Run as Administrator"

### "SHA256 mismatch"
**Solution**: Check internet connection and try again. Script will not install if checksum fails.

---

## 🐧 Linux Users

The installer works on Linux too! But Veyon installation works differently:

```bash
# Install Veyon using apt
sudo apt install veyon

# Keys are located at
~/.veyon/keys/
```

The Python scripts will detect Linux and skip the Windows installer, but will still organize keys for you.

---

## 📁 Where Everything Goes

```
veyon-installer-suite/
├── menu.py                    ← Start here!
├── requirements.txt           ← Dependencies
├── lib/
│   ├── logger.py             ← Logging system
│   ├── install_teacher.py    ← Teacher installer
│   ├── install_student.py    ← Student installer
│   └── temp/                 ← Downloaded installers (auto-cleaned)
├── logs/
│   └── PC-ADMIN_260215_120652.log  ← Timestamped logs
└── keys/
    ├── private/supervisor/key     ← TEACHER ONLY - Keep secure!
    └── public/supervisor/key      ← Distribute to students
```

---

## 🎯 Pro Tips

1. **Always check logs** if something goes wrong: `logs/COMPUTERNAME_YYMMDD_HHMMSS.log`

2. **Backup private keys** immediately after teacher installation!

3. **Test on one student machine** before deploying to entire lab

4. **Use network share** to distribute public keys to all student machines at once

5. **Automate student deployment** using Group Policy or similar tools

---

## ✅ You're Ready!

Just run `python menu.py` and follow the prompts. Everything is automated!

Questions? Check the full `README.md` or examine the logs in `logs/` directory.
