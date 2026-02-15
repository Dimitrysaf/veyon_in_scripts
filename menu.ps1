# Standardized PowerShell Menu - menu.ps1

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$libDir = Join-Path $scriptDir 'lib'
if (-not (Test-Path $libDir)) { New-Item -ItemType Directory -Path $libDir | Out-Null }

# Debug tracing to file for headless diagnostics
# logs directory
$logDir = Join-Path -Path $scriptDir -ChildPath 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
# remove legacy debug log if present
$legacyDebug = Join-Path -Path $logDir -ChildPath 'menu_debug.log'
if (Test-Path $legacyDebug) { Remove-Item -Path $legacyDebug -Force -ErrorAction SilentlyContinue }

# Load logger if available
try {
    $loggerPath = Join-Path $libDir 'logger.psm1'
    
    if (Test-Path $loggerPath) { Import-Module $loggerPath -Force -Scope Local }
    if (Get-Command -Name Init-Logger -ErrorAction SilentlyContinue) {
        Init-Logger -RootPath $scriptDir
        Write-Log -Level 'INFO' -Message 'Menu started.'
        
    }
} catch {
    Write-Host "Warning: logger failed to load: $_" -ForegroundColor Yellow
    
    try {
        $errLogDir = Join-Path -Path $scriptDir -ChildPath 'logs'
        if (-not (Test-Path $errLogDir)) { New-Item -ItemType Directory -Path $errLogDir | Out-Null }
        $errFile = Join-Path -Path $errLogDir -ChildPath 'menu_import_error.log'
        Add-Content -Path $errFile -Value ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Logger import failed: $_")
    } catch {}
}

Write-Host "menu.ps1: startup OK" -ForegroundColor Cyan
 

function Write-Header {
    Clear-Host
    $cols = 80
    try { $cols = (Get-Host).UI.RawUI.WindowSize.Width } catch {}
    if ($cols -lt 40) { $cols = 40 }
    $title = ' PowerShell Command Menu '
    $line = ''.PadLeft($cols - 2, '=')
    Write-Host ('+' + $line + '+') -ForegroundColor Cyan
    $padLeft = [int](($cols - 2 - $title.Length) / 2)
    $padRight = $cols - 2 - $title.Length - $padLeft
    $middle = ('|' + (' ' * $padLeft) + $title + (' ' * $padRight) + '|')
    Write-Host $middle -ForegroundColor Yellow
    Write-Host ('+' + $line + '+') -ForegroundColor Cyan
}

function Show-Menu {
    Write-Header
    Write-Host ""
    Write-Host "Available Libraries (lib):" -ForegroundColor Green
    $files = @()
    try { $files = Get-ChildItem -Path $libDir -Filter *.ps1 -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'logger.psm1' } | Sort-Object Name } catch {}
    if ($files.Count -eq 0) {
        Write-Host "  (No scripts found in 'lib' folder.)" -ForegroundColor DarkYellow
    } else {
        $i = 1
        foreach ($f in $files) {
            $name = $f.Name
            $text = "  $i) $name"
            Write-Host $text -ForegroundColor White
            $i++
        }
    }
    Write-Host ""
    Write-Host "  r) Reload menu" -ForegroundColor Gray
    Write-Host "  e) Run external script by path" -ForegroundColor Gray
    Write-Host "  0) Exit" -ForegroundColor Magenta
    Write-Host ""
}

try {
    
    while ($true) {
        Show-Menu
        $choice = Read-Host "Choose an option (number/r/e/0)"
        
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log -Level 'DEBUG' -Message "User choice: $choice" }
        if ($choice -eq '0') { break }
        elseif ($choice -eq 'r') { continue }
        elseif ($choice -eq 'e') {
            $path = Read-Host "Enter path to script"
            
            if ([string]::IsNullOrWhiteSpace($path)) { Write-Host "No path provided." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue }
            if (-not (Test-Path $path)) { Write-Host "File not found: $path" -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
            if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log -Level 'INFO' -Message "Running external script: $path" }
            try { & $path } catch { if (Get-Command -Name Write-Exception -ErrorAction SilentlyContinue) { Write-Exception -ErrorRecord $_ } }
            Read-Host "Press Enter to continue..."
            continue
        }
        else {
            $files = @()
            try { $files = Get-ChildItem -Path $libDir -Filter *.ps1 -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'logger.psm1' } | Sort-Object Name } catch {}
            $isInt = $false
            try { $tmp = [int]$choice; $isInt = $true } catch { $isInt = $false }
            if ($isInt) {
                $idx = [int]$choice - 1
                if ($idx -ge 0 -and $idx -lt $files.Count) {
                    $script = $files[$idx].FullName
                    
                    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log -Level 'INFO' -Message "Running library script: $script" }
                    try { & $script } catch { if (Get-Command -Name Write-Exception -ErrorAction SilentlyContinue) { Write-Exception -ErrorRecord $_ } }
                    Read-Host "Press Enter to continue..."
                    continue
                } else {
                    Write-Host "Invalid selection." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue
                }
            } else {
                Write-Host "Invalid input." -ForegroundColor Yellow; Start-Sleep -Seconds 1; continue
            }
        }
    }
} catch {
    if (Get-Command -Name Write-Exception -ErrorAction SilentlyContinue) { Write-Exception -ErrorRecord $_ }
    else { Write-Host "Fatal error: $_" -ForegroundColor Red }
} finally {
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) { Write-Log -Level 'INFO' -Message 'Menu exiting.' }
    Write-Host "Goodbye!" -ForegroundColor Green
}
