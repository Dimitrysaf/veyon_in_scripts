PowerShell Menu Application

Files:
- menu.ps1 — main interactive, standardized menu
- lib/ — put your `.ps1` helper scripts or libraries here (see `lib/README.md`)

Run (PowerShell Core on Linux/macOS):

```bash
pwsh ./menu.ps1
```

On Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\menu.ps1
```

On Linux/macOS make the script executable and run it directly (or use `pwsh`):

```bash
chmod +x ./menu.ps1
./menu.ps1
# or
pwsh ./menu.ps1
```

Usage: place your scripts into the `commands` folder and run the menu. Choose a numbered option to execute a command, or press `e` to run any script by path.
