Lib folder

Place any PowerShell helper scripts or small libraries you want the menu to show or load in this folder.

- `logger.psm1` — logging module (created automatically). Do not delete unless you know what you're doing.
- Other `.ps1` scripts placed here will be listed by `menu.ps1` and can be executed from the menu.

Example:

Create `hello-world.ps1` in this folder:

```powershell
Write-Host "Hello from lib/hello-world.ps1" -ForegroundColor Green
```

Then run the menu and choose the corresponding number.
