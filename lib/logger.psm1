function Init-Logger {
    param(
        [Parameter(Mandatory=$false)] [string] $RootPath = $PSScriptRoot
    )
    try {
        if (-not $RootPath) { $RootPath = $PSScriptRoot }
        $logDir = Join-Path -Path $RootPath -ChildPath 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        $machine = [System.Environment]::MachineName
        $time = Get-Date -Format 'yyyyMMdd_HHmmss'
        $file = Join-Path -Path $logDir -ChildPath ("$machine" + "_" + "$time.log")
        Set-Variable -Name LoggerFile -Value $file -Scope Global -Force
        Write-Log -Level 'INFO' -Message "Logger initialized. Log file: $file"
        return $file
    } catch {
        Write-Error "Failed to initialize logger: $_"
        throw
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('DEBUG','VERBOSE','INFO','WARN','ERROR','FATAL')] [string] $Level,
        [Parameter(Mandatory=$true)][string] $Message
    )
    try {
        if (-not (Get-Variable -Name LoggerFile -Scope Global -ErrorAction SilentlyContinue)) {
            $fallbackDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'logs'
            if (-not (Test-Path $fallbackDir)) { New-Item -ItemType Directory -Path $fallbackDir | Out-Null }
            $machine = [System.Environment]::MachineName
            $time = Get-Date -Format 'yyyyMMdd_HHmmss'
            $global:LoggerFile = Join-Path -Path $fallbackDir -ChildPath ("$machine" + "_" + "$time.log")
        }
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$timestamp] [$Level] $Message"
        $global:LoggerFile | Out-Null
        Add-Content -Path $global:LoggerFile -Value $line
    } catch {
        Write-Error "Failed to write log: $_"
    }
}

function Write-Exception {
    param(
        [Parameter(Mandatory=$true)][System.Management.Automation.ErrorRecord] $ErrorRecord
    )
    try {
        $ex = $ErrorRecord.Exception
        $msg = "Exception: $($ex.GetType().FullName) - $($ex.Message)"
        $stack = if ($ex.StackTrace) { "StackTrace: $($ex.StackTrace)" } else { '' }
        Write-Log -Level 'ERROR' -Message $msg
        if ($stack) { Write-Log -Level 'ERROR' -Message $stack }
        if ($ex.InnerException) { Write-Log -Level 'ERROR' -Message ("Inner: $($ex.InnerException.Message)") }
    } catch {
        Write-Error "Failed to write exception log: $_"
    }
}

Export-ModuleMember -Function Init-Logger, Write-Log, Write-Exception
