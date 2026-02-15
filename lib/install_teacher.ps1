<#
install_teacher.ps1
- Fetch latest veyon release via GitHub API
- Download win64 installer into script directory
- Verify SHA256 using checksum from release (if available)
- Run installer silently (/S)
- Log actions via `logger.psm1` if present
#>

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$cwd = $scriptDir

# load logger
$loggerPath = Join-Path $scriptDir 'logger.psm1'
if (Test-Path $loggerPath) { Import-Module $loggerPath -Force -Scope Local }
function Log {
    param($level, $msg)
    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Level $level -Message $msg
    } else {
        Write-Host ("{0}: {1}" -f $level, $msg)
    }
}

function LogEx {
    param($err)
    if (Get-Command -Name Write-Exception -ErrorAction SilentlyContinue) {
        Write-Exception -ErrorRecord $err
    } else {
        Write-Host ("EX: {0}" -f $err)
    }
}

try {
    Log INFO "install_teacher: Starting"
    $api = 'https://api.github.com/repos/veyon/veyon/releases/latest'
    $headers = @{ 'User-Agent' = 'PowerShell' }
    Log DEBUG "Querying GitHub API: $api"
    $rel = Invoke-RestMethod -Uri $api -Headers $headers -ErrorAction Stop
    $tag = $rel.tag_name
    Log INFO "Latest release: $tag"

    $assets = $rel.assets
    if (-not $assets) { throw "No assets found on release $tag" }

    # find 64-bit installer asset
    $asset64 = $assets | Where-Object { $_.name -match 'win64' -or $_.browser_download_url -match 'win64' } | Select-Object -First 1
    if (-not $asset64) { throw "No win64 asset found in release $tag" }
    $url64 = $asset64.browser_download_url
    $name64 = $asset64.name
    Log INFO "Found asset: $name64"

    # try to find checksum asset or inline hash
    $checksum = $null
    # first: look for an asset that contains sha or checksum
    $checksumAsset = $assets | Where-Object { $_.name -match 'sha256' -or $_.name -match 'checksums' -or $_.name -match 'sha256sums' } | Select-Object -First 1
    if ($checksumAsset) {
        Log DEBUG "Found checksum asset: $($checksumAsset.name)"
        $text = Invoke-RestMethod -Uri $checksumAsset.browser_download_url -Headers $headers -UseBasicParsing -ErrorAction Stop
        $lines = $text -split "\r?\n"
        foreach ($l in $lines) {
            if ($l -match '\\b([A-Fa-f0-9]{64})\\b') {
                if ($l -match [regex]::Escape($name64)) {
                    $checksum = ($matches[1]).ToLower()
                    break
                }
                # fallback: if only one hash present, use it
                if (-not $checksum) { $checksum = ($matches[1]).ToLower() }
            }
        }
    }

    # second: attempt to parse body text of release for hash lines
    if (-not $checksum -and $rel.body) {
        $b = $rel.body -split "\r?\n"
        foreach ($l in $b) {
            if ($l -match '\\b([A-Fa-f0-9]{64})\\b') {
                $checksum = ($matches[1]).ToLower()
                break
            }
        }
    }

    if ($checksum) { Log INFO "Remote checksum found: $checksum" } else { Log WARN "No remote checksum located; will compute local SHA and prompt" }

    # download with progress using HttpWebRequest stream (works on Windows PowerShell)
    $outFile = Join-Path -Path $cwd -ChildPath $name64
    if (Test-Path $outFile) { Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue }

    Log INFO "Downloading $url64 -> $outFile"
    $req = [System.Net.HttpWebRequest]::Create($url64)
    $req.Method = 'GET'
    $req.UserAgent = 'PowerShell'
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $stream = $resp.GetResponseStream()
    $outStream = [System.IO.File]::OpenWrite($outFile)
    try {
        $buffer = New-Object byte[] 81920
        $read = 0
        $downloaded = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outStream.Write($buffer, 0, $read)
            $downloaded += $read
            if ($total -gt 0) { $pct = [int]((($downloaded / $total) * 100)) } else { $pct = 0 }
            $kbRec = [math]::Round($downloaded / 1KB)
            $kbTot = if ($total -gt 0) { [math]::Round($total / 1KB) } else { 0 }
            Write-Progress -Activity "Downloading $name64" -Status "$pct% ($kbRec KB of $kbTot KB)" -PercentComplete $pct
        }
        Write-Progress -Activity "Downloading $name64" -Completed
        Log INFO "Download complete: $outFile"
    } finally {
        $outStream.Close()
        $stream.Close()
        $resp.Close()
    }

    # compute SHA256
    $localHash = (Get-FileHash -Algorithm SHA256 -Path $outFile).Hash.ToLower()
    Log INFO "Local SHA256: $localHash"

    if ($checksum) {
        if ($localHash -ne $checksum) { throw "SHA256 mismatch: remote $checksum != local $localHash" }
        Log INFO "SHA256 verified OK"
    } else {
        Log WARN "No remote checksum to compare; computed local SHA256: $localHash"
    }

    # run installer silently
    Log INFO "Starting silent install: $outFile"
    $proc = Start-Process -FilePath $outFile -ArgumentList '/S' -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Installer exited with code $($proc.ExitCode)" }
    Log INFO "Installer exited with code $($proc.ExitCode)"

    Log INFO "install_teacher: Completed successfully"
} catch {
    Log ERROR "install_teacher failed: $_"
    LogEx $_
    throw
}
*** End Patch