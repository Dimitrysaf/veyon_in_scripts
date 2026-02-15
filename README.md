# Veyon Installer Suite

Python-based automated installer for Veyon classroom management software.

## Features

- ✅ **Automatic Updates**: Fetches latest Veyon release from GitHub API
- ✅ **SHA256 Verification**: Verifies installer integrity before installation
- ✅ **Silent Installation**: Automated silent installation on Windows
- ✅ **Key Management**: Automatically copies Veyon keys to organized directory structure
- ✅ **Colored Logging**: Beautiful colored console output with file logging
- ✅ **Cross-Platform Ready**: Works on Windows (primary) and Linux (future)

## Directory Structure

```
/
├── menu.py                          # Main menu interface
├── requirements.txt                 # Python dependencies
├── lib/
│   ├── logger.py                   # Logging module
│   ├── install_teacher.py          # Teacher/supervisor installation
│   └── install_student.py          # Student machine installation
├── logs/
│   └── PC_ADMIN_260215_120652.log  # Timestamped log files
└── keys/
    ├── private/supervisor/key      # Private keys (teacher only)
    └── public/supervisor/key       # Public keys (all machines)
```

## Installation

### Prerequisites

1. **Python 3.7+** (Check: `python --version`)
2. **pip** (Check: `pip --version`)

### Setup

1. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

2. **Run the menu:**
   ```bash
   python menu.py
   ```

## Usage

### Interactive Menu

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

Choose an option (number/r/e/0):
```

### Teacher Installation

1. Select option `1` from menu
2. Script will:
   - Fetch latest Veyon release
   - Verify SHA256 checksum
   - Install silently
   - Copy **both private and public keys** to `keys/` directory

### Student Installation

1. Select option `2` from menu
2. Script will:
   - Fetch latest Veyon release
   - Verify SHA256 checksum
   - Install silently
   - Copy **public keys only** to `keys/` directory
   - Prompt to import teacher's public key

## Key Management

### Teacher/Supervisor Keys

After installation, keys are organized:

```
keys/
├── private/supervisor/key    # Keep secure - teacher only!
└── public/supervisor/key     # Distribute to all student machines
```

### Distributing Keys to Students

1. Copy `keys/public/supervisor/key` from teacher machine
2. Place in same location on each student machine
3. Or use Veyon Configurator to import keys

## Logging

All operations are logged with timestamps:

- **Location**: `logs/COMPUTERNAME_YYMMDD_HHMMSS.log`
- **Format**: `[2026-02-15 12:06:52] [INFO] Message here`
- **Levels**: DEBUG, INFO, WARNING, ERROR, CRITICAL

### Example Log Output

```
[2026-02-15 12:06:52] [INFO] Logger initialized. Log file: logs\PC-ADMIN_260215_120652.log
[2026-02-15 12:06:52] [INFO] Menu started.
[2026-02-15 12:06:54] [DEBUG] User choice: 1
[2026-02-15 12:06:54] [INFO] Running script: lib\install_teacher.py
[2026-02-15 12:06:54] [INFO] install_teacher: Starting
[2026-02-15 12:06:54] [DEBUG] Querying GitHub API: https://api.github.com/repos/veyon/veyon/releases/latest
[2026-02-15 12:06:54] [INFO] Latest release: v4.10.0
[2026-02-15 12:06:54] [INFO] Found asset: veyon-4.10.0.0-win64-setup.exe
[2026-02-15 12:06:54] [INFO] Remote SHA256: e0cb164a6b5f73e9055b84753783a691bd4f57ff2a92e6124328956ba84eb618
[2026-02-15 12:07:08] [INFO] Download complete
[2026-02-15 12:07:09] [INFO] Local SHA256: e0cb164a6b5f73e9055b84753783a691bd4f57ff2a92e6124328956ba84eb618
[2026-02-15 12:07:09] [INFO] SHA256 verified successfully - checksums match!
[2026-02-15 12:07:37] [INFO] Installer exited with code 0
[2026-02-15 12:07:37] [INFO] Successfully copied 2 key(s)
[2026-02-15 12:07:37] [INFO] install_teacher: Completed successfully
```

## Troubleshooting

### No Keys Found

**Symptom**: "Could not find Veyon keys directory"

**Solution**: 
1. Run Veyon Configurator manually
2. Generate key pair
3. Re-run the installation script

### SHA256 Mismatch

**Symptom**: "SHA256 VERIFICATION FAILED"

**Solution**:
1. Check your internet connection
2. Try downloading again
3. Verify you're not behind a proxy that modifies downloads

### Permission Denied (Windows)

**Symptom**: "Access is denied"

**Solution**:
1. Right-click `menu.py`
2. Select "Run as Administrator"

## Linux Support

While primarily designed for Windows, the scripts include Linux compatibility:

```bash
# Install Veyon on Linux
sudo apt install veyon

# Keys location on Linux
~/.veyon/keys/
```

## Development

### Adding New Scripts

1. Create script in `lib/` directory
2. Add docstring at the top:
   ```python
   """
   my_script.py - Brief description here
   """
   ```
3. Include main function: `install_teacher()`, `install_student()`, or `main()`
4. Script will automatically appear in menu

### Running Scripts Directly

```bash
# Teacher installation
python lib/install_teacher.py

# Student installation
python lib/install_student.py
```

## Dependencies

- **requests**: HTTP library for GitHub API and downloads
- **colorama**: Cross-platform colored terminal output

Install with:
```bash
pip install requests colorama
```

## Security Notes

⚠️ **Private Keys**: Keep `keys/private/` secure on teacher machines only!

✅ **Public Keys**: Safe to distribute to all student machines

✅ **SHA256 Verification**: All downloads are verified before installation

## License

This installer suite is a wrapper around Veyon software.

- **Veyon**: GPLv2 - https://github.com/veyon/veyon
- **This Suite**: Use freely for educational purposes

## Support

For Veyon-specific issues: https://github.com/veyon/veyon/issues

For installer issues: Check logs in `logs/` directory

## Credits

- **Veyon**: https://veyon.io
- **Developer**: Automated installation suite
