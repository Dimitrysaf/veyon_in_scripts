<#
.SYNOPSIS
    Veyon Installation and Configuration Tool
.DESCRIPTION
    Comprehensive tool for installing, configuring, and managing Veyon classroom management software.
    Compatible with SEPEHY manual standards.
.NOTES
    Version: 2.0
    Author: System Administrator
    Requires: PowerShell 5.1 or higher, Administrator privileges
#>

#Requires -RunAsAdministrator

# Script configuration
$script:Config = @{
    VeyonGitHubAPI = "https://api.github.com/repos/veyon/veyon/releases/latest"
    VeyonDownloadUrl = $null  # Will be determined dynamically
    VeyonVersion = $null      # Will be determined dynamically
    VeyonInstallerPath = "$env:TEMP\veyon-setup.exe"
    VeyonConfigPath = "$env:ProgramData\Veyon\config.json"
    KeysBasePath = "$env:ProgramData\Veyon\keys"
    LogPath = "$env:ProgramData\Veyon\setup.log"
    ExpectedSHA256 = $null    # Will be fetched or verified
    ManualUrls = @{
        Admin = "https://docs.veyon.io/en/latest/admin/index.html"
        User = "https://docs.veyon.io/en/latest/user/index.html"
    }
}

# Color scheme for UI
$script:Colors = @{
    Header = 'Cyan'
    Success = 'Green'
    Warning = 'Yellow'
    Error = 'Red'
    Info = 'White'
    Prompt = 'Magenta'
}

# Reusable separator line (80 characters)
$script:Line80 = (-join (1..80 | ForEach-Object { '=' }))

#region Helper Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Ensure log directory exists
    $logDir = Split-Path $script:Config.LogPath
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Add-Content -Path $script:Config.LogPath -Value $logMessage
    
    $color = switch ($Level) {
        'Success' { $script:Colors.Success }
        'Warning' { $script:Colors.Warning }
        'Error' { $script:Colors.Error }
        default { $script:Colors.Info }
    }
    
    Write-Host $logMessage -ForegroundColor $color
}

function Show-Header {
    Clear-Host
    Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
    Write-Host " VEYON INSTALLATION & CONFIGURATION TOOL v2.0" -ForegroundColor $script:Colors.Header
    Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
    Write-Host ""
}

function Show-Progress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )
    
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

function Invoke-MenuSelection {
    param(
        [string]$Title,
        [string[]]$Options,
        [switch]$AllowMultiple
    )
    
    Show-Header
    Write-Host $Title -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Options[$i])" -ForegroundColor $script:Colors.Info
    }
    Write-Host "  [0] Back to Main Menu" -ForegroundColor $script:Colors.Warning
    Write-Host ""
    
    if ($AllowMultiple) {
        $prompt = "Enter your choices (comma-separated, e.g., 1,3,5)"
    } else {
        $prompt = "Enter your choice"
    }
    
    do {
        $input = Read-Host $prompt
        if ($input -eq '0') { return $null }
        
        if ($AllowMultiple) {
            $selections = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
            $validSelections = $selections | Where-Object { [int]$_ -ge 1 -and [int]$_ -le $Options.Count }
            if ($validSelections.Count -gt 0) {
                return $validSelections | ForEach-Object { [int]$_ - 1 }
            }
        } else {
            if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le $Options.Count) {
                return [int]$input - 1
            }
        }
        
        Write-Host "Invalid selection. Please try again." -ForegroundColor $script:Colors.Error
    } while ($true)
}

function Test-VeyonInstalled {
    $veyonPath = "C:\Program Files\Veyon\veyon-configurator.exe"
    return Test-Path $veyonPath
}

function Get-SystemInfo {
    Show-Progress -Activity "Gathering System Information" -Status "Collecting data..." -PercentComplete 0
    
    Start-Sleep -Milliseconds 200
    Show-Progress -Activity "Gathering System Information" -Status "Reading hardware info..." -PercentComplete 20
    
    $computerSystem = Get-WmiObject Win32_ComputerSystem
    $os = Get-WmiObject Win32_OperatingSystem
    
    Show-Progress -Activity "Gathering System Information" -Status "Reading network configuration..." -PercentComplete 40
    
    $ipAddress = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress -join ", "
    $macAddress = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).MacAddress
    
    Show-Progress -Activity "Gathering System Information" -Status "Checking Veyon installation..." -PercentComplete 60
    
    $veyonInstalled = Test-VeyonInstalled
    $veyonVersion = if ($veyonInstalled) { 
        try {
            (Get-ItemProperty "C:\Program Files\Veyon\veyon-configurator.exe" -ErrorAction SilentlyContinue).VersionInfo.FileVersion 
        } catch {
            "Unknown"
        }
    } else { 
        "Not Installed" 
    }
    
    Show-Progress -Activity "Gathering System Information" -Status "Finalizing..." -PercentComplete 80
    
    $info = @{
        ComputerName = $env:COMPUTERNAME
        Domain = $computerSystem.Domain
        OSVersion = $os.Caption
        OSArchitecture = $os.OSArchitecture
        RAM = [math]::Round($computerSystem.TotalPhysicalMemory / 1GB, 2)
        IPAddress = $ipAddress
        MACAddress = $macAddress
        CurrentUser = $env:USERNAME
        VeyonInstalled = $veyonInstalled
        VeyonVersion = $veyonVersion
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    Show-Progress -Activity "Gathering System Information" -Status "Complete" -PercentComplete 100
    Start-Sleep -Milliseconds 500
    Write-Progress -Activity "Gathering System Information" -Completed
    
    return $info
}

function Export-SystemInfo {
    param(
        [hashtable]$SystemInfo,
        [ValidateSet('JSON', 'CSV', 'TXT')]
        [string]$Format
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filename = "$($SystemInfo.ComputerName)_$timestamp"
    
    Show-Progress -Activity "Exporting System Information" -Status "Preparing export..." -PercentComplete 20
    
    switch ($Format) {
        'JSON' {
            $outputPath = Join-Path $PWD "$filename.json"
            Show-Progress -Activity "Exporting System Information" -Status "Writing JSON file..." -PercentComplete 60
            $SystemInfo | ConvertTo-Json -Depth 10 | Out-File $outputPath -Encoding UTF8
        }
        'CSV' {
            $outputPath = Join-Path $PWD "$filename.csv"
            Show-Progress -Activity "Exporting System Information" -Status "Writing CSV file..." -PercentComplete 60
            $SystemInfo.GetEnumerator() | Select-Object Name, Value | Export-Csv $outputPath -NoTypeInformation
        }
        'TXT' {
            $outputPath = Join-Path $PWD "$filename.txt"
            Show-Progress -Activity "Exporting System Information" -Status "Writing TXT file..." -PercentComplete 60
            $output = @"
SYSTEM INFORMATION REPORT
Generated: $($SystemInfo.Timestamp)
$script:Line80

Computer Name: $($SystemInfo.ComputerName)
Domain: $($SystemInfo.Domain)
OS Version: $($SystemInfo.OSVersion)
OS Architecture: $($SystemInfo.OSArchitecture)
RAM: $($SystemInfo.RAM) GB
IP Address: $($SystemInfo.IPAddress)
MAC Address: $($SystemInfo.MACAddress)
Current User: $($SystemInfo.CurrentUser)
Veyon Installed: $($SystemInfo.VeyonInstalled)
Veyon Version: $($SystemInfo.VeyonVersion)
"@
            $output | Out-File $outputPath -Encoding UTF8
        }
    }
    
    Show-Progress -Activity "Exporting System Information" -Status "Complete" -PercentComplete 100
    Start-Sleep -Milliseconds 300
    Write-Progress -Activity "Exporting System Information" -Completed
    
    Write-Log "System information exported to: $outputPath" -Level Success
    return $outputPath
}

function Get-FileSHA256Hash {
    param(
        [string]$FilePath
    )
    
    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
        return $hash.Hash
    } catch {
        Write-Log "Failed to calculate SHA256 hash: $_" -Level Error
        return $null
    }
}

function Test-FileIntegrity {
    param(
        [string]$FilePath,
        [string]$ExpectedHash
    )
    
    Show-Progress -Activity "Verifying File Integrity" -Status "Calculating SHA256 hash..." -PercentComplete 50
    
    $actualHash = Get-FileSHA256Hash -FilePath $FilePath
    
    if ($null -eq $actualHash) {
        Show-Progress -Activity "Verifying File Integrity" -Status "Failed" -PercentComplete 100
        Write-Progress -Activity "Verifying File Integrity" -Completed
        return $false
    }
    
    Show-Progress -Activity "Verifying File Integrity" -Status "Comparing hashes..." -PercentComplete 80
    Start-Sleep -Milliseconds 200
    
    $match = $actualHash -eq $ExpectedHash
    
    Show-Progress -Activity "Verifying File Integrity" -Status "Complete" -PercentComplete 100
    Start-Sleep -Milliseconds 300
    Write-Progress -Activity "Verifying File Integrity" -Completed
    
    if ($match) {
        Write-Log "File integrity verified successfully" -Level Success
        Write-Host "SHA256 Hash: $actualHash" -ForegroundColor $script:Colors.Success
    } else {
        Write-Log "File integrity check FAILED!" -Level Error
        Write-Host "Expected: $ExpectedHash" -ForegroundColor $script:Colors.Error
        Write-Host "Actual:   $actualHash" -ForegroundColor $script:Colors.Error
    }
    
    return $match
}

function Get-LatestVeyonRelease {
    Show-Progress -Activity "Checking for Latest Veyon Version" -Status "Contacting GitHub API..." -PercentComplete 30
    
    try {
        # Set TLS 1.2 for GitHub API
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        Write-Log "Fetching latest Veyon release information from GitHub"
        
        $release = Invoke-RestMethod -Uri $script:Config.VeyonGitHubAPI -Method Get -ErrorAction Stop
        
        Show-Progress -Activity "Checking for Latest Veyon Version" -Status "Processing release data..." -PercentComplete 70
        
        $script:Config.VeyonVersion = $release.tag_name -replace '^v', ''
        Write-Log "Latest Veyon version: $($script:Config.VeyonVersion)" -Level Info
        
        # Find the Windows 64-bit installer
        $asset = $release.assets | Where-Object { $_.name -match 'win64-setup\.exe$' } | Select-Object -First 1
        
        if ($asset) {
            $script:Config.VeyonDownloadUrl = $asset.browser_download_url
            Write-Log "Download URL: $($script:Config.VeyonDownloadUrl)" -Level Info
            
            Show-Progress -Activity "Checking for Latest Veyon Version" -Status "Complete" -PercentComplete 100
            Start-Sleep -Milliseconds 300
            Write-Progress -Activity "Checking for Latest Veyon Version" -Completed
            
            return @{
                Version = $script:Config.VeyonVersion
                DownloadUrl = $script:Config.VeyonDownloadUrl
                Size = [math]::Round($asset.size / 1MB, 2)
                PublishedDate = $release.published_at
            }
        } else {
            throw "Could not find Windows 64-bit installer in release assets"
        }
        
    } catch {
        Write-Log "Failed to fetch latest Veyon release: $_" -Level Error
        Write-Progress -Activity "Checking for Latest Veyon Version" -Completed
        
        # Fallback to hardcoded version
        Write-Log "Falling back to hardcoded version 4.10.0" -Level Warning
        $script:Config.VeyonVersion = "4.10.0"
        $script:Config.VeyonDownloadUrl = "https://github.com/veyon/veyon/releases/download/v4.10.0/veyon-4.10.0-win64-setup.exe"
        
        return @{
            Version = $script:Config.VeyonVersion
            DownloadUrl = $script:Config.VeyonDownloadUrl
            Size = "Unknown"
            PublishedDate = "Unknown"
        }
    }
}

#endregion

#region Veyon Installation Functions

function Install-Veyon {
    Show-Header
    Write-Host "VEYON INSTALLATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    # Check if already installed
    if (Test-VeyonInstalled) {
        $currentVersion = try {
            (Get-ItemProperty "C:\Program Files\Veyon\veyon-configurator.exe" -ErrorAction SilentlyContinue).VersionInfo.FileVersion
        } catch {
            "Unknown"
        }
        
        Write-Host "Veyon is already installed on this system." -ForegroundColor $script:Colors.Warning
        Write-Host "Current version: $currentVersion" -ForegroundColor $script:Colors.Info
        Write-Host ""
        $reinstall = Read-Host "Do you want to reinstall/upgrade? (y/N)"
        if ($reinstall -ne 'y') {
            return
        }
    }
    
    # ASK FOR INSTALLATION MODE - TEACHER OR STUDENT
    Write-Host ""
    Write-Host "INSTALLATION MODE" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "  [1] Teacher Computer (Install Master + Service)" -ForegroundColor $script:Colors.Info
    Write-Host "  [2] Student Computer (Install Service only, NO Master)" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    do {
        $modeChoice = Read-Host "Select installation mode (1 or 2)"
        if ($modeChoice -eq '1' -or $modeChoice -eq '2') {
            break
        }
        Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor $script:Colors.Error
    } while ($true)
    
    $isTeacher = ($modeChoice -eq '1')
    
    if ($isTeacher) {
        Write-Host ""
        Write-Host "Installing in TEACHER mode (with Master application)..." -ForegroundColor $script:Colors.Success
        $installMode = "Teacher"
    } else {
        Write-Host ""
        Write-Host "Installing in STUDENT mode (Service only, NO Master)..." -ForegroundColor $script:Colors.Success
        $installMode = "Student"
    }
    
    Write-Log "Installation mode selected: $installMode"
    Start-Sleep -Seconds 2
    
    try {
        # Get latest version info
        Write-Host "Fetching latest Veyon version information..." -ForegroundColor $script:Colors.Info
        $releaseInfo = Get-LatestVeyonRelease
        
        Write-Host ""
        Write-Host "Latest Veyon Version: $($releaseInfo.Version)" -ForegroundColor $script:Colors.Success
        Write-Host "File Size: $($releaseInfo.Size) MB" -ForegroundColor $script:Colors.Info
        Write-Host "Published: $($releaseInfo.PublishedDate)" -ForegroundColor $script:Colors.Info
        Write-Host ""
        
        $confirm = Read-Host "Proceed with installation? (Y/n)"
        if ($confirm -eq 'n') {
            Write-Host "Installation cancelled." -ForegroundColor $script:Colors.Warning
            Read-Host "Press Enter to continue"
            return
        }
        
        # Download installer
        Show-Progress -Activity "Installing Veyon" -Status "Downloading installer..." -PercentComplete 10
        Write-Log "Downloading Veyon installer from $($script:Config.VeyonDownloadUrl)"
        Write-Host ""
        Write-Host "Downloading Veyon $($releaseInfo.Version)..." -ForegroundColor $script:Colors.Info
        
        $downloadSuccess = $false
        
        # Try BITS first (if available and user is logged on to network)
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            
            if ((Get-Service BITS).Status -eq 'Running') {
                Write-Log "Attempting download using BITS transfer"
                Start-BitsTransfer -Source $script:Config.VeyonDownloadUrl -Destination $script:Config.VeyonInstallerPath -DisplayName "Downloading Veyon" -Description "Downloading Veyon installer..." -ErrorAction Stop
                Show-Progress -Activity "Installing Veyon" -Status "Download complete" -PercentComplete 40
                $downloadSuccess = $true
                Write-Log "Download completed using BITS"
            }
        } catch {
            Write-Log "BITS transfer failed or unavailable: $_" -Level Warning
            Write-Host "Note: BITS transfer unavailable, using alternative method..." -ForegroundColor $script:Colors.Warning
        }
        
        # Fallback to Invoke-WebRequest (most reliable)
        if (-not $downloadSuccess) {
            try {
                Write-Log "Using Invoke-WebRequest for download"
                Write-Host "Downloading using standard HTTP method..." -ForegroundColor $script:Colors.Info
                
                # Ensure TLS 1.2
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                
                # Download with progress
                $ProgressPreference = 'SilentlyContinue'  # Suppress Invoke-WebRequest progress bar
                
                # Start download
                $startTime = Get-Date
                Invoke-WebRequest -Uri $script:Config.VeyonDownloadUrl -OutFile $script:Config.VeyonInstallerPath -UseBasicParsing
                
                $downloadTime = ((Get-Date) - $startTime).TotalSeconds
                Write-Log "Download completed in $([math]::Round($downloadTime, 2)) seconds"
                
                Show-Progress -Activity "Installing Veyon" -Status "Download complete" -PercentComplete 40
                $downloadSuccess = $true
                
            } catch {
                Write-Log "Invoke-WebRequest failed: $_" -Level Error
            }
        }
        
        # Last resort: WebClient
        if (-not $downloadSuccess) {
            try {
                Write-Log "Using WebClient as last resort"
                Write-Host "Using fallback download method..." -ForegroundColor $script:Colors.Warning
                
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $webClient = New-Object System.Net.WebClient
                $webClient.DownloadFile($script:Config.VeyonDownloadUrl, $script:Config.VeyonInstallerPath)
                
                Show-Progress -Activity "Installing Veyon" -Status "Download complete" -PercentComplete 40
                $downloadSuccess = $true
                Write-Log "Download completed using WebClient"
                
            } catch {
                Write-Log "WebClient download failed: $_" -Level Error
                throw "All download methods failed. Please check your internet connection and try again."
            }
        }
        
        # Restore progress preference
        $ProgressPreference = 'Continue'
        
        if (!(Test-Path $script:Config.VeyonInstallerPath)) {
            throw "Failed to download Veyon installer"
        }
        
        $actualSize = (Get-Item $script:Config.VeyonInstallerPath).Length / 1MB
        Write-Host "Download complete! Size: $([math]::Round($actualSize, 2)) MB" -ForegroundColor $script:Colors.Success
        Write-Host ""
        
        # SHA256 verification
        Show-Progress -Activity "Installing Veyon" -Status "Verifying file integrity..." -PercentComplete 45
        Write-Host "Verifying file integrity..." -ForegroundColor $script:Colors.Info
        
        $calculatedHash = Get-FileSHA256Hash -FilePath $script:Config.VeyonInstallerPath
        Write-Host "SHA256: $calculatedHash" -ForegroundColor $script:Colors.Info
        Write-Log "Downloaded file SHA256: $calculatedHash" -Level Info
        
        # Optional: Compare with known hash if available
        if ($script:Config.ExpectedSHA256) {
            $isValid = Test-FileIntegrity -FilePath $script:Config.VeyonInstallerPath -ExpectedHash $script:Config.ExpectedSHA256
            if (-not $isValid) {
                $continue = Read-Host "`nFile integrity check failed! Continue anyway? (y/N)"
                if ($continue -ne 'y') {
                    throw "Installation cancelled due to integrity check failure"
                }
            }
        } else {
            Write-Host "Note: No reference hash available for automatic verification." -ForegroundColor $script:Colors.Warning
            Write-Host "Please verify the hash manually if needed." -ForegroundColor $script:Colors.Warning
        }
        
        Write-Host ""
        
        # Run installer
        Show-Progress -Activity "Installing Veyon" -Status "Running installer..." -PercentComplete 60
        Write-Log "Running Veyon installer"
        Write-Host "Installing Veyon... This may take a few minutes." -ForegroundColor $script:Colors.Info
        
        # Check if config exists for import
        $configArg = ""
        if (Test-Path $script:Config.VeyonConfigPath) {
            $configArg = " /ApplyConfig=`"$($script:Config.VeyonConfigPath)`""
            Write-Log "Will apply existing configuration after installation"
        }
        
        # CRITICAL: Add /NoMaster for STUDENT installations
        $noMasterArg = ""
        if (-not $isTeacher) {
            $noMasterArg = " /NoMaster"
            Write-Log "Installing WITHOUT Master application (Student mode)"
        } else {
            Write-Log "Installing WITH Master application (Teacher mode)"
        }
        
        $installArgs = "/S$configArg$noMasterArg"
        Write-Log "Installer arguments: $installArgs"
        
        Show-Progress -Activity "Installing Veyon" -Status "Installing components..." -PercentComplete 70
        $process = Start-Process -FilePath $script:Config.VeyonInstallerPath -ArgumentList $installArgs -Wait -PassThru
        
        Show-Progress -Activity "Installing Veyon" -Status "Finalizing installation..." -PercentComplete 90
        
        if ($process.ExitCode -ne 0) {
            throw "Veyon installation failed with exit code: $($process.ExitCode)"
        }
        
        Show-Progress -Activity "Installing Veyon" -Status "Installation complete" -PercentComplete 100
        Start-Sleep -Milliseconds 500
        Write-Progress -Activity "Installing Veyon" -Completed
        
        Write-Log "Veyon $($releaseInfo.Version) installed successfully" -Level Success
        
        # Cleanup
        Write-Host ""
        Write-Host "Cleaning up temporary files..." -ForegroundColor $script:Colors.Info
        Remove-Item $script:Config.VeyonInstallerPath -Force -ErrorAction SilentlyContinue
        
        # FOR TEACHER MODE: Export authentication keys to PWD
        if ($isTeacher) {
            Write-Host ""
            Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
            Write-Host " TEACHER MODE: Exporting Keys" -ForegroundColor $script:Colors.Header
            Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
            Write-Host ""
            
            $keysSourcePath = "C:\ProgramData\Veyon\keys"
            $keysDestPath = Join-Path $PWD "keys"

            # Ensure keys exist; if not, attempt to generate and export them automatically
            try {
                $generatedOrPresent = Ensure-TeacherKeys -KeyName 'supervisor' -ExportPath $keysDestPath

                if ($generatedOrPresent -and (Test-Path $keysDestPath)) {
                    Write-Host "" 
                    Write-Host "Authentication keys exported successfully!" -ForegroundColor $script:Colors.Success
                    Write-Host "Location: $keysDestPath" -ForegroundColor $script:Colors.Success
                    Write-Host ""
                    Write-Host "IMPORTANT: Copy this 'keys' folder to student computers!" -ForegroundColor $script:Colors.Warning
                    Write-Host "Place it in the same directory as the VeyonSetup.ps1 script on student computers." -ForegroundColor $script:Colors.Warning
                    Write-Host ""
                    Write-Log "Teacher keys exported to: $keysDestPath" -Level Success
                } else {
                    Write-Host "Note: No keys found and automatic generation/export failed." -ForegroundColor $script:Colors.Warning
                    Write-Host "You can manually generate keys using the Configuration menu or copy keys from another teacher." -ForegroundColor $script:Colors.Info
                    Write-Host "Keys would normally be at: $keysSourcePath" -ForegroundColor $script:Colors.Info
                }
            } catch {
                Write-Log "Failed while ensuring/exporting keys: $_" -Level Error
                Write-Host "Warning: Could not export keys: $_" -ForegroundColor $script:Colors.Warning
                Write-Host "You can manually copy keys from: $keysSourcePath" -ForegroundColor $script:Colors.Info
            }
        }
        
        # FOR STUDENT MODE: Import authentication keys from PWD
        if (-not $isTeacher) {
            Write-Host ""
            Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
            Write-Host " STUDENT MODE: Importing Keys" -ForegroundColor $script:Colors.Header
            Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
            Write-Host ""
            
            $keysSourcePath = Join-Path $PWD "keys"
            $keysDestPath = "C:\ProgramData\Veyon\keys"
            
            if (Test-Path $keysSourcePath) {
                try {
                    Show-Progress -Activity "Importing Keys" -Status "Checking for authentication keys..." -PercentComplete 30
                    
                    Write-Host "Found keys in script directory!" -ForegroundColor $script:Colors.Success
                    Write-Host "Source: $keysSourcePath" -ForegroundColor $script:Colors.Info
                    
                    Show-Progress -Activity "Importing Keys" -Status "Copying keys to Veyon directory..." -PercentComplete 60
                    
                    # Ensure destination exists
                    if (!(Test-Path $keysDestPath)) {
                        New-Item -ItemType Directory -Path $keysDestPath -Force | Out-Null
                    }
                    
                    # Copy all keys (public and private folders)
                    Copy-Item -Path "$keysSourcePath\*" -Destination $keysDestPath -Recurse -Force
                    
                    Show-Progress -Activity "Importing Keys" -Status "Setting permissions..." -PercentComplete 80
                    Start-Sleep -Milliseconds 300
                    
                    # Set proper permissions for keys
                    # Public keys should be readable by everyone
                    $publicKeyPath = Join-Path $keysDestPath "public"
                    if (Test-Path $publicKeyPath) {
                        icacls $publicKeyPath /grant "Users:(OI)(CI)R" /T /Q | Out-Null
                        Write-Log "Set read permissions for public keys"
                    }
                    
                    # Private keys should be restricted (if they exist - usually only on teacher)
                    $privateKeyPath = Join-Path $keysDestPath "private"
                    if (Test-Path $privateKeyPath) {
                        icacls $privateKeyPath /inheritance:r /T /Q | Out-Null
                        icacls $privateKeyPath /grant "SYSTEM:(OI)(CI)F" /T /Q | Out-Null
                        icacls $privateKeyPath /grant "Administrators:(OI)(CI)F" /T /Q | Out-Null
                        Write-Log "Set restricted permissions for private keys"
                    }
                    
                    Show-Progress -Activity "Importing Keys" -Status "Complete" -PercentComplete 100
                    Start-Sleep -Milliseconds 300
                    Write-Progress -Activity "Importing Keys" -Completed
                    
                    Write-Host ""
                    Write-Host "Authentication keys imported successfully!" -ForegroundColor $script:Colors.Success
                    Write-Host "Destination: $keysDestPath" -ForegroundColor $script:Colors.Success
                    Write-Host ""
                    Write-Host "This student computer is now ready to be controlled!" -ForegroundColor $script:Colors.Success
                    Write-Host ""
                    Write-Log "Student keys imported from: $keysSourcePath" -Level Success
                    
                } catch {
                    Write-Log "Failed to import keys: $_" -Level Error
                    Write-Host "Warning: Could not import keys: $_" -ForegroundColor $script:Colors.Warning
                    Write-Host ""
                    Write-Host "Manual import steps:" -ForegroundColor $script:Colors.Info
                    Write-Host "1. Copy the 'keys' folder from teacher computer" -ForegroundColor $script:Colors.Info
                    Write-Host "2. Place it in the same directory as this script" -ForegroundColor $script:Colors.Info
                    Write-Host "3. Run the installation again" -ForegroundColor $script:Colors.Info
                }
            } else {
                Write-Host "WARNING: No keys found in script directory!" -ForegroundColor $script:Colors.Error
                Write-Host ""
                Write-Host "The 'keys' folder was not found at: $keysSourcePath" -ForegroundColor $script:Colors.Warning
                Write-Host ""
                Write-Host "To complete the setup:" -ForegroundColor $script:Colors.Header
                Write-Host "1. Get the 'keys' folder from the teacher computer" -ForegroundColor $script:Colors.Info
                Write-Host "2. Copy it to: $PWD" -ForegroundColor $script:Colors.Info
                Write-Host "3. Re-run this script to import keys automatically" -ForegroundColor $script:Colors.Info
                Write-Host ""
                Write-Host "OR use the Configuration menu to import keys manually" -ForegroundColor $script:Colors.Info
                Write-Host ""
                Write-Log "No keys found in PWD for student import" -Level Warning
            }
        }
        
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host " Veyon $($releaseInfo.Version) installed successfully!" -ForegroundColor $script:Colors.Success
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host ""
        
        # FOR TEACHER MODE: Pin Veyon Master to taskbar
        if ($isTeacher) {
            Write-Host "Configuring Veyon Master..." -ForegroundColor $script:Colors.Info
            Pin-VeyonMasterToTaskbar
            Write-Host ""
        }
        
        # Restart prompt
        $restart = Read-Host "A system restart is recommended. Restart now? (y/N)"
        if ($restart -eq 'y') {
            Write-Log "Initiating system restart"
            Write-Host "Restarting in 5 seconds..." -ForegroundColor $script:Colors.Warning
            Start-Sleep -Seconds 5
            Restart-Computer -Force
        } else {
            Write-Host ""
            Write-Host "IMPORTANT: Please restart the computer later for all changes to take effect." -ForegroundColor $script:Colors.Warning
            Write-Host ""
        }
        
    } catch {
        Write-Log "Installation failed: $_" -Level Error
        Write-Host ""
        Write-Host "Installation failed: $_" -ForegroundColor $script:Colors.Error
        Write-Host ""
    }
    
    Read-Host "Press Enter to continue"
}

function Uninstall-Veyon {
    Show-Header
    Write-Host "VEYON UNINSTALLATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    # Check if Veyon is installed
    if (!(Test-VeyonInstalled)) {
        Write-Host "Veyon is not installed on this system." -ForegroundColor $script:Colors.Warning
        Read-Host "Press Enter to continue"
        return
    }
    
    $currentVersion = try {
        (Get-ItemProperty "C:\Program Files\Veyon\veyon-configurator.exe" -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    } catch {
        "Unknown"
    }
    
    Write-Host "Current Veyon version: $currentVersion" -ForegroundColor $script:Colors.Info
    Write-Host ""
    Write-Host "WARNING: This will completely remove Veyon from this computer!" -ForegroundColor $script:Colors.Warning
    Write-Host ""
    Write-Host "The following will be removed:" -ForegroundColor $script:Colors.Header
    Write-Host "  - Veyon application files" -ForegroundColor $script:Colors.Info
    Write-Host "  - Veyon Service" -ForegroundColor $script:Colors.Info
    Write-Host "  - Configuration files" -ForegroundColor $script:Colors.Info
    Write-Host "  - Authentication keys" -ForegroundColor $script:Colors.Info
    Write-Host "  - Log files" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $confirm = Read-Host "Are you sure you want to uninstall Veyon? (yes/N)"
    if ($confirm -ne 'yes') {
        Write-Host "Uninstallation cancelled." -ForegroundColor $script:Colors.Warning
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host ""
    $clearConfig = Read-Host "Do you want to clear all configuration and data? (Y/n)"
    $shouldClearConfig = ($clearConfig -ne 'n')
    
    try {
        $uninstallerPath = "C:\Program Files\Veyon\uninstall.exe"
        
        if (!(Test-Path $uninstallerPath)) {
            throw "Veyon uninstaller not found at: $uninstallerPath"
        }
        
        Write-Host ""
        Write-Host "Uninstalling Veyon..." -ForegroundColor $script:Colors.Info
        Write-Log "Starting Veyon uninstallation"
        
        # Build uninstall arguments
        $uninstallArgs = "/S"  # Silent mode
        if ($shouldClearConfig) {
            $uninstallArgs += " /ClearConfig"
            Write-Log "Uninstalling with configuration clearing"
        } else {
            Write-Log "Uninstalling without clearing configuration"
        }
        
        Show-Progress -Activity "Uninstalling Veyon" -Status "Stopping Veyon Service..." -PercentComplete 10
        Start-Sleep -Milliseconds 500
        
        # Stop Veyon Service if running
        try {
            $service = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Stop-Service -Name "VeyonService" -Force -ErrorAction SilentlyContinue
                Write-Log "Stopped Veyon Service"
            }
        } catch {
            $errorMsg = $_.Exception.Message
            Write-Log "Could not stop Veyon Service: $errorMsg" -Level Warning
        }
        
        Show-Progress -Activity "Uninstalling Veyon" -Status "Running uninstaller..." -PercentComplete 30
        Write-Log "Executing: $uninstallerPath $uninstallArgs"
        
        # Run uninstaller
        $process = Start-Process -FilePath $uninstallerPath -ArgumentList $uninstallArgs -Wait -PassThru
        
        Show-Progress -Activity "Uninstalling Veyon" -Status "Removing files..." -PercentComplete 60
        Start-Sleep -Milliseconds 500
        
        if ($process.ExitCode -ne 0) {
            throw "Veyon uninstallation failed with exit code: $($process.ExitCode)"
        }
        
        Show-Progress -Activity "Uninstalling Veyon" -Status "Cleaning up..." -PercentComplete 80
        Start-Sleep -Milliseconds 500
        
        # Additional cleanup if requested
        if ($shouldClearConfig) {
            # Remove any remaining data directories
            $dataPaths = @(
                "C:\ProgramData\Veyon",
                "$env:APPDATA\Veyon"
            )
            
            foreach ($path in $dataPaths) {
                if (Test-Path $path) {
                    try {
                        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log "Removed: $path"
                    } catch {
                        $errorMsg = $_.Exception.Message
                        Write-Log "Could not remove $path : $errorMsg" -Level Warning
                    }
                }
            }
        }
        
        Show-Progress -Activity "Uninstalling Veyon" -Status "Complete" -PercentComplete 100
        Start-Sleep -Milliseconds 500
        Write-Progress -Activity "Uninstalling Veyon" -Completed
        
        Write-Log "Veyon uninstalled successfully" -Level Success
        
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host " Veyon uninstalled successfully!" -ForegroundColor $script:Colors.Success
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host ""
        
        if ($shouldClearConfig) {
            Write-Host "All configuration and data has been removed." -ForegroundColor $script:Colors.Info
        } else {
            Write-Host "Configuration and keys were preserved." -ForegroundColor $script:Colors.Info
        }
        
        Write-Host ""
        
        # Restart prompt
        $restart = Read-Host "A system restart is recommended. Restart now? (y/N)"
        if ($restart -eq 'y') {
            Write-Log "Initiating system restart after uninstallation"
            Write-Host "Restarting in 5 seconds..." -ForegroundColor $script:Colors.Warning
            Start-Sleep -Seconds 5
            Restart-Computer -Force
        } else {
            Write-Host ""
            Write-Host "Note: Please restart the computer later to complete the uninstallation." -ForegroundColor $script:Colors.Warning
        }
        
    } catch {
        Write-Log "Uninstallation failed: $_" -Level Error
        Write-Host ""
        Write-Host "Uninstallation failed: $_" -ForegroundColor $script:Colors.Error
        Write-Host ""
    }
    
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Set-VeyonConfiguration {
    Show-Header
    Write-Host "VEYON CONFIGURATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    if (!(Test-VeyonInstalled)) {
        Write-Host "Veyon is not installed. Please install Veyon first." -ForegroundColor $script:Colors.Error
        Read-Host "Press Enter to continue"
        return
    }
    
    $options = @(
        "Generate Authentication Keys",
        "Configure Network Settings",
        "Setup Access Control",
        "Configure LDAP Integration",
        "Export Configuration",
        "Import Configuration"
    )
    
    $choice = Invoke-MenuSelection -Title "Select configuration option:" -Options $options
    
    if ($null -eq $choice) { return }
    
    switch ($choice) {
        0 { New-VeyonAuthenticationKeys }
        1 { Set-VeyonNetworkSettings }
        2 { Set-VeyonAccessControl }
        3 { Set-VeyonLDAPIntegration }
        4 { Export-VeyonConfiguration }
        5 { Import-VeyonConfiguration }
    }
}

function New-VeyonAuthenticationKeys {
    Show-Header
    Write-Host "GENERATE AUTHENTICATION KEYS" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    Write-Host "This will generate a new RSA key pair for authentication." -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $keyName = Read-Host "Enter key name (default: supervisor)"
    if ([string]::IsNullOrWhiteSpace($keyName)) {
        $keyName = "supervisor"
    }
    
    try {
        # Verify Veyon CLI exists
        $veyonCLI = "C:\Program Files\Veyon\veyon-cli.exe"
        
        if (!(Test-Path $veyonCLI)) {
            throw "Veyon CLI not found at: $veyonCLI. Please ensure Veyon is installed correctly."
        }
        
        Show-Progress -Activity "Generating Keys" -Status "Preparing directories..." -PercentComplete 20
        
        Write-Host "Generating authentication keys..." -ForegroundColor $script:Colors.Info
        Write-Log "Generating keys with name: $keyName"
        
        Show-Progress -Activity "Generating Keys" -Status "Creating RSA key pair..." -PercentComplete 50
        
        # Generate keys using Veyon CLI
        $output = & $veyonCLI authkeys create $keyName 2>&1
        $exitCode = $LASTEXITCODE
        
        Write-Log "Veyon CLI output: $output"
        Write-Log "Veyon CLI exit code: $exitCode"
        
        if ($exitCode -ne 0) {
            throw "Key generation failed with exit code $exitCode. Output: $output"
        }
        
        Show-Progress -Activity "Generating Keys" -Status "Verifying key files..." -PercentComplete 70
        Start-Sleep -Milliseconds 500
        
        # Verify keys were created
        $publicKeyPath = Join-Path $script:Config.KeysBasePath "public\$keyName"
        $privateKeyPath = Join-Path $script:Config.KeysBasePath "private\$keyName"
        
        $publicKeyFile = Get-ChildItem -Path $publicKeyPath -Filter "*.pem" -ErrorAction SilentlyContinue | Select-Object -First 1
        $privateKeyFile = Get-ChildItem -Path $privateKeyPath -Filter "*.pem" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if (!$publicKeyFile -or !$privateKeyFile) {
            throw "Key files were not created. Please check Veyon installation."
        }
        
        Show-Progress -Activity "Generating Keys" -Status "Complete" -PercentComplete 100
        Start-Sleep -Milliseconds 500
        Write-Progress -Activity "Generating Keys" -Completed
        
        Write-Log "Authentication keys generated successfully: $keyName" -Level Success
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host " Authentication keys generated!" -ForegroundColor $script:Colors.Success
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host ""
        Write-Host "Key name: $keyName" -ForegroundColor $script:Colors.Info
        Write-Host ""
        Write-Host "Public key location:" -ForegroundColor $script:Colors.Header
        Write-Host "  $($publicKeyFile.FullName)" -ForegroundColor $script:Colors.Info
        Write-Host ""
        Write-Host "Private key location:" -ForegroundColor $script:Colors.Header
        Write-Host "  $($privateKeyFile.FullName)" -ForegroundColor $script:Colors.Info
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor $script:Colors.Header
        Write-Host "  1. The private key stays on THIS computer (teacher/master)" -ForegroundColor $script:Colors.Info
        Write-Host "  2. Copy the PUBLIC key to all student computers" -ForegroundColor $script:Colors.Info
        Write-Host "  3. Use 'Export Configuration' to save the complete setup" -ForegroundColor $script:Colors.Info
        Write-Host ""
        
        # Offer to export keys to PWD
        $exportKeys = Read-Host "Export keys to script directory for distribution? (Y/n)"
        if ($exportKeys -ne 'n') {
            try {
                $keysDestPath = Join-Path $PWD "keys"
                
                if (!(Test-Path $keysDestPath)) {
                    New-Item -ItemType Directory -Path $keysDestPath -Force | Out-Null
                }
                
                # Copy entire keys folder structure
                Copy-Item -Path $script:Config.KeysBasePath\* -Destination $keysDestPath -Recurse -Force
                
                Write-Host ""
                Write-Host "Keys exported to: $keysDestPath" -ForegroundColor $script:Colors.Success
                Write-Host "You can now copy this folder to student computers." -ForegroundColor $script:Colors.Info
                Write-Log "Keys exported to PWD: $keysDestPath" -Level Success
            } catch {
                $errorMsg = $_.Exception.Message
                Write-Host "Failed to export keys: $errorMsg" -ForegroundColor $script:Colors.Warning
                Write-Log "Failed to export keys to PWD: $errorMsg" -Level Warning
            }
        }
        
    } catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Key generation failed: $errorMsg" -Level Error
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Error
        Write-Host " Key generation failed!" -ForegroundColor $script:Colors.Error
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Error
        Write-Host ""
        Write-Host "Error: $errorMsg" -ForegroundColor $script:Colors.Error
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor $script:Colors.Header
        Write-Host "  1. Ensure Veyon is installed correctly" -ForegroundColor $script:Colors.Info
        Write-Host "  2. Check that you have administrator privileges" -ForegroundColor $script:Colors.Info
        Write-Host "  3. Verify Veyon Service is running" -ForegroundColor $script:Colors.Info
        Write-Host ""
    }
    
    Read-Host "Press Enter to continue"
}

function Ensure-TeacherKeys {
    param(
        [string]$KeyName = 'supervisor',
        [string]$ExportPath = $null
    )

    $keysSourcePath = $script:Config.KeysBasePath
    $veyonCLI = "C:\Program Files\Veyon\veyon-cli.exe"

    try {
        # If keys already exist, optionally export them
        if (Test-Path $keysSourcePath) {
            if ($ExportPath) {
                if (!(Test-Path $ExportPath)) { New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null }
                Copy-Item -Path $keysSourcePath -Destination $ExportPath -Recurse -Force
                Write-Log "Supervisor keys copied to: $ExportPath" -Level Success
            }
            return $true
        }

        # Ensure Veyon CLI exists
        if (!(Test-Path $veyonCLI)) {
            Write-Log "Veyon CLI not found at: $veyonCLI. Cannot generate keys." -Level Error
            return $false
        }

        Write-Log "No supervisor keys found, attempting to generate keys using Veyon CLI"
        $output = & $veyonCLI authkeys create $KeyName 2>&1
        $exitCode = $LASTEXITCODE
        Write-Log "Veyon CLI authkeys output: $output"

        if ($exitCode -ne 0) {
            Write-Log "Key generation failed with exit code $exitCode" -Level Error
            return $false
        }

        Start-Sleep -Seconds 1

        if (Test-Path $keysSourcePath) {
            if ($ExportPath) {
                if (!(Test-Path $ExportPath)) { New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null }
                Copy-Item -Path $keysSourcePath -Destination $ExportPath -Recurse -Force
                Write-Log "Generated supervisor keys exported to: $ExportPath" -Level Success
            }
            return $true
        } else {
            Write-Log "Supervisor keys not found after generation attempt" -Level Warning
            return $false
        }

    } catch {
        Write-Log "Ensure-TeacherKeys failed: $_" -Level Error
        return $false
    }
}

function Pin-VeyonMasterToTaskbar {
    try {
        $veyonMasterPath = "C:\Program Files\Veyon\veyon-master.exe"
        
        if (!(Test-Path $veyonMasterPath)) {
            Write-Log "Veyon Master not found at: $veyonMasterPath. Cannot pin to taskbar." -Level Warning
            return $false
        }
        
        # Use Windows Shell object to pin to taskbar
        $shell = New-Object -ComObject "Shell.Application"
        $folder = $shell.Namespace((Split-Path $veyonMasterPath))
        $file = $folder.ParseName((Split-Path $veyonMasterPath -Leaf))
        
        # Pin to taskbar verb ID = "pintohome" for older Windows or "pintotaskbar" 
        $verbs = $file.Verbs()
        foreach ($verb in $verbs) {
            if ($verb.Name -match "Pin to Taskbar|Pin to Start") {
                $verb.DoIt()
                Write-Log "Pinned Veyon Master to taskbar" -Level Success
                Write-Host "Veyon Master has been pinned to the taskbar." -ForegroundColor $script:Colors.Success
                return $true
            }
        }
        
        Write-Log "Pin to Taskbar verb not found in context menu" -Level Warning
        Write-Host "Note: Could not pin Veyon Master to taskbar automatically." -ForegroundColor $script:Colors.Warning
        return $false
        
    } catch {
        Write-Log "Failed to pin Veyon Master to taskbar: $_" -Level Error
        Write-Host "Note: Could not pin Veyon Master to taskbar: $_" -ForegroundColor $script:Colors.Warning
        return $false
    }
}

function Set-VeyonNetworkSettings {
    Show-Header
    Write-Host "NETWORK SETTINGS" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "Network configuration through GUI is recommended." -ForegroundColor $script:Colors.Info
    Write-Host "Opening Veyon Configurator..." -ForegroundColor $script:Colors.Info
    
    try {
        $configurator = "C:\Program Files\Veyon\veyon-configurator.exe"
        if (Test-Path $configurator) {
            Start-Process $configurator
        } else {
            throw "Veyon Configurator not found"
        }
    } catch {
        Write-Host "Failed to open Veyon Configurator: $_" -ForegroundColor $script:Colors.Error
    }
    
    Read-Host "`nPress Enter to continue"
}

function Set-VeyonAccessControl {
    Show-Header
    Write-Host "ACCESS CONTROL SETTINGS" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "Access control configuration through GUI is recommended." -ForegroundColor $script:Colors.Info
    Write-Host "Opening Veyon Configurator..." -ForegroundColor $script:Colors.Info
    
    try {
        $configurator = "C:\Program Files\Veyon\veyon-configurator.exe"
        if (Test-Path $configurator) {
            Start-Process $configurator
        } else {
            throw "Veyon Configurator not found"
        }
    } catch {
        Write-Host "Failed to open Veyon Configurator: $_" -ForegroundColor $script:Colors.Error
    }
    
    Read-Host "`nPress Enter to continue"
}

function Set-VeyonLDAPIntegration {
    Show-Header
    Write-Host "LDAP INTEGRATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "LDAP configuration through GUI is recommended." -ForegroundColor $script:Colors.Info
    Write-Host "Opening Veyon Configurator..." -ForegroundColor $script:Colors.Info
    
    try {
        $configurator = "C:\Program Files\Veyon\veyon-configurator.exe"
        if (Test-Path $configurator) {
            Start-Process $configurator
        } else {
            throw "Veyon Configurator not found"
        }
    } catch {
        Write-Host "Failed to open Veyon Configurator: $_" -ForegroundColor $script:Colors.Error
    }
    
    Read-Host "`nPress Enter to continue"
}

function Export-VeyonConfiguration {
    Show-Header
    Write-Host "EXPORT VEYON CONFIGURATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    try {
        Show-Progress -Activity "Exporting Configuration" -Status "Reading configuration..." -PercentComplete 30
        
        $veyonCLI = "C:\Program Files\Veyon\veyon-cli.exe"
        $exportPath = Join-Path $PWD "veyon-config_$env:COMPUTERNAME.json"
        
        Show-Progress -Activity "Exporting Configuration" -Status "Exporting to file..." -PercentComplete 60
        
        & $veyonCLI config export $exportPath
        
        if ($LASTEXITCODE -ne 0) {
            throw "Configuration export failed"
        }
        
        Show-Progress -Activity "Exporting Configuration" -Status "Complete" -PercentComplete 100
        Start-Sleep -Milliseconds 300
        Write-Progress -Activity "Exporting Configuration" -Completed
        
        Write-Log "Configuration exported to: $exportPath" -Level Success
        Write-Host "Configuration exported successfully!" -ForegroundColor $script:Colors.Success
        Write-Host "File: $exportPath" -ForegroundColor $script:Colors.Info
        
    } catch {
        Write-Log "Configuration export failed: $_" -Level Error
        Write-Host "Configuration export failed: $_" -ForegroundColor $script:Colors.Error
    }
    
    Read-Host "`nPress Enter to continue"
}

function Import-VeyonConfiguration {
    Show-Header
    Write-Host "IMPORT VEYON CONFIGURATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    $configPath = Read-Host "Enter path to configuration file"
    
    if (![string]::IsNullOrWhiteSpace($configPath) -and (Test-Path $configPath)) {
        try {
            Show-Progress -Activity "Importing Configuration" -Status "Reading file..." -PercentComplete 30
            
            $veyonCLI = "C:\Program Files\Veyon\veyon-cli.exe"
            
            Show-Progress -Activity "Importing Configuration" -Status "Importing configuration..." -PercentComplete 60
            
            & $veyonCLI config import $configPath
            
            if ($LASTEXITCODE -ne 0) {
                throw "Configuration import failed"
            }
            
            Show-Progress -Activity "Importing Configuration" -Status "Complete" -PercentComplete 100
            Start-Sleep -Milliseconds 300
            Write-Progress -Activity "Importing Configuration" -Completed
            
            Write-Log "Configuration imported from: $configPath" -Level Success
            Write-Host "Configuration imported successfully!" -ForegroundColor $script:Colors.Success
            
        } catch {
            Write-Log "Configuration import failed: $_" -Level Error
            Write-Host "Configuration import failed: $_" -ForegroundColor $script:Colors.Error
        }
    } else {
        Write-Host "Invalid file path." -ForegroundColor $script:Colors.Error
    }
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region User Restriction Functions

function Set-UserRestrictions {
    Show-Header
    Write-Host "USER RESTRICTION SETTINGS" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    Write-Host "Apply restrictive settings to non-admin users?" -ForegroundColor $script:Colors.Warning
    Write-Host "This will modify Group Policies and Windows Settings." -ForegroundColor $script:Colors.Warning
    Write-Host ""
    
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne 'y') {
        return
    }
    
    Show-Header
    Write-Host "USER RESTRICTION SETTINGS" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "Select restrictions to apply (marked with [X] are enabled by default):" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $restrictions = @(
        @{ Name = "Disable Automatic Updates"; Enabled = $false; Key = "AutoUpdate" },
        @{ Name = "Disable Background Change"; Enabled = $false; Key = "Background" },
        @{ Name = "Disable PC Name Change"; Enabled = $true; Key = "PCName" },
        @{ Name = "Disable Script Execution"; Enabled = $true; Key = "Scripts" },
        @{ Name = "Disable Control Panel Access"; Enabled = $false; Key = "ControlPanel" },
        @{ Name = "Disable Registry Editor"; Enabled = $false; Key = "RegEdit" },
        @{ Name = "Disable Task Manager"; Enabled = $false; Key = "TaskMgr" },
        @{ Name = "Disable Command Prompt"; Enabled = $false; Key = "CMD" },
        @{ Name = "Disable Windows Settings"; Enabled = $false; Key = "Settings" },
        @{ Name = "Hide System Drive in Explorer"; Enabled = $false; Key = "CDrive" }
    )
    
    for ($i = 0; $i -lt $restrictions.Count; $i++) {
        $marker = if ($restrictions[$i].Enabled) { "[X]" } else { "[ ]" }
        Write-Host "  [$($i + 1)] $marker $($restrictions[$i].Name)" -ForegroundColor $script:Colors.Info
    }
    
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor $script:Colors.Header
    Write-Host "  - Enter numbers to toggle (comma-separated, e.g., 1,3,5)" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter 'A' to apply current selection" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter '0' to cancel" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    do {
        $input = Read-Host "Enter command"
        
        if ($input -eq '0') { return }
        if ($input -eq 'A' -or $input -eq 'a') { break }
        
        $selections = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        foreach ($sel in $selections) {
            $index = [int]$sel - 1
            if ($index -ge 0 -and $index -lt $restrictions.Count) {
                $restrictions[$index].Enabled = !$restrictions[$index].Enabled
            }
        }
        
        # Redisplay
        Show-Header
        Write-Host "USER RESTRICTION SETTINGS" -ForegroundColor $script:Colors.Header
        Write-Host ""
        Write-Host "Select restrictions to apply:" -ForegroundColor $script:Colors.Info
        Write-Host ""
        for ($i = 0; $i -lt $restrictions.Count; $i++) {
            $marker = if ($restrictions[$i].Enabled) { "[X]" } else { "[ ]" }
            Write-Host "  [$($i + 1)] $marker $($restrictions[$i].Name)" -ForegroundColor $script:Colors.Info
        }
        Write-Host ""
        Write-Host "Commands: Numbers to toggle | 'A' to apply | '0' to cancel" -ForegroundColor $script:Colors.Prompt
        Write-Host ""
        
    } while ($true)
    
    # Apply restrictions
    $enabledRestrictions = $restrictions | Where-Object { $_.Enabled }
    
    if ($enabledRestrictions.Count -eq 0) {
        Write-Host "No restrictions selected." -ForegroundColor $script:Colors.Warning
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host ""
    Write-Host "Applying $($enabledRestrictions.Count) restriction(s)..." -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $step = 0
    $totalSteps = $enabledRestrictions.Count
    
    try {
        foreach ($restriction in $enabledRestrictions) {
            $step++
            $percent = [int](($step / $totalSteps) * 100)
            Show-Progress -Activity "Applying Restrictions" -Status "[$step/$totalSteps] $($restriction.Name)" -PercentComplete $percent
            Start-Sleep -Milliseconds 300
            
            switch ($restriction.Key) {
                "AutoUpdate" {
                    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -Force
                }
                "Background" {
                    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" -Name "NoChangingWallPaper" -Value 1 -Force
                }
                "PCName" {
                    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "DontDisplayNetworkSelectionUI" -Value 1 -Force
                }
                "Scripts" {
                    Set-ExecutionPolicy -ExecutionPolicy Restricted -Scope CurrentUser -Force -ErrorAction SilentlyContinue
                }
                "ControlPanel" {
                    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoControlPanel" -Value 1 -Force
                }
                "RegEdit" {
                    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableRegistryTools" -Value 1 -Force
                }
                "TaskMgr" {
                    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Value 1 -Force
                }
                "CMD" {
                    New-Item -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\System" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "DisableCMD" -Value 1 -Force
                }
                "Settings" {
                    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "SettingsPageVisibility" -Value "hide:windowsupdate" -Force
                }
                "CDrive" {
                    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDrives" -Value 4 -Force
                }
            }
            
            Write-Log "Applied restriction: $($restriction.Name)" -Level Success
        }
        
        Show-Progress -Activity "Applying Restrictions" -Status "Complete" -PercentComplete 100
        Start-Sleep -Milliseconds 500
        Write-Progress -Activity "Applying Restrictions" -Completed
        
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host " $($enabledRestrictions.Count) restriction(s) applied successfully!" -ForegroundColor $script:Colors.Success
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host ""
        Write-Host "Note: Some restrictions require a logoff/restart to take effect." -ForegroundColor $script:Colors.Warning
        
    } catch {
        Write-Log "Failed to apply restrictions: $_" -Level Error
        Write-Host ""
        Write-Host "Failed to apply restrictions: $_" -ForegroundColor $script:Colors.Error
    }
    
    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

#region Computer Management Functions

function Rename-ComputerMenu {
    Show-Header
    Write-Host "RENAME COMPUTER" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    $currentName = $env:COMPUTERNAME
    Write-Host "Current computer name: $currentName" -ForegroundColor $script:Colors.Info
    Write-Host ""
    Write-Host "Computer name requirements:" -ForegroundColor $script:Colors.Header
    Write-Host "  - 1-15 characters maximum" -ForegroundColor $script:Colors.Info
    Write-Host "  - Letters, numbers, and hyphens only" -ForegroundColor $script:Colors.Info
    Write-Host "  - Cannot start or end with a hyphen" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $newName = Read-Host "Enter new computer name (or press Enter to cancel)"
    
    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Host "Operation cancelled." -ForegroundColor $script:Colors.Warning
        Read-Host "Press Enter to continue"
        return
    }
    
    # Validate computer name
    if ($newName -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,13}[a-zA-Z0-9])?$') {
        Write-Host ""
        Write-Host "Invalid computer name!" -ForegroundColor $script:Colors.Error
        Write-Host "Please follow the naming requirements." -ForegroundColor $script:Colors.Error
        Read-Host "Press Enter to continue"
        return
    }
    
    try {
        Show-Progress -Activity "Renaming Computer" -Status "Applying new name..." -PercentComplete 50
        
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        
        Show-Progress -Activity "Renaming Computer" -Status "Complete" -PercentComplete 100
        Start-Sleep -Milliseconds 300
        Write-Progress -Activity "Renaming Computer" -Completed
        
        Write-Log "Computer renamed from $currentName to $newName" -Level Success
        
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host " Computer renamed successfully!" -ForegroundColor $script:Colors.Success
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host ""
        Write-Host "Old name: $currentName" -ForegroundColor $script:Colors.Info
        Write-Host "New name: $newName" -ForegroundColor $script:Colors.Info
        Write-Host ""
        
        $restart = Read-Host "A restart is required for changes to take effect. Restart now? (y/N)"
        if ($restart -eq 'y') {
            Write-Host ""
            Write-Host "Restarting in 5 seconds..." -ForegroundColor $script:Colors.Warning
            Write-Log "Initiating system restart after computer rename"
            Start-Sleep -Seconds 5
            Restart-Computer -Force
        } else {
            Write-Host ""
            Write-Host "IMPORTANT: Please restart the computer later for changes to take effect." -ForegroundColor $script:Colors.Warning
        }
        
    } catch {
        Write-Log "Failed to rename computer: $_" -Level Error
        Write-Host ""
        Write-Host "Failed to rename computer: $_" -ForegroundColor $script:Colors.Error
    }
    
    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

#region Main Menu Functions

function Show-MainMenu {
    Show-Header
    
    $systemInfo = Get-SystemInfo
    
    Write-Host "SYSTEM STATUS" -ForegroundColor $script:Colors.Header
    Write-Host "  Computer:     $($systemInfo.ComputerName)" -ForegroundColor $script:Colors.Info
    Write-Host "  IP Address:   $($systemInfo.IPAddress)" -ForegroundColor $script:Colors.Info
    Write-Host "  Veyon Status: " -NoNewline -ForegroundColor $script:Colors.Info
    if ($systemInfo.VeyonInstalled) {
        Write-Host "Installed ($($systemInfo.VeyonVersion))" -ForegroundColor $script:Colors.Success
    } else {
        Write-Host "Not Installed" -ForegroundColor $script:Colors.Warning
    }
    Write-Host ""
    
    Write-Host "MAIN MENU" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "  [1] System Information" -ForegroundColor $script:Colors.Info
    Write-Host "  [2] Install Veyon" -ForegroundColor $script:Colors.Info
    Write-Host "  [3] Uninstall Veyon" -ForegroundColor $script:Colors.Info
    Write-Host "  [4] Configure Veyon" -ForegroundColor $script:Colors.Info
    Write-Host "  [5] User Restrictions" -ForegroundColor $script:Colors.Info
    Write-Host "  [6] Rename Computer" -ForegroundColor $script:Colors.Info
    Write-Host "  [7] Documentation & Help" -ForegroundColor $script:Colors.Info
    Write-Host "  [0] Exit" -ForegroundColor $script:Colors.Warning
    Write-Host ""
    
    $choice = Read-Host "Enter your choice"
    
    switch ($choice) {
        '1' { Show-SystemInformation }
        '2' { Install-Veyon }
        '3' { Uninstall-Veyon }
        '4' { Set-VeyonConfiguration }
        '5' { Set-UserRestrictions }
        '6' { Rename-ComputerMenu }
        '7' { Show-Documentation }
        '0' { 
            Write-Host ""
            Write-Host "Thank you for using Veyon Installation Tool!" -ForegroundColor $script:Colors.Info
            Write-Log "Script exited by user"
            Write-Host ""
            exit 0
        }
        default {
            Write-Host "Invalid choice. Please try again." -ForegroundColor $script:Colors.Error
            Start-Sleep -Seconds 2
        }
    }
}

function Show-SystemInformation {
    Show-Header
    Write-Host "SYSTEM INFORMATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    $systemInfo = Get-SystemInfo
    
    Write-Host "Computer Name:   $($systemInfo.ComputerName)" -ForegroundColor $script:Colors.Info
    Write-Host "Domain:          $($systemInfo.Domain)" -ForegroundColor $script:Colors.Info
    Write-Host "OS Version:      $($systemInfo.OSVersion)" -ForegroundColor $script:Colors.Info
    Write-Host "Architecture:    $($systemInfo.OSArchitecture)" -ForegroundColor $script:Colors.Info
    Write-Host "RAM:             $($systemInfo.RAM) GB" -ForegroundColor $script:Colors.Info
    Write-Host "IP Address:      $($systemInfo.IPAddress)" -ForegroundColor $script:Colors.Info
    Write-Host "MAC Address:     $($systemInfo.MACAddress)" -ForegroundColor $script:Colors.Info
    Write-Host "Current User:    $($systemInfo.CurrentUser)" -ForegroundColor $script:Colors.Info
    Write-Host "Veyon Installed: $($systemInfo.VeyonInstalled)" -ForegroundColor $script:Colors.Info
    Write-Host "Veyon Version:   $($systemInfo.VeyonVersion)" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    Write-Host "Export Options:" -ForegroundColor $script:Colors.Header
    Write-Host "  [1] Export to JSON" -ForegroundColor $script:Colors.Info
    Write-Host "  [2] Export to CSV" -ForegroundColor $script:Colors.Info
    Write-Host "  [3] Export to TXT" -ForegroundColor $script:Colors.Info
    Write-Host "  [0] Back to Main Menu" -ForegroundColor $script:Colors.Warning
    Write-Host ""
    
    $exportChoice = Read-Host "Enter your choice"
    
    switch ($exportChoice) {
        '1' { 
            $path = Export-SystemInfo -SystemInfo $systemInfo -Format JSON
            Write-Host ""
            Write-Host "Exported to: $path" -ForegroundColor $script:Colors.Success
        }
        '2' { 
            $path = Export-SystemInfo -SystemInfo $systemInfo -Format CSV
            Write-Host ""
            Write-Host "Exported to: $path" -ForegroundColor $script:Colors.Success
        }
        '3' { 
            $path = Export-SystemInfo -SystemInfo $systemInfo -Format TXT
            Write-Host ""
            Write-Host "Exported to: $path" -ForegroundColor $script:Colors.Success
        }
        '0' { return }
    }
    
    if ($exportChoice -ne '0') {
        Write-Host ""
        Read-Host "Press Enter to continue"
    }
}

function Show-Documentation {
    Show-Header
    Write-Host "DOCUMENTATION & HELP" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    Write-Host "Official Veyon Documentation:" -ForegroundColor $script:Colors.Header
    Write-Host "  Administrator Manual: $($script:Config.ManualUrls.Admin)" -ForegroundColor $script:Colors.Info
    Write-Host "  User Manual:          $($script:Config.ManualUrls.User)" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    Write-Host "Local PDF Manuals:" -ForegroundColor $script:Colors.Header
    $manualPaths = Get-ChildItem -Path $PSScriptRoot -Filter "*.pdf" -ErrorAction SilentlyContinue
    if ($manualPaths) {
        foreach ($manual in $manualPaths) {
            Write-Host "  - $($manual.Name)" -ForegroundColor $script:Colors.Info
            Write-Host "    Path: $($manual.FullName)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  No local PDF manuals found in script directory." -ForegroundColor $script:Colors.Warning
        Write-Host "  Place PDF manuals in: $PSScriptRoot" -ForegroundColor $script:Colors.Info
    }
    
    Write-Host ""
    Write-Host "Quick Help:" -ForegroundColor $script:Colors.Header
    Write-Host "  1. Install Veyon on all computers (teacher and student)" -ForegroundColor $script:Colors.Info
    Write-Host "  2. Generate authentication keys on the teacher computer" -ForegroundColor $script:Colors.Info
    Write-Host "  3. Distribute public keys to all student computers" -ForegroundColor $script:Colors.Info
    Write-Host "  4. Configure network object directory (rooms and computers)" -ForegroundColor $script:Colors.Info
    Write-Host "  5. Test connection from Veyon Master" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    Write-Host "Options:" -ForegroundColor $script:Colors.Header
    Write-Host "  [1] Open Administrator Manual in browser" -ForegroundColor $script:Colors.Info
    Write-Host "  [2] Open User Manual in browser" -ForegroundColor $script:Colors.Info
    Write-Host "  [3] Open local PDF manual" -ForegroundColor $script:Colors.Info
    Write-Host "  [0] Back to Main Menu" -ForegroundColor $script:Colors.Warning
    Write-Host ""
    
    $choice = Read-Host "Enter your choice"
    
    switch ($choice) {
        '1' {
            Write-Host "Opening administrator manual in browser..." -ForegroundColor $script:Colors.Info
            Start-Process $script:Config.ManualUrls.Admin
        }
        '2' {
            Write-Host "Opening user manual in browser..." -ForegroundColor $script:Colors.Info
            Start-Process $script:Config.ManualUrls.User
        }
        '3' {
            if ($manualPaths -and $manualPaths.Count -gt 0) {
                Write-Host "Opening $($manualPaths[0].Name)..." -ForegroundColor $script:Colors.Info
                Start-Process $manualPaths[0].FullName
            } else {
                Write-Host "No local PDF manuals found." -ForegroundColor $script:Colors.Warning
            }
        }
        '0' { return }
    }
    
    if ($choice -ne '0') {
        Write-Host ""
        Read-Host "Press Enter to continue"
    }
}

#endregion

#region Main Script Entry Point

function Main {
    param(
        [Parameter(Position=0)]
        [string]$Command,
        
        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$Arguments
    )
    
    # Initialize log directory
    $logDir = Split-Path $script:Config.LogPath
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Write-Log "=== Veyon Setup Script Started ==="
    Write-Log "Script version: 2.0"
    Write-Log "User: $env:USERNAME"
    Write-Log "Computer: $env:COMPUTERNAME"
    
    # Check for CLI mode
    if ($Command) {
        switch ($Command.ToLower()) {
            'install' { 
                Write-Log "CLI mode: install"
                # Check for mode argument
                $mode = if ($Arguments[0]) { $Arguments[0].ToLower() } else { $null }
                
                if ($mode -eq 'teacher' -or $mode -eq 'student') {
                    Write-Host "Installing Veyon in $mode mode..." -ForegroundColor $script:Colors.Info
                    # We need to modify Install-Veyon to accept parameters for CLI mode
                    # For now, call interactive
                    Install-Veyon
                } else {
                    Write-Host "Usage: .\VeyonSetup.ps1 install [teacher|student]" -ForegroundColor $script:Colors.Warning
                    Write-Host "Running in interactive mode..." -ForegroundColor $script:Colors.Info
                    Install-Veyon
                }
            }
            'uninstall' {
                Write-Log "CLI mode: uninstall"
                Uninstall-Veyon
            }
            'info' { 
                Write-Log "CLI mode: info"
                $info = Get-SystemInfo
                $info.GetEnumerator() | Sort-Object Name | Format-Table -AutoSize
            }
            'export' {
                Write-Log "CLI mode: export"
                $format = if ($Arguments[0]) { $Arguments[0].ToUpper() } else { 'JSON' }
                if ($format -notin @('JSON', 'CSV', 'TXT')) {
                    Write-Host "Invalid format. Use: JSON, CSV, or TXT" -ForegroundColor $script:Colors.Error
                    exit 1
                }
                $info = Get-SystemInfo
                $path = Export-SystemInfo -SystemInfo $info -Format $format
                Write-Host "Exported to: $path" -ForegroundColor $script:Colors.Success
            }
            'rename' {
                Write-Log "CLI mode: rename"
                if ($Arguments[0]) {
                    $newName = $Arguments[0]
                    if ($newName -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,13}[a-zA-Z0-9])?$') {
                        Rename-Computer -NewName $newName -Force
                        Write-Host "Computer will be renamed to '$newName' after restart." -ForegroundColor $script:Colors.Success
                        $restart = if ($Arguments[1] -eq '-restart') { $true } else { $false }
                        if ($restart) {
                            Restart-Computer -Force
                        }
                    } else {
                        Write-Host "Invalid computer name format." -ForegroundColor $script:Colors.Error
                        exit 1
                    }
                } else {
                    Write-Host "Usage: script.ps1 rename <newname> [-restart]" -ForegroundColor $script:Colors.Error
                    exit 1
                }
            }
            'version' {
                Write-Log "CLI mode: version"
                $release = Get-LatestVeyonRelease
                Write-Host "Latest Veyon version: $($release.Version)" -ForegroundColor $script:Colors.Info
                Write-Host "Published: $($release.PublishedDate)" -ForegroundColor $script:Colors.Info
                Write-Host "Download URL: $($release.DownloadUrl)" -ForegroundColor $script:Colors.Info
            }
            'help' {
                                Write-Host @"

Veyon Installation & Configuration Tool v2.0 - CLI Help
$script:Line80

Usage: .\VeyonSetup.ps1 [command] [arguments]

Commands:
    install [mode]       Install Veyon (mode: teacher or student)
                       - teacher: Installs Master + Service (with key export)
                       - student: Installs Service only (NO Master)
  uninstall            Uninstall Veyon completely
  info                 Display system information
  export [format]      Export system info (JSON, CSV, TXT)
  rename <name>        Rename computer (add -restart to restart automatically)
  version              Show latest available Veyon version
  help                 Show this help message

Examples:
  .\VeyonSetup.ps1 install teacher
  .\VeyonSetup.ps1 install student
  .\VeyonSetup.ps1 uninstall
  .\VeyonSetup.ps1 info
  .\VeyonSetup.ps1 export JSON
  .\VeyonSetup.ps1 rename LAB-PC-01
  .\VeyonSetup.ps1 rename LAB-PC-01 -restart
  .\VeyonSetup.ps1 version

Interactive Mode:
  Run without arguments to enter interactive menu mode.

For detailed documentation, visit:
  Administrator Manual: $($script:Config.ManualUrls.Admin)
  User Manual:          $($script:Config.ManualUrls.User)

"@ -ForegroundColor $script:Colors.Info
            }
            default {
                Write-Host "Unknown command: $Command" -ForegroundColor $script:Colors.Error
                Write-Host "Run with 'help' for usage information." -ForegroundColor $script:Colors.Info
                Write-Log "CLI mode: unknown command '$Command'"
                exit 1
            }
        }
        
        Write-Log "CLI mode completed successfully"
        return
    }
    
    # Interactive mode
    Write-Log "Starting interactive mode"
    while ($true) {
        Show-MainMenu
    }
}

# Script execution
try {
    Main @args
} catch {
    Write-Log "Fatal error: $_" -Level Error
    Write-Host ""
    Write-Host "A fatal error occurred: $_" -ForegroundColor $script:Colors.Error
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

#endregion