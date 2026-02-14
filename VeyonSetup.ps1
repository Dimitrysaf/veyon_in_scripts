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

# Verbose logging preference
$script:Config.LogVerbose = $true


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

function Rotate-Logs {
    param(
        [int]$MaxFiles = 5,
        [int]$MaxSizeMB = 5
    )

    try {
        $logPath = $script:Config.LogPath
        $logDir = Split-Path $logPath
        if (!(Test-Path $logDir)) { return }

        if (Test-Path $logPath) {
            $fi = Get-Item $logPath
            if ($fi.Length -gt ($MaxSizeMB * 1MB)) {
                $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
                $rotated = Join-Path $logDir ("setup_$ts.log")
                Move-Item -Path $logPath -Destination $rotated -Force
            }
        }

        # Clean old rotated logs
        $rotatedLogs = Get-ChildItem -Path $logDir -Filter 'setup_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($rotatedLogs.Count -gt $MaxFiles) {
            $rotatedLogs | Select-Object -Skip $MaxFiles | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Log "Rotate-Logs failed: $_" -Level Warning
    }
}

function Preflight-Checks {
    param(
        [int]$MinFreeMB = 500,
        [switch]$RequireNonAdmin
    )

    try {
        $ok = $true

        # OS Version check
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $caption = $os.Caption
        if ($caption -notmatch 'Windows 10|Windows 11') {
            Write-Host "Warning: OS detected: $caption" -ForegroundColor $script:Colors.Warning
            Write-Log "Preflight: Non-standard OS detected: $caption" -Level Warning
            $resp = Read-Host "Proceed anyway? (y/N)"
            if ($resp -ne 'y') { $ok = $false }
        }

        # Disk space check (system drive)
        $sysDrive = (Get-PSDrive -Name (Split-Path $env:SystemDrive -Qualifier)).Name
        $freeMB = [math]::Round((Get-PSDrive -Name $env:SystemDrive.TrimEnd('\'))[0].Free / 1MB, 0)
        if ($freeMB -lt $MinFreeMB) {
            Write-Host "Warning: Low disk space on system drive: $freeMB MB free" -ForegroundColor $script:Colors.Warning
            Write-Log "Preflight: Low disk space ($freeMB MB)" -Level Warning
            $resp = Read-Host "Continue with low disk space? (y/N)"
            if ($resp -ne 'y') { $ok = $false }
        }

        if ($RequireNonAdmin) {
            $nonAdmins = Get-NonAdminUserProfiles
            if ($nonAdmins.Count -eq 0) {
                Write-Host "Error: No non-admin user profiles detected. Aborting." -ForegroundColor $script:Colors.Error
                Write-Log "Preflight failed: no non-admin users found" -Level Error
                $ok = $false
            }
        }

        return $ok
    } catch {
        Write-Log "Preflight-Checks failed: $_" -Level Warning
        return $false
    }
}

function Add-SummaryEntry {
    param(
        [string]$Key,
        [string]$Value
    )
    if (-not $script:SessionSummary) { $script:SessionSummary = @{} }
    $script:SessionSummary[$Key] = $Value
}

function Show-FinalStatus {
    try {
        Write-Host ""; Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
        Write-Host "FINAL STATUS SUMMARY" -ForegroundColor $script:Colors.Header
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
        if ($script:SessionSummary) {
            foreach ($k in $script:SessionSummary.Keys) {
                Write-Host "  $k : $($script:SessionSummary[$k])" -ForegroundColor $script:Colors.Info
            }
        } else {
            Write-Host "  No session summary available." -ForegroundColor $script:Colors.Warning
        }
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
    } catch {
        Write-Log "Show-FinalStatus failed: $_" -Level Warning
    }
}

function Backup-VeyonConfiguration {
    param(
        [string]$DestinationRoot = "$env:TEMP\VeyonBackups"
    )
    try {
        $src = "C:\ProgramData\Veyon"
        if (!(Test-Path $src)) { Write-Log "No Veyon data to backup" -Level Info; return $false }
        if (!(Test-Path $DestinationRoot)) { New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null }
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dest = Join-Path $DestinationRoot "VeyonBackup_$ts.zip"
        Compress-Archive -Path $src\* -DestinationPath $dest -Force -ErrorAction Stop
        Write-Log "Backup created: $dest" -Level Success
        Add-SummaryEntry -Key "Backup" -Value $dest
        return $true
    } catch {
        Write-Log "Backup failed: $_" -Level Warning
        return $false
    }
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

function Invoke-ReturnToMenu {
    <#
    .SYNOPSIS
        Prompts user to return to main menu
    .DESCRIPTION
        Displays a message asking user to press 0 to return to main menu.
        Loops until 0 is pressed, then returns control to main menu.
    #>
    Write-Host ""
    do {
        $input = Read-Host "Press 0 to return to Main Menu"
        if ($input -eq '0') {
            break
        } else {
            Write-Host "Invalid input. Press 0 to return to Main Menu." -ForegroundColor $script:Colors.Warning
        }
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

function Add-VeyonFirewallRules {
    try {
        Write-Log "Configuring Windows Firewall for Veyon..."
        
        # Veyon standard ports
        $ports = @(
            @{ Port = 5900; Name = "Veyon VNC" },
            @{ Port = 5901; Name = "Veyon VNC Alt" },
            @{ Port = 11400; Name = "Veyon Service" }
        )
        
        $rulesAdded = 0
        
        foreach ($portInfo in $ports) {
            $ruleName = "Veyon - $($portInfo.Name) (Port $($portInfo.Port))"
            
            # Check if rule already exists
            $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            
            if ($existingRule) {
                Write-Log "Firewall rule already exists: $ruleName"
            } else {
                try {
                    New-NetFirewallRule -DisplayName $ruleName `
                        -Direction Inbound `
                        -Action Allow `
                        -Protocol TCP `
                        -LocalPort $portInfo.Port `
                        -ErrorAction Stop | Out-Null
                    
                    Write-Log "Added firewall rule: $ruleName"
                    $rulesAdded++
                } catch {
                    Write-Log "Failed to add firewall rule for port $($portInfo.Port): $_" -Level Warning
                }
            }
        }
        
        if ($rulesAdded -gt 0) {
            Write-Host "Firewall rules configured ($rulesAdded new rules added)." -ForegroundColor $script:Colors.Success
        } else {
            Write-Host "Firewall rules already configured or no changes needed." -ForegroundColor $script:Colors.Info
        }
        
        return $true
        
    } catch {
        Write-Log "Failed to configure firewall rules: $_" -Level Warning
        Write-Host "Warning: Could not configure firewall rules. Veyon may not be accessible over network." -ForegroundColor $script:Colors.Warning
        return $false
    }
}

function Check-VeyonService {
    try {
        Write-Log "Checking Veyon Service health..."
        
        $service = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue
        
        if ($null -eq $service) {
            Write-Log "Veyon Service not found on system" -Level Warning
            Write-Host "Warning: Veyon Service not found." -ForegroundColor $script:Colors.Warning
            return $false
        }
        
        if ($service.Status -eq 'Running') {
            Write-Log "Veyon Service is running"
            Write-Host "Veyon Service is running." -ForegroundColor $script:Colors.Success
            return $true
        } else {
            Write-Log "Veyon Service is not running. Attempting to start..."
            Write-Host "Starting Veyon Service..." -ForegroundColor $script:Colors.Info
            
            try {
                Start-Service -Name "VeyonService" -ErrorAction Stop
                Start-Sleep -Seconds 2
                
                $service = Get-Service -Name "VeyonService"
                if ($service.Status -eq 'Running') {
                    Write-Log "Veyon Service started successfully" -Level Success
                    Write-Host "Veyon Service started successfully." -ForegroundColor $script:Colors.Success
                    return $true
                } else {
                    Write-Log "Failed: Veyon Service did not start" -Level Error
                    Write-Host "Failed: Veyon Service did not start." -ForegroundColor $script:Colors.Error
                    return $false
                }
            } catch {
                Write-Log "Failed to start Veyon Service: $_" -Level Error
                Write-Host "Error: Could not start Veyon Service: $_" -ForegroundColor $script:Colors.Error
                return $false
            }
        }
    } catch {
        Write-Log "Error checking Veyon Service: $_" -Level Error
        return $false
    }
}

function Export-ComputerToRegistry {
    param(
        [string]$OutputPath = $PWD
    )
    
    try {
        $registryFile = Join-Path $OutputPath "computer_registry.json"
        
        # Reuse Get-SystemInfo to gather system information (DRY principle)
        $systemInfo = Get-SystemInfo
        
        # Enhance with installation status
        $computerInfo = $systemInfo.Clone()
        $computerInfo.InstallationStatus = if ($systemInfo.VeyonInstalled) { "Success" } else { "Failed" }
        
        # Read existing registry if it exists
        $registry = @()
        if (Test-Path $registryFile) {
            try {
                $registry = Get-Content $registryFile -Raw | ConvertFrom-Json
                if ($registry -isnot [System.Collections.Generic.List[object]]) {
                    $registry = @($registry)
                }
            } catch {
                Write-Log "Could not read existing registry, starting fresh" -Level Warning
                $registry = @()
            }
        }
        
        # Add new computer entry (or update if same computer name exists)
        $existingIndex = $registry.FindIndex({ param($item) $item.ComputerName -eq $computerInfo.ComputerName })
        
        if ($existingIndex -ge 0) {
            $registry[$existingIndex] = $computerInfo
            Write-Log "Updated existing computer entry: $($computerInfo.ComputerName)"
        } else {
            $registry += $computerInfo
            Write-Log "Added new computer entry: $($computerInfo.ComputerName)"
        }
        
        # Write registry back to file
        $registry | ConvertTo-Json -Depth 10 | Out-File $registryFile -Encoding UTF8 -Force
        
        Write-Host "Computer information saved to: $registryFile" -ForegroundColor $script:Colors.Success
        Write-Log "Computer registry updated: $registryFile" -Level Success
        
        return $true
        
    } catch {
        Write-Log "Failed to export computer info to registry: $_" -Level Error
        Write-Host "Warning: Could not save computer information: $_" -ForegroundColor $script:Colors.Warning
        return $false
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
        # Run preflight checks (require at least one non-admin user for installs)
        $preflightOk = Preflight-Checks -MinFreeMB 500 -RequireNonAdmin
        if (-not $preflightOk) {
            Write-Host "Preflight checks failed or cancelled. Aborting installation." -ForegroundColor $script:Colors.Error
            Write-Log "Installation aborted due to failed preflight checks" -Level Error
            Invoke-ReturnToMenu
            return
        }

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
            Invoke-ReturnToMenu
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
        
        # Configure Windows Firewall for Veyon
        Write-Host ""
        Write-Host "Configuring firewall rules..." -ForegroundColor $script:Colors.Info
        Add-VeyonFirewallRules
        Write-Host ""
        
        # Check Veyon Service health
        Write-Host "Verifying Veyon Service..." -ForegroundColor $script:Colors.Info
        Check-VeyonService
        Write-Host ""
        
        # Export computer information to registry
        Write-Host "Recording computer information..." -ForegroundColor $script:Colors.Info
        Export-ComputerToRegistry -OutputPath $PWD
        Write-Host ""
        
        # FOR STUDENT MODE: Apply restrictions from restrictions.ini if it exists
        if (-not $isTeacher) {
            $iniPath = Join-Path $PWD "restrictions.ini"
            if (Test-Path $iniPath) {
                Write-Host ""
                Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
                Write-Host " STUDENT MODE: Applying Restrictions" -ForegroundColor $script:Colors.Header
                Write-Host $script:Line80 -ForegroundColor $script:Colors.Header
                Write-Host ""
                
                $restrictions = Load-RestrictionsFromINI -InputPath $PWD
                if ($restrictions) {
                    $enabledRestrictions = $restrictions | Where-Object { $_.Enabled }
                    
                    if ($enabledRestrictions.Count -gt 0) {
                        Write-Host "Applying $($enabledRestrictions.Count) restriction(s) from restrictions.ini..." -ForegroundColor $script:Colors.Info
                        
                        $step = 0
                        $totalSteps = $enabledRestrictions.Count
                        
                        try {
                            foreach ($restriction in $enabledRestrictions) {
                                $step++
                                $percent = [int](($step / $totalSteps) * 100)
                                Show-Progress -Activity "Applying Restrictions" -Status "[$step/$totalSteps] $($restriction.Name)" -PercentComplete $percent
                                Start-Sleep -Milliseconds 200
                                
                                switch ($restriction.Key) {
                                    "AutoUpdate" {
                                        New-Item -Path $restriction.RegPath -Force -ErrorAction SilentlyContinue | Out-Null
                                        Set-ItemProperty -Path $restriction.RegPath -Name $restriction.RegName -Value $restriction.RegValue -Force
                                    }
                                    "Background" {
                                        New-Item -Path $restriction.RegPath -Force -ErrorAction SilentlyContinue | Out-Null
                                        Set-ItemProperty -Path $restriction.RegPath -Name $restriction.RegName -Value $restriction.RegValue -Force
                                    }
                                    "PCName" {
                                        New-Item -Path $restriction.RegPath -Force -ErrorAction SilentlyContinue | Out-Null
                                        Set-ItemProperty -Path $restriction.RegPath -Name $restriction.RegName -Value $restriction.RegValue -Force
                                    }
                                    "Scripts" {
                                        Set-ExecutionPolicy -ExecutionPolicy Restricted -Scope CurrentUser -Force -ErrorAction SilentlyContinue
                                    }
                                    default {
                                        if ($restriction.RegPath) {
                                            New-Item -Path $restriction.RegPath -Force -ErrorAction SilentlyContinue | Out-Null
                                            Set-ItemProperty -Path $restriction.RegPath -Name $restriction.RegName -Value $restriction.RegValue -Force
                                        }
                                    }
                                }
                                
                                Write-Log "Applied restriction: $($restriction.Name)" -Level Success
                            }
                            
                            Show-Progress -Activity "Applying Restrictions" -Status "Complete" -PercentComplete 100
                            Start-Sleep -Milliseconds 300
                            Write-Progress -Activity "Applying Restrictions" -Completed
                            
                            Write-Host ""
                            Write-Host "Restrictions applied successfully!" -ForegroundColor $script:Colors.Success
                            Write-Log "Applied $($enabledRestrictions.Count) restriction(s) during installation" -Level Success
                        } catch {
                            Write-Log "Failed to apply restrictions during installation: $_" -Level Error
                            Write-Host "Warning: Some restrictions could not be applied: $_" -ForegroundColor $script:Colors.Warning
                        }
                    }
                }
                Write-Host ""
            }
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
    
    Invoke-ReturnToMenu
}

function Uninstall-Veyon {
    Show-Header
    Write-Host "VEYON UNINSTALLATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    # Check if Veyon is installed
    if (!(Test-VeyonInstalled)) {
        Write-Host "Veyon is not installed on this system." -ForegroundColor $script:Colors.Warning
        Invoke-ReturnToMenu
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
        Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
}

function Set-VeyonConfiguration {
    Show-Header
    Write-Host "VEYON CONFIGURATION" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    if (!(Test-VeyonInstalled)) {
        Write-Host "Veyon is not installed. Please install Veyon first." -ForegroundColor $script:Colors.Error
        Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
}

#endregion

#region User Restriction Functions

function Get-RestrictionDefinitions {
    return @(
        @{ Name = "Disable Automatic Updates"; Enabled = $false; Key = "AutoUpdate"; RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; RegName = "NoAutoUpdate"; RegValue = 1 },
        @{ Name = "Disable Background Change"; Enabled = $false; Key = "Background"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"; RegName = "NoChangingWallPaper"; RegValue = 1 },
        @{ Name = "Disable PC Name Change"; Enabled = $false; Key = "PCName"; RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; RegName = "DontDisplayNetworkSelectionUI"; RegValue = 1 },
        @{ Name = "Disable Script Execution"; Enabled = $false; Key = "Scripts"; RegPath = $null; RegName = $null; RegValue = $null },
        @{ Name = "Disable Control Panel Access"; Enabled = $false; Key = "ControlPanel"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; RegName = "NoControlPanel"; RegValue = 1 },
        @{ Name = "Disable Registry Editor"; Enabled = $false; Key = "RegEdit"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; RegName = "DisableRegistryTools"; RegValue = 1 },
        @{ Name = "Disable Task Manager"; Enabled = $false; Key = "TaskMgr"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; RegName = "DisableTaskMgr"; RegValue = 1 },
        @{ Name = "Disable Command Prompt"; Enabled = $false; Key = "CMD"; RegPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\System"; RegName = "DisableCMD"; RegValue = 1 },
        @{ Name = "Disable Windows Settings"; Enabled = $false; Key = "Settings"; RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; RegName = "SettingsPageVisibility"; RegValue = "hide:windowsupdate" },
        @{ Name = "Hide System Drive in Explorer"; Enabled = $false; Key = "CDrive"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; RegName = "NoDrives"; RegValue = 4 },
        @{ Name = "Disable USB Removable Media"; Enabled = $false; Key = "USB"; RegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR"; RegName = "Start"; RegValue = 4 },
        @{ Name = "Disable Password Change (User)"; Enabled = $false; Key = "PassChange"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; RegName = "DisableChangePassword"; RegValue = 1 },
        @{ Name = "Disable Printer Installation"; Enabled = $false; Key = "Printers"; RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers"; RegName = "DisablePrinterRedirection"; RegValue = 1 },
        @{ Name = "Disable File Sharing"; Enabled = $false; Key = "FileShare"; RegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"; RegName = "AutoShareWk"; RegValue = 0 },
        @{ Name = "Disable Run from Start Menu"; Enabled = $false; Key = "RunMenu"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; RegName = "NoRun"; RegValue = 1 },
        @{ Name = "Hide Administrative Tools"; Enabled = $false; Key = "AdminTools"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; RegName = "NoAdminToolsMenu"; RegValue = 1 }
    )
}

function Save-RestrictionsToINI {
    param(
        [array]$Restrictions,
        [string]$OutputPath = $PWD
    )
    
    try {
        $iniFile = Join-Path $OutputPath "restrictions.ini"
        $content = @(
            "[Restrictions]",
            "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "# These settings will be applied on installation in Student mode",
            "# Change values to true to enable, false to disable",
            ""
        )
        
        foreach ($restriction in $Restrictions) {
            $enabled = if ($restriction.Enabled) { "true" } else { "false" }
            $content += "$($restriction.Key)=$enabled"
        }
        
        $content | Out-File $iniFile -Encoding UTF8 -Force
        Write-Log "Restrictions saved to: $iniFile" -Level Success
        Write-Host "Restrictions configuration saved to: $iniFile" -ForegroundColor $script:Colors.Success
        return $true
    } catch {
        Write-Log "Failed to save restrictions to INI: $_" -Level Error
        Write-Host "Warning: Could not save restrictions configuration: $_" -ForegroundColor $script:Colors.Warning
        return $false
    }
}

function Load-RestrictionsFromINI {
    param(
        [string]$InputPath = $PWD
    )
    
    try {
        $iniFile = Join-Path $InputPath "restrictions.ini"
        
        if (!(Test-Path $iniFile)) {
            Write-Log "No restrictions.ini file found at: $iniFile"
            return $null
        }
        
        $restrictions = Get-RestrictionDefinitions
        $iniContent = Get-Content $iniFile | Where-Object { $_ -and !$_.StartsWith("#") -and $_.Contains("=") }
        
        foreach ($line in $iniContent) {
            $parts = $line -split "="
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $value = $parts[1].Trim().ToLower()
                $restriction = $restrictions | Where-Object { $_.Key -eq $key }
                if ($restriction) {
                    $restriction.Enabled = ($value -eq "true")
                }
            }
        }
        
        Write-Log "Restrictions loaded from: $iniFile" -Level Success
        return $restrictions
    } catch {
        Write-Log "Failed to load restrictions from INI: $_" -Level Error
        return $null
    }
}

function Detect-ActiveRestrictions {
    try {
        $restrictions = Get-RestrictionDefinitions
        $activeCount = 0
        
        foreach ($restriction in $restrictions) {
            if ($restriction.RegPath -and (Test-Path $restriction.RegPath)) {
                try {
                    $value = Get-ItemProperty -Path $restriction.RegPath -Name $restriction.RegName -ErrorAction SilentlyContinue
                    if ($value) {
                        $restriction.Enabled = $true
                        $activeCount++
                    }
                } catch {
                    # Restriction not applied
                }
            }
        }
        
        Write-Log "Detected $activeCount active restrictions"
        return $restrictions
    } catch {
        Write-Log "Failed to detect active restrictions: $_" -Level Error
        return Get-RestrictionDefinitions
    }
}

function Apply-RestrictionWithFallback {
    param(
        [hashtable]$Restriction
    )
    
    $registrySuccess = $false
    $fallbackSuccess = $false
    
    # Attempt 1: Direct Registry Modification (Primary method)
    try {
        if ($Restriction.RegPath -and $Restriction.RegName) {
            # Create registry path if it doesn't exist
            if (!(Test-Path $Restriction.RegPath)) {
                New-Item -Path $Restriction.RegPath -Force -ErrorAction Stop | Out-Null
            }
            
            # Set the registry value
            Set-ItemProperty -Path $Restriction.RegPath -Name $Restriction.RegName -Value $Restriction.RegValue -Force -ErrorAction Stop
            $registrySuccess = $true
            Write-Log "Registry method successful for: $($Restriction.Name)" -Level Success
        }
    } catch {
        $registryError = $_.Exception.Message
        Write-Log "Registry method failed for $($Restriction.Name): $registryError" -Level Warning
    }
    
    # Attempt 2: Group Policy Fallback (if registry failed)
    if (!$registrySuccess -and $Restriction.RegPath -and $Restriction.RegName) {
        try {
            # Build LGPO-style policy path from registry path
            $policyPath = $Restriction.RegPath.Replace("HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\", "")
            $policyPath = $Restriction.RegPath.Replace("HKLM:\SOFTWARE\", "")
            
            # Try using secedit to apply the restriction
            Write-Log "Attempting Group Policy fallback for: $($Restriction.Name)" -Level Info
            
            # For Local Group Policy, we'll try to use the registry paths that Group Policy monitors
            # Group Policy reads from: HKLM\SOFTWARE\Policies\... (Policies hive)
            $gpPolicyPath = $Restriction.RegPath.Replace(
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\",
                "HKCU:\SOFTWARE\Policies\"
            ).Replace(
                "HKLM:\SOFTWARE\Microsoft\",
                "HKLM:\SOFTWARE\Policies\Microsoft\"
            ).Replace(
                "HKLM:\SOFTWARE\",
                "HKLM:\SOFTWARE\Policies\"
            )
            
            # If the path has already been converted, use it; otherwise use original
            if ($gpPolicyPath -ne $Restriction.RegPath) {
                if (!(Test-Path $gpPolicyPath)) {
                    New-Item -Path $gpPolicyPath -Force -ErrorAction Stop | Out-Null
                }
                Set-ItemProperty -Path $gpPolicyPath -Name $Restriction.RegName -Value $Restriction.RegValue -Force -ErrorAction Stop
                $fallbackSuccess = $true
                Write-Log "Group Policy method successful for: $($Restriction.Name)" -Level Success
            }
            
            # Attempt to refresh Group Policy to apply changes
            if ($fallbackSuccess) {
                try {
                    & gpupdate /force | Out-Null
                    Write-Log "Invoked gpupdate /force to apply Group Policy changes" -Level Info
                } catch {
                    Write-Log "Could not invoke gpupdate, but Group Policy registry entry was modified" -Level Info
                }
            }
        } catch {
            $gpError = $_.Exception.Message
            Write-Log "Group Policy fallback failed for $($Restriction.Name): $gpError" -Level Warning
        }
    }
    
    return ($registrySuccess -or $fallbackSuccess)
}

function Get-NonAdminUserProfiles {
    <#
    .SYNOPSIS
        Gets all non-admin user profiles on the computer.
    .DESCRIPTION
        Loads user profiles from registry excluding built-in and administrator accounts.
    #>
    
    try {
        $nonAdminUsers = @()
        
        # Get all user profile paths from registry
        $profilePath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
        $profiles = Get-ChildItem -Path $profilePath -ErrorAction SilentlyContinue
        
        foreach ($profile in $profiles) {
            $sid = $profile.PSChildName
            
            # Skip non-user SIDs (system, local service, network service, etc.)
            if ($sid -notmatch '^S-1-5-21-') {
                continue
            }
            
            try {
                # Try to get the username from the SID
                $objSID = New-Object System.Security.Principal.SecurityIdentifier($sid)
                $objUser = $objSID.Translate([System.Security.Principal.NTAccount])
                $username = $objUser.Value -replace '^.*\\'  # Get just the username part
                
                # Get the user object to check if admin
                $user = [ADSI]"WinNT://./$username,user"
                $groups = $user.Groups() | ForEach-Object { $_.GetType().InvokeMember("Name", 'GetProperty', $null, $_, $null) }
                
                # Check if user is NOT in Administrators group
                if ($groups -notcontains "Administrators") {
                    $nonAdminUsers += @{
                        Username = $username
                        SID = $sid
                        ProfilePath = (Get-ItemProperty -Path $profile.PSPath -Name "ProfilePath" -ErrorAction SilentlyContinue).ProfilePath
                    }
                    Write-Log "Found non-admin user: $username" -Level Info
                }
            } catch {
                # Skip users we can't enumerate
                Write-Log "Could not process user SID $sid : $_" -Level Warning
            }
        }
        
        return $nonAdminUsers
    } catch {
        Write-Log "Failed to enumerate user profiles: $_" -Level Error
        return @()
    }
}

function Apply-RestrictionToUserProfile {
    <#
    .SYNOPSIS
        Applies a restriction to a specific user profile's registry hive.
    .DESCRIPTION
        Loads and modifies a user's NTUSER.DAT hive to apply restrictions.
    #>
    
    param(
        [string]$UserSID,
        [string]$ProfilePath,
        [hashtable]$Restriction
    )
    
    try {
        # Only handle HKCU restrictions (user-specific ones)
        if (!$Restriction.RegPath -or $Restriction.RegPath -notmatch '^HKCU:') {
            return $false
        }
        
        # Load user hive if not already loaded
        $hivePath = Join-Path $ProfilePath "NTUSER.DAT"
        
        if (!(Test-Path $hivePath)) {
            Write-Log "User hive not found at $hivePath" -Level Warning
            return $false
        }
        
        # Use the loaded hive or load it temporarily
        $tempHiveName = "TempUserHive_$([System.Guid]::NewGuid().ToString().Substring(0,8))"
        $userName = Split-Path $ProfilePath -Leaf
        
        # Convert HKCU path to HKU path format
        $regPath = $Restriction.RegPath -replace '^HKCU:', ($UserSID)
        
        try {
            # Load the user hive
            & reg load "HKU\$tempHiveName" "$hivePath" 2>&1 | Out-Null
            
            # Convert the registry path to use the loaded hive
            $hivePath = "Registry::HKEY_USERS\$tempHiveName\" + ($regPath -replace "^.*?:\\", "")
            
            # Create the path if it doesn't exist
            if (!(Test-Path $hivePath)) {
                New-Item -Path $hivePath -Force -ErrorAction Stop | Out-Null
            }
            
            # Apply the restriction
            Set-ItemProperty -Path $hivePath -Name $Restriction.RegName -Value $Restriction.RegValue -Force -ErrorAction Stop
            
            Write-Log "Applied restriction to user $userName : $($Restriction.Name)" -Level Success
            return $true
            
        } catch {
            Write-Log "Failed to apply restriction to user hive: $_" -Level Warning
            return $false
        } finally {
            # Unload the hive
            Start-Sleep -Milliseconds 500
            & reg unload "HKU\$tempHiveName" 2>&1 | Out-Null
        }
        
    } catch {
        Write-Log "Failed to process user profile: $_" -Level Error
        return $false
    }
}

function Set-UserRestrictions {
    Show-Header
    Write-Host "USER RESTRICTION SETTINGS" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    # Check if running as admin
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentUser)
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (!$isAdmin) {
        Write-Host "WARNING: This script must be run as Administrator!" -ForegroundColor $script:Colors.Error
        Write-Host "Please run as Administrator to apply restrictions to non-admin users." -ForegroundColor $script:Colors.Error
        Invoke-ReturnToMenu
        return
    }
    
    Write-Host "Apply restrictive settings to non-admin users?" -ForegroundColor $script:Colors.Warning
    Write-Host "This will modify registry and Group Policy settings for non-admin user accounts." -ForegroundColor $script:Colors.Warning
    Write-Host ""
    Write-Host "NOTE: Admin user account will NOT be restricted." -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne 'y') {
        return
    }
    
    # Check if restrictions.ini exists and offer to load it
    $iniPath = Join-Path $PWD "restrictions.ini"
    $restrictions = $null
    
    if (Test-Path $iniPath) {
        Write-Host ""
        Write-Host "Found existing restrictions.ini file!" -ForegroundColor $script:Colors.Success
        $loadConfig = Read-Host "Load restrictions from file? (Y/n)"
        if ($loadConfig -ne 'n') {
            $restrictions = Load-RestrictionsFromINI -InputPath $PWD
        }
    }
    
    # If not loaded from file, detect current or show defaults
    if (!$restrictions) {
        Write-Host ""
        Write-Host "Detecting currently active restrictions..." -ForegroundColor $script:Colors.Info
        $restrictions = Detect-ActiveRestrictions
    }
    
    Show-Header
    Write-Host "USER RESTRICTION SETTINGS" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "Select restrictions to apply (marked with [X] are enabled):" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    for ($i = 0; $i -lt $restrictions.Count; $i++) {
        $marker = if ($restrictions[$i].Enabled) { "[X]" } else { "[ ]" }
        Write-Host "  [$($i + 1)] $marker $($restrictions[$i].Name)" -ForegroundColor $script:Colors.Info
    }
    
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor $script:Colors.Header
    Write-Host "  - Enter numbers to toggle (comma-separated, e.g., 1,3,5)" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter 'A' to apply current selection" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter 'S' to save configuration to restrictions.ini" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter '0' to cancel" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    do {
        $input = Read-Host "Enter command"
        
        if ($input -eq '0') { return }
        if ($input -eq 'A' -or $input -eq 'a') { break }
        if ($input -eq 'S' -or $input -eq 's') {
            Save-RestrictionsToINI -Restrictions $restrictions -OutputPath $PWD
            Write-Host ""
            continue
        }
        
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
        Write-Host "Commands: Numbers to toggle | 'A' to apply | 'S' to save | '0' to cancel" -ForegroundColor $script:Colors.Prompt
        Write-Host ""
        
    } while ($true)
    
    # Apply restrictions
    $enabledRestrictions = $restrictions | Where-Object { $_.Enabled }
    
    if ($enabledRestrictions.Count -eq 0) {
        Write-Host "No restrictions selected." -ForegroundColor $script:Colors.Warning
        Invoke-ReturnToMenu
        return
    }
    
    Write-Host ""
    Write-Host "Applying $($enabledRestrictions.Count) restriction(s)..." -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $step = 0
    $totalSteps = $enabledRestrictions.Count
    $successCount = 0
    $failureCount = 0
    
    # Get non-admin user profiles for user-specific restrictions
    $nonAdminUsers = @()
    $hkuRestrictions = @($enabledRestrictions | Where-Object { $_.RegPath -match '^HKCU:' })
    
    if ($hkuRestrictions.Count -gt 0) {
        Write-Host ""
        Write-Host "Scanning for non-admin user accounts..." -ForegroundColor $script:Colors.Info
        $nonAdminUsers = Get-NonAdminUserProfiles
        
        if ($nonAdminUsers.Count -eq 0) {
            Write-Host "No non-admin user profiles found on this computer." -ForegroundColor $script:Colors.Warning
            Write-Host ""
        } else {
            Write-Host "Found $($nonAdminUsers.Count) non-admin user profile(s):" -ForegroundColor $script:Colors.Success
            foreach ($user in $nonAdminUsers) {
                Write-Host "  - $($user.Username)" -ForegroundColor $script:Colors.Info
            }
            Write-Host ""
        }
    }
    
    try {
        foreach ($restriction in $enabledRestrictions) {
            $step++
            $percent = [int](($step / $totalSteps) * 100)
            Show-Progress -Activity "Applying Restrictions" -Status "[$step/$totalSteps] $($restriction.Name)" -PercentComplete $percent
            Start-Sleep -Milliseconds 300
            
            # Check if this is a user-specific (HKCU) restriction
            if ($restriction.RegPath -match '^HKCU:') {
                # Apply to each non-admin user profile
                if ($nonAdminUsers.Count -gt 0) {
                    $restrictionAppliedCount = 0
                    foreach ($user in $nonAdminUsers) {
                        $applied = Apply-RestrictionToUserProfile -UserSID $user.SID -ProfilePath $user.ProfilePath -Restriction $restriction
                        if ($applied) {
                            $restrictionAppliedCount++
                        }
                    }
                    
                    if ($restrictionAppliedCount -gt 0) {
                        Write-Log "Applied '$($restriction.Name)' to $restrictionAppliedCount non-admin user(s)" -Level Success
                        $successCount++
                    } else {
                        Write-Log "Failed to apply '$($restriction.Name)' to any user profiles" -Level Warning
                        $failureCount++
                    }
                } else {
                    Write-Log "Skipped user-specific restriction '$($restriction.Name)' - no non-admin users found" -Level Warning
                }
            } else {
                # HKLM restriction - apply system-wide
                if ($restriction.Key -eq "Scripts") {
                    # Special handling for Script Execution
                    try {
                        Set-ExecutionPolicy -ExecutionPolicy Restricted -Scope CurrentUser -Force -ErrorAction Stop
                        Write-Log "Applied restriction: $($restriction.Name) (Execution Policy)" -Level Success
                        $successCount++
                    } catch {
                        Write-Log "Failed to apply Script Execution restriction: $_" -Level Warning
                        $failureCount++
                    }
                } else {
                    # Use standard registry + Group Policy fallback for all other restrictions
                    $applied = Apply-RestrictionWithFallback -Restriction $restriction
                    if ($applied) {
                        Write-Log "Applied system-wide restriction: $($restriction.Name)" -Level Success
                        $successCount++
                    } else {
                        Write-Log "Failed to apply system-wide restriction: $($restriction.Name)" -Level Warning
                        $failureCount++
                    }
                }
            }
        }
        
        Show-Progress -Activity "Applying Restrictions" -Status "Complete" -PercentComplete 100
        Start-Sleep -Milliseconds 500
        Write-Progress -Activity "Applying Restrictions" -Completed
        
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host " Restriction Application Summary" -ForegroundColor $script:Colors.Success
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host ""
        Write-Host "Total restrictions selected: $($enabledRestrictions.Count)" -ForegroundColor $script:Colors.Info
        Write-Host "Successfully applied:       $successCount" -ForegroundColor $script:Colors.Success
        if ($failureCount -gt 0) {
            Write-Host "Failed to apply:            $failureCount" -ForegroundColor $script:Colors.Warning
        }
        Write-Host ""
        
        # Show details about which users were affected
        if ($nonAdminUsers.Count -gt 0) {
            $userRestrictionCount = @($enabledRestrictions | Where-Object { $_.RegPath -match '^HKCU:' }).Count
            if ($userRestrictionCount -gt 0) {
                Write-Host "User-specific restrictions applied to:" -ForegroundColor $script:Colors.Info
                foreach ($user in $nonAdminUsers) {
                    Write-Host "  - $($user.Username)" -ForegroundColor $script:Colors.Info
                }
                Write-Host ""
            }
        }
        
        Write-Host "Application methods used:" -ForegroundColor $script:Colors.Info
        Write-Host "  - Primary: Direct Registry Modification" -ForegroundColor $script:Colors.Info
        Write-Host "  - Fallback: Group Policy (if registry method fails)" -ForegroundColor $script:Colors.Info
        Write-Host ""
        Write-Host "Note: Some restrictions require a logoff/restart to take effect." -ForegroundColor $script:Colors.Warning
        
    } catch {
        Write-Log "Failed to apply restrictions: $_" -Level Error
        Write-Host ""
        Write-Host "Failed to apply restrictions: $_" -ForegroundColor $script:Colors.Error
    }
    
    Invoke-ReturnToMenu
}

#endregion

#region Windows Personalization Functions

function Apply-PerformanceOptimization {
    <#
    .SYNOPSIS
        Optimizes Windows for best performance by disabling visual effects, animations, and shadows.
    .DESCRIPTION
        Applies registry settings equivalent to "Adjust for best performance" in Windows Settings.
    #>
    
    try {
        Write-Log "Applying performance optimizations..." -Level Info
        
        # Registry paths for performance settings
        $paths = @(
            "HKCU:\Control Panel\Desktop",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        )
        
        # Ensure paths exist
        foreach ($path in $paths) {
            if (!(Test-Path $path)) {
                New-Item -Path $path -Force | Out-Null
            }
        }
        
        # Disable animations (User Preference Mask)
        # 90 12 03 80 = Best performance
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "UserPreferencesMask" -Value ([byte[]](0x90, 0x12, 0x03, 0x80)) -Force
        
        # Disable font smoothing
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "FontSmoothing" -Value "0" -Force
        
        # Disable window animations
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Force -ErrorAction SilentlyContinue
        
        # Disable menu animations
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Force
        
        # Disable taskbar animations
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAnimations" -Value "0" -Force
        
        # Remove visual effects from folder options
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "DisallowShaking" -Value "1" -Force
        
        # Disable tooltip animations
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TooltipFadeTime" -Value "0" -Force -ErrorAction SilentlyContinue
        
        Write-Log "Performance optimizations applied successfully" -Level Success
        return $true
        
    } catch {
        Write-Log "Failed to apply performance optimizations: $_" -Level Warning
        return $false
    }
}

function Get-PersonalizationDefinitions {
    return @(
        @{ Name = "Disable Copilot in Windows"; Enabled = $false; Key = "Copilot"; RegPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; RegName = "TurnOffWindowsCopilot"; RegValue = 1 },
        @{ Name = "Disable Ads in Start Menu"; Enabled = $false; Key = "StartMenuAds"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"; RegName = "LevelsToConvert"; RegValue = 0 },
        @{ Name = "Disable Ads in Lock Screen"; Enabled = $false; Key = "LockScreenAds"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; RegName = "RotatingLockScreenEnabled"; RegValue = 0 },
        @{ Name = "Disable Targeted Ads"; Enabled = $false; Key = "TargetedAds"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; RegName = "Enabled"; RegValue = 0 },
        @{ Name = "Disable Game Bar"; Enabled = $false; Key = "GameBar"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"; RegName = "AppCaptureEnabled"; RegValue = 0 },
        @{ Name = "Disable Activity History"; Enabled = $false; Key = "ActivityHistory"; RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; RegName = "PublishUserActivities"; RegValue = 0 },
        @{ Name = "Disable Telemetry/Diagnostic Data"; Enabled = $false; Key = "Telemetry"; RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; RegName = "AllowDiagnosticData"; RegValue = 0 },
        @{ Name = "Disable App Suggestions"; Enabled = $false; Key = "AppSuggestions"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; RegName = "ContentDeliveryEnabled"; RegValue = 0 },
        @{ Name = "Disable Tailored Experiences"; Enabled = $false; Key = "TailoredExp"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; RegName = "FeatureManagementEnabled"; RegValue = 0 },
        @{ Name = "Disable Cortana in Start Menu"; Enabled = $false; Key = "Cortana"; RegPath = "HKCU:\SOFTWARE\Microsoft\Personalization\Settings"; RegName = "AcceptedPrivacyPolicy"; RegValue = 0 },
        @{ Name = "Disable OneDrive Autostart"; Enabled = $false; Key = "OneDrive"; RegPath = "HKCU:\SOFTWARE\Microsoft\OneDrive"; RegName = "DisableAutoStartOnSignIn"; RegValue = 1 },
        @{ Name = "Disable Background App Refresh"; Enabled = $false; Key = "BackgroundApps"; RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"; RegName = "GlobalUserDisabled"; RegValue = 1 },
        @{ Name = "Optimize for Best Performance"; Enabled = $false; Key = "Performance"; RegPath = $null; RegName = $null; RegValue = $null }
    )
}

function Set-WindowsPersonalization {
    Show-Header
    Write-Host "WINDOWS PERSONALIZATION & CLEANUP" -ForegroundColor $script:Colors.Header
    Write-Host ""
    
    Write-Host "Apply Windows personalization settings?" -ForegroundColor $script:Colors.Warning
    Write-Host "This will disable ads, telemetry, and bloatware on this computer." -ForegroundColor $script:Colors.Warning
    Write-Host ""
    
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne 'y') {
        return
    }
    
    # Load personalization settings definitions
    $personalizations = Get-PersonalizationDefinitions
    
    Show-Header
    Write-Host "WINDOWS PERSONALIZATION & CLEANUP" -ForegroundColor $script:Colors.Header
    Write-Host ""
    Write-Host "Select personalization options to apply (marked with [X] are enabled):" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    for ($i = 0; $i -lt $personalizations.Count; $i++) {
        $marker = if ($personalizations[$i].Enabled) { "[X]" } else { "[ ]" }
        Write-Host "  [$($i + 1)] $marker $($personalizations[$i].Name)" -ForegroundColor $script:Colors.Info
    }
    
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor $script:Colors.Header
    Write-Host "  - Enter numbers to toggle (comma-separated, e.g., 1,3,5)" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter 'A' to apply current selection" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter 'ALL' to enable all options" -ForegroundColor $script:Colors.Info
    Write-Host "  - Enter '0' to cancel" -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    do {
        $input = Read-Host "Enter command"
        
        if ($input -eq '0') { return }
        if ($input -eq 'A' -or $input -eq 'a') { break }
        if ($input -eq 'ALL' -or $input -eq 'all') {
            foreach ($personalization in $personalizations) {
                $personalization.Enabled = $true
            }
            break
        }
        
        $selections = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        foreach ($sel in $selections) {
            $index = [int]$sel - 1
            if ($index -ge 0 -and $index -lt $personalizations.Count) {
                $personalizations[$index].Enabled = !$personalizations[$index].Enabled
            }
        }
        
        # Redisplay
        Show-Header
        Write-Host "WINDOWS PERSONALIZATION & CLEANUP" -ForegroundColor $script:Colors.Header
        Write-Host ""
        Write-Host "Select personalization options:" -ForegroundColor $script:Colors.Info
        Write-Host ""
        for ($i = 0; $i -lt $personalizations.Count; $i++) {
            $marker = if ($personalizations[$i].Enabled) { "[X]" } else { "[ ]" }
            Write-Host "  [$($i + 1)] $marker $($personalizations[$i].Name)" -ForegroundColor $script:Colors.Info
        }
        Write-Host ""
        Write-Host "Commands: Numbers to toggle | 'A' to apply | 'ALL' to enable all | '0' to cancel" -ForegroundColor $script:Colors.Prompt
        Write-Host ""
        
    } while ($true)
    
    # Apply personalization settings
    $enabledPersonalizations = $personalizations | Where-Object { $_.Enabled }
    
    if ($enabledPersonalizations.Count -eq 0) {
        Write-Host "No personalization options selected." -ForegroundColor $script:Colors.Warning
        Invoke-ReturnToMenu
        return
    }
    
    Write-Host ""
    Write-Host "Applying $($enabledPersonalizations.Count) personalization option(s)..." -ForegroundColor $script:Colors.Info
    Write-Host ""
    
    $step = 0
    $totalSteps = $enabledPersonalizations.Count
    $successCount = 0
    $failureCount = 0
    
    try {
        foreach ($personalization in $enabledPersonalizations) {
            $step++
            $percent = [int](($step / $totalSteps) * 100)
            Show-Progress -Activity "Personalizing Windows" -Status "[$step/$totalSteps] $($personalization.Name)" -PercentComplete $percent
            Start-Sleep -Milliseconds 300
            
            # Handle performance optimization separately (requires multiple registry changes)
            if ($personalization.Key -eq "Performance") {
                $applied = Apply-PerformanceOptimization
                if ($applied) {
                    Write-Log "Applied personalization: $($personalization.Name)" -Level Success
                    $successCount++
                } else {
                    Write-Log "Failed to apply personalization: $($personalization.Name)" -Level Warning
                    $failureCount++
                }
            } else {
                # Apply other personalizations with registry primary method and Group Policy fallback
                $applied = Apply-RestrictionWithFallback -Restriction $personalization
                if ($applied) {
                    Write-Log "Applied personalization: $($personalization.Name)" -Level Success
                    $successCount++
                } else {
                    Write-Log "Failed to apply personalization: $($personalization.Name)" -Level Warning
                    $failureCount++
                }
            }
        }
        
        Show-Progress -Activity "Personalizing Windows" -Status "Complete" -PercentComplete 100
        Start-Sleep -Milliseconds 500
        Write-Progress -Activity "Personalizing Windows" -Completed
        
        Write-Host ""
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host " Personalization Summary" -ForegroundColor $script:Colors.Success
        Write-Host $script:Line80 -ForegroundColor $script:Colors.Success
        Write-Host ""
        Write-Host "Total options selected:    $($enabledPersonalizations.Count)" -ForegroundColor $script:Colors.Info
        Write-Host "Successfully applied:      $successCount" -ForegroundColor $script:Colors.Success
        if ($failureCount -gt 0) {
            Write-Host "Failed to apply:           $failureCount" -ForegroundColor $script:Colors.Warning
        }
        Write-Host ""
        Write-Host "Applied changes:" -ForegroundColor $script:Colors.Info
        foreach ($personalization in $enabledPersonalizations) {
            Write-Host "  ✓ $($personalization.Name)" -ForegroundColor $script:Colors.Success
        }
        Write-Host ""
        Write-Host "Note: Some changes require a logoff or restart to take full effect." -ForegroundColor $script:Colors.Warning
        
    } catch {
        Write-Log "Failed to apply personalization settings: $_" -Level Error
        Write-Host ""
        Write-Host "Failed to apply personalization settings: $_" -ForegroundColor $script:Colors.Error
    }
    
    Invoke-ReturnToMenu
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
        Invoke-ReturnToMenu
        return
    }
    
    # Validate computer name
    if ($newName -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,13}[a-zA-Z0-9])?$') {
        Write-Host ""
        Write-Host "Invalid computer name!" -ForegroundColor $script:Colors.Error
        Write-Host "Please follow the naming requirements." -ForegroundColor $script:Colors.Error
        Invoke-ReturnToMenu
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
    
    Invoke-ReturnToMenu
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
    Write-Host "  [6] Windows Personalization & Cleanup" -ForegroundColor $script:Colors.Info
    Write-Host "  [7] Rename Computer" -ForegroundColor $script:Colors.Info
    Write-Host "  [8] Documentation & Help" -ForegroundColor $script:Colors.Info
    Write-Host "  [0] Exit" -ForegroundColor $script:Colors.Warning
    Write-Host ""
    
    $choice = Read-Host "Enter your choice"
    
    switch ($choice) {
        '1' { Show-SystemInformation }
        '2' { Install-Veyon }
        '3' { Uninstall-Veyon }
        '4' { Set-VeyonConfiguration }
        '5' { Set-UserRestrictions }
        '6' { Set-WindowsPersonalization }
        '7' { Rename-ComputerMenu }
        '8' { Show-Documentation }
        '0' { 
            Write-Host ""
            Write-Host "Thank you for using Veyon Installation Tool!" -ForegroundColor $script:Colors.Info
            Write-Log "Script exited by user"
            Show-FinalStatus
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
        Invoke-ReturnToMenu
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
        Invoke-ReturnToMenu
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
    
    # Rotate logs before starting new session
    Rotate-Logs -MaxFiles 7 -MaxSizeMB 5

    # Start transcript if verbose logging enabled
    if ($script:Config.LogVerbose) {
        try {
            Start-Transcript -Path $script:Config.LogPath -Append -ErrorAction SilentlyContinue
            Write-Log "Transcript started" -Level Info
        } catch {
            Write-Log "Could not start transcript: $_" -Level Warning
        }
    }
    
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
        Show-FinalStatus
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