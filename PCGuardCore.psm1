# Shared core functions used by both the background watchdog (PCGuard.ps1)
# and the GUI (PCGuard-GUI.ps1).

$script:TaskName = 'PCGuard-Watchdog'

function Get-SystemHealth {
    param([int]$TopProcessCount = 8)

    $os = Get-CimInstance Win32_OperatingSystem
    $ramFreePercent = [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
    $ramFreeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)

    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average

    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        [PSCustomObject]@{
            Drive       = $_.DeviceID
            FreePercent = [math]::Round(($_.FreeSpace / $_.Size) * 100, 1)
            FreeGB      = [math]::Round($_.FreeSpace / 1GB, 1)
            SizeGB      = [math]::Round($_.Size / 1GB, 1)
        }
    }

    $topProcs = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First $TopProcessCount |
        ForEach-Object {
            [PSCustomObject]@{
                Name  = $_.Name
                MemMB = [math]::Round($_.WorkingSet / 1MB, 0)
            }
        }

    [PSCustomObject]@{
        RamFreePercent = $ramFreePercent
        RamFreeGB      = $ramFreeGB
        RamTotalGB     = $ramTotalGB
        CpuPercent     = $cpu
        Disks          = $disks
        TopProcesses   = $topProcs
        Timestamp      = Get-Date
    }
}

function Invoke-SafeCleanup {
    $freedMB = 0
    $targets = @(
        "$env:LOCALAPPDATA\Temp",
        "$env:LOCALAPPDATA\npm-cache",
        "C:\Windows\Temp"
    )
    foreach ($t in $targets) {
        if (Test-Path $t) {
            $before = (Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue -Directory |
                Where-Object { (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0 } |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            $after = (Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $freedMB += [math]::Round((($before - $after) / 1MB), 1)
        }
    }
    return $freedMB
}

function Test-WatchdogInstalled {
    return [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
}

function Install-Watchdog {
    param([string]$ScriptDir, [int]$IntervalMinutes = 15)

    $scriptPath = Join-Path $ScriptDir 'PCGuard.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    # Stagger any post-boot catch-up run so it doesn't fire in the first
    # busy moments right after login, alongside everything else starting up.
    $trigger.Delay = 'PT2M'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description "Monitors RAM/CPU/disk and alerts or cleans up when the PC is under pressure." `
        -Force -ErrorAction Stop | Out-Null
}

function Uninstall-Watchdog {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-RecentAlerts {
    param([string]$LogDir, [int]$Count = 20)

    $logFile = Join-Path $LogDir ("pcguard_{0:yyyy-MM}.log" -f (Get-Date))
    if (-not (Test-Path $logFile)) { return @() }
    $result = @(Get-Content $logFile -Tail 400 | Where-Object { $_ -match 'ALERT' } | Select-Object -Last $Count)
    return $result
}

function Get-HealthHistory {
    # Parses the watchdog's own log lines (not the GUI's live scans) into a time series
    # for the trend chart. Returns points oldest-first.
    param([string]$LogDir, [int]$MaxPoints = 50)

    $logFile = Join-Path $LogDir ("pcguard_{0:yyyy-MM}.log" -f (Get-Date))
    if (-not (Test-Path $logFile)) { return @() }

    $lines = Get-Content $logFile -Tail 2000
    $points = @()
    $current = $null
    foreach ($line in $lines) {
        if ($line -match 'RAM:\s*([\d.]+)%\s*free.*\|\s*CPU:\s*([\d.]+)?%?') {
            if ($current) { $points += [PSCustomObject]$current }
            $current = @{ RamFree = [double]$matches[1]; Cpu = if ($matches[2]) { [double]$matches[2] } else { 0 }; DiskCFree = $null }
        }
        elseif ($line -match 'Disk C:: ([\d.]+)% free' -and $current) {
            $current.DiskCFree = [double]$matches[1]
        }
    }
    if ($current) { $points += [PSCustomObject]$current }
    return $points | Select-Object -Last $MaxPoints
}

function Get-TopFolders {
    # Scans the immediate subfolders of a path and sizes them. Can be slow on large
    # trees, so the GUI runs this inside a background job.
    param([string]$Path, [int]$Top = 15)

    Get-ChildItem $Path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $size = (Get-ChildItem $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        [PSCustomObject]@{ Folder = $_.FullName; SizeGB = [math]::Round($size / 1GB, 2) }
    } | Sort-Object SizeGB -Descending | Select-Object -First $Top
}

function Get-WslDockerInfo {
    $vmmem = Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue
    $wslMemMB = if ($vmmem) { [math]::Round(($vmmem | Measure-Object WorkingSet -Sum).Sum / 1MB, 0) } else { 0 }

    $distros = @()
    try {
        $env:WSL_UTF8 = '1'
        $raw = (wsl --list --verbose 2>$null) -join "`n"
        if ($raw) {
            $distros = $raw -split "`r?`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' } |
                ForEach-Object { ($_ -replace '^\*', '').Trim() -split '\s+' | Select-Object -First 1 } |
                Where-Object { $_.Length -gt 1 }
        }
    } catch {}

    $dockerPath = "$env:LOCALAPPDATA\Docker"
    $dockerGB = 0
    if (Test-Path $dockerPath) {
        $dockerGB = [math]::Round(((Get-ChildItem $dockerPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2)
    }
    $wslDiskPath = "$env:LOCALAPPDATA\wsl"
    $wslDiskGB = 0
    if (Test-Path $wslDiskPath) {
        $wslDiskGB = [math]::Round(((Get-ChildItem $wslDiskPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2)
    }

    [PSCustomObject]@{
        WslRunningMemMB = $wslMemMB
        Distros         = $distros
        DockerDiskGB    = $dockerGB
        WslDiskGB       = $wslDiskGB
    }
}

function Invoke-WslShutdown {
    wsl --shutdown 2>$null
}

function Get-PCGuardConfig {
    param([string]$RootDir)
    $path = Join-Path $RootDir 'config.json'
    $cfg = [ordered]@{
        RamFreePercentWarn       = 15
        DiskFreePercentWarn      = 10
        DiskFreePercentCritical  = 8
        AutoClean                = $true
        UnwantedProcesses        = @()
        FocusMode                = $false
        WebhookUrl               = ''
        WebhookType              = 'Slack'
        AiEnabled                = $false
        AiModel                  = 'qwen2.5:3b'
        AnthropicApiKey          = ''
        ClaudeModel              = 'claude-sonnet-5-5'
        CustomRules              = @()
        AutoApproveActions       = @()
    }
    if (Test-Path $path) {
        try {
            $loaded = Get-Content $path -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $loaded.$k) { $cfg[$k] = $loaded.$k }
            }
        } catch {}
    }
    return [PSCustomObject]$cfg
}

function Save-PCGuardConfig {
    param([string]$RootDir, [PSCustomObject]$Config)
    $path = Join-Path $RootDir 'config.json'
    $Config | ConvertTo-Json | Set-Content -Path $path -Encoding UTF8
}

function Export-HealthReport {
    param([string]$RootDir, [string]$LogDir)

    $health = Get-SystemHealth -TopProcessCount 15
    $wslInfo = Get-WslDockerInfo
    $alerts = Get-RecentAlerts -LogDir $LogDir -Count 30
    $reportPath = Join-Path $RootDir ("PCGuard-Report_{0:yyyyMMdd_HHmmss}.html" -f (Get-Date))

    $procRows = ($health.TopProcesses | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.MemMB) MB</td></tr>" }) -join "`n"
    $diskRows = ($health.Disks | ForEach-Object { "<tr><td>$($_.Drive)</td><td>$($_.FreePercent)%</td><td>$($_.FreeGB) GB / $($_.SizeGB) GB</td></tr>" }) -join "`n"
    $alertRows = if ($alerts.Count -gt 0) { ($alerts | ForEach-Object { "<li>$_</li>" }) -join "`n" } else { "<li>None recorded</li>" }

    $html = @"
<html><head><title>PCGuard Report</title>
<style>body{font-family:Segoe UI,Arial;background:#1e1e1e;color:#e0e0e0;padding:24px}
table{border-collapse:collapse;margin-bottom:20px}td,th{padding:6px 14px;border:1px solid #444;text-align:left}
h1,h2{color:#fff}</style></head><body>
<h1>PCGuard System Report</h1>
<p>Generated: $(Get-Date)</p>
<h2>RAM</h2><p>$($health.RamFreePercent)% free ($($health.RamFreeGB) GB / $($health.RamTotalGB) GB)</p>
<h2>CPU</h2><p>$($health.CpuPercent)% load</p>
<h2>Disks</h2><table><tr><th>Drive</th><th>Free %</th><th>Free / Total</th></tr>$diskRows</table>
<h2>Top Processes</h2><table><tr><th>Name</th><th>Memory</th></tr>$procRows</table>
<h2>WSL / Docker</h2><p>WSL running memory: $($wslInfo.WslRunningMemMB) MB | Docker disk use: $($wslInfo.DockerDiskGB) GB | WSL disk use: $($wslInfo.WslDiskGB) GB</p>
<h2>Recent Alerts</h2><ul>$alertRows</ul>
</body></html>
"@
    $html | Set-Content -Path $reportPath -Encoding UTF8
    return $reportPath
}

function Get-NetworkStats {
    # Cumulative counters since the adapter was last reset (not since app start).
    # Callers sample this twice and divide by elapsed time to get a live rate.
    $adapters = Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Where-Object {
        $_.ReceivedBytes -gt 0 -or $_.SentBytes -gt 0
    } | ForEach-Object {
        [PSCustomObject]@{
            Name          = $_.Name
            SentMB        = [math]::Round($_.SentBytes / 1MB, 2)
            ReceivedMB    = [math]::Round($_.ReceivedBytes / 1MB, 2)
            SentBytes     = $_.SentBytes
            ReceivedBytes = $_.ReceivedBytes
        }
    }
    $totalSent = ($adapters | Measure-Object SentBytes -Sum).Sum
    $totalRecv = ($adapters | Measure-Object ReceivedBytes -Sum).Sum

    [PSCustomObject]@{
        Adapters           = $adapters
        TotalSentBytes     = [double]$totalSent
        TotalReceivedBytes = [double]$totalRecv
        Timestamp          = Get-Date
    }
}

function Get-ActiveConnections {
    param([int]$Top = 200)

    $procCache = @{}
    Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object -First $Top | ForEach-Object {
        $procId = $_.OwningProcess
        if (-not $procCache.ContainsKey($procId)) {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $procCache[$procId] = if ($p) { $p.ProcessName } else { "PID $procId" }
        }
        [PSCustomObject]@{
            Process       = $procCache[$procId]
            Pid           = $procId
            LocalAddress  = $_.LocalAddress
            LocalPort     = $_.LocalPort
            RemoteAddress = $_.RemoteAddress
            RemotePort    = $_.RemotePort
            State         = if ($_.State) { $_.State.ToString() } else { 'Unknown' }
        }
    } | Sort-Object Process, RemoteAddress
}

function Get-NetworkHistory {
    # Parses NET lines the watchdog logs each run, returns cumulative points
    # oldest-first. The GUI converts consecutive points into per-interval deltas.
    param([string]$LogDir, [int]$MaxPoints = 50)

    $logFile = Join-Path $LogDir ("pcguard_{0:yyyy-MM}.log" -f (Get-Date))
    if (-not (Test-Path $logFile)) { return @() }

    $points = @()
    Get-Content $logFile -Tail 2000 | ForEach-Object {
        if ($_ -match 'NET: sent=([\d.]+)MB recv=([\d.]+)MB') {
            $sentMB = [double]$matches[1]
            $recvMB = [double]$matches[2]
            $ts = $null
            if ($_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { $ts = [datetime]$matches[1] }
            $points += [PSCustomObject]@{ Timestamp = $ts; SentMB = $sentMB; ReceivedMB = $recvMB }
        }
    }
    return $points | Select-Object -Last $MaxPoints
}

function Get-SystemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $uptime = (Get-Date) - $os.LastBootUpTime

    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $batteryText = if ($battery) {
        $statusMap = @{ 1='Discharging'; 2='On AC'; 3='Fully Charged'; 4='Low'; 5='Critical'; 6='Charging'; 7='Charging High'; 8='Charging Low'; 9='Charging Critical'; 10='Unknown'; 11='Partially Charged' }
        $st = $statusMap[[int]$battery.BatteryStatus]
        "$($battery.EstimatedChargeRemaining)% ($st)"
    } else { "No battery (desktop)" }

    $gpuPercent = $null
    try {
        $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $gpuPercent = [math]::Round((($samples | Measure-Object CookedValue -Sum).Sum), 1)
        if ($gpuPercent -gt 100) { $gpuPercent = 100 }
    } catch { $gpuPercent = $null }

    [PSCustomObject]@{
        UptimeText  = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
        BootTime    = $os.LastBootUpTime
        BatteryText = $batteryText
        GpuPercent  = $gpuPercent
    }
}

function Get-DiskIoStats {
    try {
        $samples = (Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec', '\PhysicalDisk(_Total)\Disk Write Bytes/sec' -ErrorAction Stop).CounterSamples
        $read  = ($samples | Where-Object { $_.Path -like '*read*' } | Select-Object -First 1).CookedValue
        $write = ($samples | Where-Object { $_.Path -like '*write*' } | Select-Object -First 1).CookedValue
        [PSCustomObject]@{ ReadMBs = [math]::Round($read / 1MB, 2); WriteMBs = [math]::Round($write / 1MB, 2); Available = $true }
    } catch {
        [PSCustomObject]@{ ReadMBs = 0; WriteMBs = 0; Available = $false }
    }
}

function Get-RecentSystemEvents {
    param([int]$Hours = 24, [int]$Top = 15)
    try {
        $since = (Get-Date).AddHours(-$Hours)
        @(Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $since } -MaxEvents $Top -ErrorAction Stop |
            ForEach-Object {
                [PSCustomObject]@{
                    Time    = $_.TimeCreated
                    Log     = $_.LogName
                    Level   = $_.LevelDisplayName
                    Source  = $_.ProviderName
                    Message = (($_.Message -split "`r?`n")[0])
                }
            })
    } catch {
        @()
    }
}

function Get-ScheduledTasksList {
    param([int]$Top = 400)
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name        = $_.TaskName
            Path        = $_.TaskPath
            State       = $_.State.ToString()
            LastRunTime = if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 1700) { $info.LastRunTime } else { $null }
            NextRunTime = if ($info -and $info.NextRunTime -and $info.NextRunTime.Year -gt 1700) { $info.NextRunTime } else { $null }
            Author      = $_.Author
        }
    } | Sort-Object Name | Select-Object -First $Top
}

function Set-ScheduledTaskState {
    param([string]$TaskName, [string]$TaskPath, [bool]$Enable)
    if ($Enable) {
        Enable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Out-Null
    } else {
        Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Out-Null
    }
}

function Get-ProcessesDetailed {
    Get-Process | ForEach-Object {
        $responding = $true
        try { $responding = $_.Responding } catch {}
        $priority = $null
        try { $priority = $_.PriorityClass.ToString() } catch {}
        $threads = 0
        try { $threads = $_.Threads.Count } catch {}
        $start = $null
        try { $start = $_.StartTime } catch {}
        [PSCustomObject]@{
            Name      = $_.Name
            Id        = $_.Id
            Status    = if ($responding) { 'Responding' } else { 'Not Responding' }
            MemMB     = [math]::Round($_.WorkingSet / 1MB, 1)
            CpuSec    = if ($_.CPU) { [math]::Round($_.CPU, 1) } else { 0 }
            Threads   = $threads
            Priority  = $priority
            StartTime = $start
        }
    } | Sort-Object MemMB -Descending
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
    foreach ($c in $children) { Stop-ProcessTree -ProcessId $c.ProcessId }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Set-ProcessPriority {
    param([int]$ProcessId, [string]$Priority)
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$Priority
}

function Get-ProcessFilePath {
    param([int]$ProcessId)
    try { (Get-Process -Id $ProcessId -ErrorAction Stop).Path } catch { $null }
}

function Invoke-FreeUpRam {
    # Trims the working set of eligible background processes (EmptyWorkingSet,
    # a documented Win32 API) so Windows reclaims pages those apps aren't
    # actively using. This is a real, bounded optimization - not a "RAM cleaner"
    # gimmick - and processes simply reallocate pages back as needed.
    param([string[]]$ExcludeNames = @())

    if (-not ('PCGuardNative.Memory' -as [type])) {
        Add-Type -Namespace PCGuardNative -Name Memory -MemberDefinition @"
[DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(IntPtr hProcess);
"@
    }

    $critical = @('System', 'Idle', 'smss', 'csrss', 'wininit', 'services', 'lsass', 'winlogon', 'dwm', 'Registry', 'MemCompression') + $ExcludeNames
    $before = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
    $trimmed = 0
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($critical -contains $p.ProcessName) { continue }
        if ($p.Id -eq $PID) { continue }
        try {
            if ([PCGuardNative.Memory]::EmptyWorkingSet($p.Handle)) { $trimmed++ }
        } catch {}
    }
    Start-Sleep -Milliseconds 400
    $after = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory

    [PSCustomObject]@{
        ProcessesTrimmed = $trimmed
        FreedMB          = [math]::Round(($after - $before) / 1024, 1)
    }
}

function Invoke-StopUnwantedProcesses {
    param([string[]]$Names)
    $stopped = @()
    foreach ($n in $Names) {
        $n = $n.Trim()
        if (-not $n) { continue }
        foreach ($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                $stopped += "$($p.ProcessName) (PID $($p.Id))"
            } catch {}
        }
    }
    return $stopped
}

function Invoke-CreateRestorePoint {
    param([string]$Description = "Cortexa manual checkpoint")
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        [PSCustomObject]@{ Success = $true; Message = "Restore point created: $Description" }
    } catch {
        [PSCustomObject]@{ Success = $false; Message = $_.Exception.Message }
    }
}

function Get-StartupItemsDetailed {
    $items = @()

    foreach ($hive in @(
        @{ Root = 'HKCU:'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Root = 'HKLM:'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run' }
    )) {
        $full = Join-Path $hive.Root $hive.Path
        if (Test-Path $full) {
            $key = Get-Item $full
            foreach ($valueName in $key.GetValueNames()) {
                if (-not $valueName) { continue }
                $items += [PSCustomObject]@{
                    Name    = $valueName
                    Command = $key.GetValue($valueName)
                    Source  = 'Registry'
                    Hive    = $hive.Root
                    KeyPath = $hive.Path
                    Enabled = $true
                }
            }
        }
    }

    $startupFolders = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )
    foreach ($folder in $startupFolders) {
        if (Test-Path $folder) {
            Get-ChildItem $folder -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
                $items += [PSCustomObject]@{
                    Name    = $_.BaseName
                    Command = $_.FullName
                    Source  = 'Startup Folder'
                    Hive    = $null
                    KeyPath = $folder
                    Enabled = $true
                }
            }
        }
    }

    $disabledDir = Join-Path $PSScriptRoot 'DisabledStartupItems'
    if (Test-Path $disabledDir) {
        Get-ChildItem $disabledDir -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Extension -eq '.lnk') {
                $items += [PSCustomObject]@{ Name = $_.BaseName; Command = $_.FullName; Source = 'Startup Folder'; Hive = $null; KeyPath = $disabledDir; Enabled = $false }
            } elseif ($_.Extension -eq '.json') {
                try {
                    $backup = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $items += [PSCustomObject]@{ Name = $backup.Name; Command = $backup.Command; Source = 'Registry'; Hive = $backup.Hive; KeyPath = $backup.KeyPath; Enabled = $false }
                } catch {}
            }
        }
    }

    return $items | Sort-Object Name
}

function Disable-StartupItem {
    param([PSCustomObject]$Item, [string]$RootDir)
    $disabledDir = Join-Path $RootDir 'DisabledStartupItems'
    if (-not (Test-Path $disabledDir)) { New-Item -ItemType Directory -Path $disabledDir | Out-Null }

    if ($Item.Source -eq 'Registry') {
        $backup = @{ Name = $Item.Name; Command = $Item.Command; Hive = $Item.Hive; KeyPath = $Item.KeyPath }
        $backupFile = Join-Path $disabledDir ("{0}.json" -f ($Item.Name -replace '[\\/:*?"<>|]', '_'))
        $backup | ConvertTo-Json | Set-Content -Path $backupFile -Encoding UTF8
        Remove-ItemProperty -Path (Join-Path $Item.Hive $Item.KeyPath) -Name $Item.Name -ErrorAction Stop
    } else {
        $dest = Join-Path $disabledDir (Split-Path $Item.Command -Leaf)
        Move-Item -Path $Item.Command -Destination $dest -Force -ErrorAction Stop
    }
}

function Enable-StartupItem {
    param([PSCustomObject]$Item, [string]$RootDir)
    $disabledDir = Join-Path $RootDir 'DisabledStartupItems'

    if ($Item.Source -eq 'Registry') {
        $backupFile = Join-Path $disabledDir ("{0}.json" -f ($Item.Name -replace '[\\/:*?"<>|]', '_'))
        $full = Join-Path $Item.Hive $Item.KeyPath
        if (-not (Test-Path $full)) { New-Item -Path $full -Force | Out-Null }
        New-ItemProperty -Path $full -Name $Item.Name -Value $Item.Command -PropertyType String -Force | Out-Null
        if (Test-Path $backupFile) { Remove-Item $backupFile -Force }
    } else {
        $startupFolder = [Environment]::GetFolderPath('Startup')
        $dest = Join-Path $startupFolder (Split-Path $Item.Command -Leaf)
        Move-Item -Path $Item.Command -Destination $dest -Force -ErrorAction Stop
    }
}

function Get-SecurityStatus {
    $defender = $null
    try { $defender = Get-MpComputerStatus -ErrorAction Stop } catch {}

    $firewall = @()
    try { $firewall = Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name, Enabled } catch {}

    $bitlocker = @()
    try { $bitlocker = Get-BitLockerVolume -ErrorAction Stop | Select-Object MountPoint, VolumeStatus, ProtectionStatus } catch {}

    $pnpErrors = @()
    try { $pnpErrors = Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -eq 'Error' } | Select-Object FriendlyName, InstanceId, Status } catch {}

    [PSCustomObject]@{
        DefenderEnabled       = if ($defender) { $defender.AntivirusEnabled } else { $null }
        RealTimeProtection    = if ($defender) { $defender.RealTimeProtectionEnabled } else { $null }
        SignaturesAge         = if ($defender) { $defender.AntivirusSignatureAge } else { $null }
        Firewall              = @($firewall)
        BitLocker             = @($bitlocker)
        PnpErrors             = @($pnpErrors)
    }
}

function Get-DiskHealth {
    try {
        Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            $counters = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                FriendlyName    = $_.FriendlyName
                MediaType       = $_.MediaType
                HealthStatus    = $_.HealthStatus
                OperationalStatus = ($_.OperationalStatus -join ', ')
                TemperatureC    = if ($counters) { $counters.Temperature } else { $null }
                WearPercent     = if ($counters -and $counters.Wear) { $counters.Wear } else { $null }
                ReadErrors      = if ($counters) { $counters.ReadErrorsTotal } else { $null }
            }
        }
    } catch {
        @()
    }
}

function Get-BatteryHealthReport {
    param([string]$RootDir)
    $hasBattery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if (-not $hasBattery) { return [PSCustomObject]@{ Available = $false } }

    $reportsDir = Join-Path $RootDir 'Reports'
    if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir | Out-Null }
    $htmlPath = Join-Path $reportsDir "BatteryReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    $xmlPath = [System.IO.Path]::ChangeExtension($htmlPath, '.xml')

    try {
        powercfg /batteryreport /output $htmlPath /duration 7 | Out-Null
        powercfg /batteryreport /output $xmlPath /xml /duration 7 | Out-Null

        $designCapacity = $null
        $fullChargeCapacity = $null
        if (Test-Path $xmlPath) {
            [xml]$xml = Get-Content $xmlPath -Raw
            $designCapacity = [double]$xml.BatteryReport.Design.DesignCapacity
            $fullChargeCapacity = [double]$xml.BatteryReport.Design.FullChargeCapacity
        }
        $wearPercent = if ($designCapacity -and $fullChargeCapacity) { [math]::Round((1 - ($fullChargeCapacity / $designCapacity)) * 100, 1) } else { $null }

        [PSCustomObject]@{
            Available          = $true
            HtmlPath           = $htmlPath
            DesignCapacity     = $designCapacity
            FullChargeCapacity = $fullChargeCapacity
            WearPercent        = $wearPercent
        }
    } catch {
        [PSCustomObject]@{ Available = $false; Error = $_.Exception.Message }
    }
}

function Get-LargestFiles {
    param([string]$Path, [int]$Top = 30)
    Get-ChildItem $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First $Top |
        ForEach-Object { [PSCustomObject]@{ FilePath = $_.FullName; SizeMB = [math]::Round($_.Length / 1MB, 2) } }
}

function Export-PCGuardSettings {
    param([string]$RootDir, [string]$DestPath)
    $configPath = Join-Path $RootDir 'config.json'
    if (Test-Path $configPath) { Copy-Item $configPath $DestPath -Force }
}

function Import-PCGuardSettings {
    param([string]$RootDir, [string]$SourcePath)
    $configPath = Join-Path $RootDir 'config.json'
    Copy-Item $SourcePath $configPath -Force
}

function Send-WebhookAlert {
    param([string]$WebhookUrl, [string]$WebhookType, [string]$Message)
    if (-not $WebhookUrl) { return }
    try {
        $body = if ($WebhookType -eq 'Discord') { @{ content = $Message } } else { @{ text = $Message } }
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body ($body | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop | Out-Null
    } catch {}
}

function Test-OllamaAvailable {
    param([string]$BaseUrl = 'http://localhost:11434')
    try {
        $tags = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -TimeoutSec 3 -ErrorAction Stop
        [PSCustomObject]@{ Available = $true; Models = @($tags.models | ForEach-Object { $_.name }) }
    } catch {
        [PSCustomObject]@{ Available = $false; Models = @() }
    }
}

function Start-OllamaServer {
    $exe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (-not (Test-Path $exe)) { return $false }
    Start-Process $exe -ArgumentList "serve" -WindowStyle Hidden
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        if ((Test-OllamaAvailable).Available) { return $true }
    }
    return $false
}

function Invoke-OllamaGenerate {
    param([string]$Model, [string]$Prompt, [string]$SystemPrompt = '', [string]$BaseUrl = 'http://localhost:11434', [int]$TimeoutSec = 60)
    $body = @{ model = $Model; prompt = $Prompt; system = $SystemPrompt; stream = $false } | ConvertTo-Json
    try {
        $result = Invoke-RestMethod -Uri "$BaseUrl/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
        [PSCustomObject]@{ Success = $true; Response = $result.response }
    } catch {
        [PSCustomObject]@{ Success = $false; Response = $_.Exception.Message }
    }
}

function Get-AiSystemContext {
    # A compact plain-text snapshot of current system state, sized for a small
    # local model's context window - not the full detail Cortexa's own UI shows.
    $health = Get-SystemHealth -TopProcessCount 6
    $sysInfo = Get-SystemInfo
    $sec = Get-SecurityStatus

    $lines = @()
    $lines += "RAM: $($health.RamFreePercent)% free ($($health.RamFreeGB) GB of $($health.RamTotalGB) GB)"
    $lines += "CPU load: $($health.CpuPercent)%"
    foreach ($d in $health.Disks) { $lines += "Disk $($d.Drive) $($d.FreePercent)% free ($($d.FreeGB) GB of $($d.SizeGB) GB)" }
    $lines += "Uptime: $($sysInfo.UptimeText)"
    $lines += "Battery: $($sysInfo.BatteryText)"
    $lines += "Top processes by memory: " + (($health.TopProcesses | ForEach-Object { "$($_.Name) $($_.MemMB)MB" }) -join ', ')
    $lines += "Windows Defender enabled: $($sec.DefenderEnabled); real-time protection: $($sec.RealTimeProtection)"
    if ($sec.PnpErrors.Count -gt 0) { $lines += "Devices with driver errors: " + (($sec.PnpErrors | ForEach-Object { $_.FriendlyName }) -join ', ') }
    return ($lines -join "`n")
}

$script:AiSystemPrompt = @"
You are Cortexa, an AI assistant built into a Windows PC health monitoring app. You are given a live snapshot of the user's system (RAM, CPU, disk, processes, security status). Your job: give a short, plain-language diagnosis of anything concerning, and up to 3 concrete, prioritized recommendations.

Rules:
- Be concise. Prefer short sentences and a short bullet list over long paragraphs.
- Only flag things that are actually concerning given the numbers; do not invent problems.
- You cannot take any action yourself - only suggest what the user should click/do in the Cortexa app (e.g. "Free Up RAM", "Clean Temp Junk", "Stop Unwanted Software", "Speed Boost Now", check the Startup or Security tab).
- Never ask the user to run arbitrary commands or install unrelated software.
- End your reply with one line starting exactly with "SUGGESTED_ACTIONS:" followed by a comma-separated list using ONLY these exact tokens, including only the ones that actually apply: FreeRam, CleanTemp, StopUnwanted, SpeedBoost, ShutdownWsl, RestorePoint. If none apply, write "SUGGESTED_ACTIONS: None".
"@

function Get-AiHistoricalBaseline {
    # A short "what's normal for this PC" summary from the watchdog's own
    # logged history, so the AI can say whether today's numbers are actually
    # unusual rather than judging them in isolation. Returns $null until
    # there's enough history to be meaningful.
    param([string]$LogDir, [int]$MinPoints = 3)
    $points = @(Get-HealthHistory -LogDir $LogDir -MaxPoints 200)
    if ($points.Count -lt $MinPoints) { return $null }

    $avgRam = [math]::Round(($points | Measure-Object -Property RamFree -Average).Average, 1)
    $avgCpu = [math]::Round(($points | Measure-Object -Property Cpu -Average).Average, 1)
    $diskPoints = @($points | Where-Object { $null -ne $_.DiskCFree })
    $avgDisk = if ($diskPoints.Count -gt 0) { [math]::Round(($diskPoints | Measure-Object -Property DiskCFree -Average).Average, 1) } else { $null }

    $diskText = if ($null -ne $avgDisk) { "Disk C free avg $avgDisk%" } else { "" }
    "Historical baseline for this PC (last $($points.Count) watchdog scans): RAM free avg $avgRam%, CPU avg $avgCpu%. $diskText"
}

function Invoke-AiSystemAnalysis {
    param([string]$Model, [string]$LogDir = $null, [string]$BaseUrl = 'http://localhost:11434')
    $context = Get-AiSystemContext
    $baseline = if ($LogDir) { Get-AiHistoricalBaseline -LogDir $LogDir } else { $null }
    $prompt = "Here is the current system snapshot:`n$context"
    if ($baseline) {
        $prompt += "`n`n$baseline`n`nCompare today's numbers to this baseline - call out anything that is unusual for THIS specific PC, not just generically high or low."
    }
    $prompt += "`n`nGive your diagnosis and recommendations."
    Invoke-OllamaGenerate -Model $Model -Prompt $prompt -SystemPrompt $script:AiSystemPrompt -BaseUrl $BaseUrl -TimeoutSec 60
}

# Actions eligible for per-action auto-approve, hard-coded independent of
# anything the UI or config ever sends in - this is the real enforcement
# point, not just a UI restriction. Deliberately excludes anything that ends
# a process, stops software, or touches System Restore.
$script:AutoApproveEligibleActions = @('FreeRam', 'CleanTemp')

function Get-AutoApproveEligibleActions {
    # Module-internal $script: variables aren't visible across the module
    # boundary, so the GUI must go through this accessor rather than trying
    # to read $script:AutoApproveEligibleActions directly - that would
    # silently resolve to nothing in the importing script's own scope.
    return $script:AutoApproveEligibleActions
}

function Invoke-AiParseRule {
    param([string]$Model, [string]$UserText, [string]$BaseUrl = 'http://localhost:11434')
    $sys = @"
You turn a plain-language monitoring request into a structured rule for Cortexa, a PC monitoring app. Cortexa can only watch ONE thing: whether a named process's memory usage exceeds a threshold.

Reply with ONLY one line:
RULE: process=<process name, no .exe>;thresholdMB=<whole number of megabytes>

Examples:
"tell me if chrome uses more than 2GB" -> RULE: process=chrome;thresholdMB=2048
"alert me if spotify goes over 500mb" -> RULE: process=spotify;thresholdMB=500

If the request isn't a process-memory-threshold request (it's about something else, or too vague to extract a process name and a number), reply with exactly: RULE: None
"@
    Invoke-OllamaGenerate -Model $Model -Prompt $UserText -SystemPrompt $sys -BaseUrl $BaseUrl -TimeoutSec 30
}

function Get-AiParsedRule {
    param([string]$ResponseText)
    if ($ResponseText -match '(?im)RULE:\s*process=([^;]+);\s*thresholdMB=(\d+)') {
        $proc = $matches[1].Trim() -replace '\.exe$', ''
        $threshold = [int]$matches[2]
        if ($proc -and $threshold -gt 0) {
            return [PSCustomObject]@{ Process = $proc; ThresholdMB = $threshold }
        }
    }
    return $null
}

function Add-CustomRule {
    param([string]$RootDir, [string]$Process, [int]$ThresholdMB)
    $cfg = Get-PCGuardConfig -RootDir $RootDir
    $rules = @($cfg.CustomRules)
    $rules += [PSCustomObject]@{ Id = [guid]::NewGuid().ToString(); Process = $Process; ThresholdMB = $ThresholdMB; Created = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $cfg.CustomRules = $rules
    Save-PCGuardConfig -RootDir $RootDir -Config $cfg
    return $rules
}

function Remove-CustomRule {
    param([string]$RootDir, [string]$Id)
    $cfg = Get-PCGuardConfig -RootDir $RootDir
    $cfg.CustomRules = @($cfg.CustomRules | Where-Object { $_.Id -ne $Id })
    Save-PCGuardConfig -RootDir $RootDir -Config $cfg
    return $cfg.CustomRules
}

function Get-CustomRuleViolations {
    # Checked by the watchdog each run. Returns one alert line per rule
    # currently being exceeded (by any single matching process instance).
    param([object[]]$Rules)
    $violations = @()
    foreach ($rule in $Rules) {
        $procs = @(Get-Process -Name $rule.Process -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            $memMB = [math]::Round($p.WorkingSet / 1MB, 0)
            if ($memMB -gt $rule.ThresholdMB) {
                $violations += "Custom rule: '$($rule.Process)' is using $memMB MB, above your threshold of $($rule.ThresholdMB) MB (PID $($p.Id))."
                break
            }
        }
    }
    return $violations
}

function Invoke-AiExplainAlert {
    param([string]$Model, [string]$AlertText, [string]$BaseUrl = 'http://localhost:11434')
    $context = Get-AiSystemContext
    $prompt = "This alert was logged by Cortexa's background watchdog:`n`n$AlertText`n`nCurrent system snapshot for context:`n$context`n`nIn 2-4 short sentences, explain in plain language why this likely happened and what, specifically, the user should do about it in the Cortexa app."
    $sys = "You are Cortexa, a PC assistant. Be concise and specific. Reference actual Cortexa features (Free Up RAM, Clean Temp Junk, Speed Boost Now, Disk Analysis tab, Startup tab) where relevant, not generic Windows advice."
    Invoke-OllamaGenerate -Model $Model -Prompt $prompt -SystemPrompt $sys -BaseUrl $BaseUrl -TimeoutSec 45
}

function Get-AiSuggestedActions {
    # Parses the "SUGGESTED_ACTIONS: ..." contract line out of an analysis
    # response. Returns the cleaned display text plus the whitelisted action
    # tokens found (unknown tokens are silently dropped - defense in depth
    # against a small model not following the format exactly).
    param([string]$ResponseText)
    $whitelist = @('FreeRam', 'CleanTemp', 'StopUnwanted', 'SpeedBoost', 'ShutdownWsl', 'RestorePoint')
    $actions = @()
    $displayText = $ResponseText

    if ($ResponseText -match '(?im)^SUGGESTED_ACTIONS:\s*(.+)$') {
        $raw = $matches[1]
        $tokens = $raw -split ',' | ForEach-Object { $_.Trim() }
        $actions = @($tokens | Where-Object { $whitelist -contains $_ })
        $displayText = ($ResponseText -replace '(?im)^SUGGESTED_ACTIONS:\s*.+$', '').Trim()
    }

    [PSCustomObject]@{ DisplayText = $displayText; Actions = $actions }
}

function Invoke-AiExplainProcess {
    param([string]$Model, [string]$ProcessName, [string]$ProcessPath, [double]$MemMB, [string]$BaseUrl = 'http://localhost:11434')
    $pathInfo = if ($ProcessPath) { "File location: $ProcessPath" } else { "File location: unknown (may be a protected system process)" }
    $prompt = "Explain what the Windows process '$ProcessName' is, in 2-4 short sentences. $pathInfo. It is currently using $MemMB MB of RAM. Say plainly whether it is generally safe for a user to end this process, or whether it's a system-critical process that should be left alone. If you don't recognize the specific process, say so honestly rather than guessing, and advise checking the file location/publisher instead."
    $sys = "You are Cortexa, a PC assistant. Be concise, factual, and honest about uncertainty. Do not invent information about unfamiliar processes."
    Invoke-OllamaGenerate -Model $Model -Prompt $prompt -SystemPrompt $sys -BaseUrl $BaseUrl -TimeoutSec 45
}

function Invoke-AiAppDecision {
    # A Keep / Consider Uninstalling recommendation for one app row from the
    # App Usage tab. Advisory only, same as everywhere else in Cortexa - this
    # never triggers an uninstall itself; "Open Apps & Features" is still the
    # only actual action path.
    param([string]$Model, [string]$Name, [string]$Publisher, [string]$Status, [string]$Size, [string]$LastSeen, [string]$BaseUrl = 'http://localhost:11434')
    $prompt = "Here is one installed app on this PC:`nName: $Name`nPublisher: $Publisher`nUsage status (as tracked by this app): $Status`nDisk size: $Size`nLast seen used: $LastSeen`n`nGive a short recommendation: Keep, Consider Uninstalling, or Unsure - with 1-2 sentences of reasoning based on the size and how long it's been unused. If you don't recognize this app by name, say so honestly and suggest checking the publisher name or searching for it rather than guessing what it does."
    $sys = "You are Cortexa, a PC assistant helping decide whether an installed app is worth keeping. Be concise and honest about uncertainty. You cannot uninstall anything yourself - only advise; the user acts via Windows' own Apps & Features."
    Invoke-OllamaGenerate -Model $Model -Prompt $prompt -SystemPrompt $sys -BaseUrl $BaseUrl -TimeoutSec 45
}

function Invoke-AiReviewStartupItems {
    param([string]$Model, [object[]]$Items, [string]$BaseUrl = 'http://localhost:11434')
    $list = ($Items | Select-Object -First 30 | ForEach-Object { "- $($_.Name): $($_.Command)" }) -join "`n"
    $prompt = "Here is the list of this Windows PC's startup items (programs that launch at sign-in):`n$list`n`nFor each one, give a very short verdict: either 'Safe to disable if unused' or 'Keep (needed for Windows/hardware/security)' or 'Unsure - research before disabling'. Group your answer by verdict, not by listing each item separately with long explanations. Keep the whole reply under 200 words."
    $sys = "You are Cortexa, a PC assistant reviewing Windows startup programs. Be concise and practical. Do not recommend disabling antivirus, audio drivers, GPU drivers, or other hardware/security-critical software."
    Invoke-OllamaGenerate -Model $Model -Prompt $prompt -SystemPrompt $sys -BaseUrl $BaseUrl -TimeoutSec 60
}

$script:CommandBarTabWhitelist = @('Dashboard', 'Processes', 'Disk Analysis', 'Network', 'Tasks', 'Startup', 'Security', 'App Usage', 'History', 'AI Agent', 'Settings')
$script:CommandBarActionTokens = @('FreeRam', 'CleanTemp', 'StopUnwanted', 'SpeedBoost', 'ShutdownWsl', 'RestorePoint', 'EndProcess', 'OpenTab')

function Invoke-AiParseCommand {
    # Maps a free-text user request to ONE action from a fixed whitelist. This
    # is a routing/classification call, not a free execution call - the GUI
    # re-validates the parsed token (and, for EndProcess, the target process)
    # against the same whitelist again before ever doing anything, and always
    # confirms with the user first.
    param([string]$Model, [string]$UserRequest, [string]$BaseUrl = 'http://localhost:11434')

    $sys = @"
You are a command router for Cortexa, a PC monitoring app. Map the user's request to exactly ONE of these actions and reply with ONLY a single line, nothing else:

ACTION: FreeRam          (trim idle process memory)
ACTION: CleanTemp        (clean Temp/npm-cache junk)
ACTION: StopUnwanted     (stop the user's configured unwanted software)
ACTION: SpeedBoost       (clean temp + free RAM + stop unwanted software + shutdown WSL)
ACTION: ShutdownWsl      (shut down WSL)
ACTION: RestorePoint     (create a Windows System Restore point)
ACTION: EndProcess:<name> (end a specific named process, e.g. ACTION: EndProcess:spotify)
ACTION: OpenTab:<name>   (switch to a tab; <name> must be exactly one of: Dashboard, Processes, Disk Analysis, Network, Tasks, Startup, Security, History, AI Agent, Settings)
ACTION: None             (the request doesn't match any of the above, or is unclear/unsafe)

Rules: output nothing but that one "ACTION: ..." line. Never invent a new action. If genuinely unsure, use None.
"@
    Invoke-OllamaGenerate -Model $Model -Prompt $UserRequest -SystemPrompt $sys -BaseUrl $BaseUrl -TimeoutSec 30
}

function Get-AiParsedCommand {
    # Small local models don't always follow the exact "ACTION: Token" format -
    # testing found ~60% of runs drop the "ACTION:" prefix and just emit the
    # bare token (e.g. "CleanTemp" instead of "ACTION: CleanTemp"). This parses
    # the strict format first, then falls back to finding a known token
    # anywhere in the response, so a model's formatting slip doesn't cause a
    # workable command to silently fail as "None".
    param([string]$ResponseText)
    $text = ($ResponseText | Out-String).Trim()
    if (-not $text) { return [PSCustomObject]@{ Action = 'None'; Arg = $null } }

    if ($text -match '(?im)ACTION:\s*([A-Za-z]+)(?::(.+))?\s*$') {
        $token = $matches[1].Trim()
        $arg = if ($matches[2]) { $matches[2].Trim() } else { $null }
        if ($script:CommandBarActionTokens -contains $token) {
            return [PSCustomObject]@{ Action = $token; Arg = $arg }
        }
    }

    # Fallback: check the last non-empty line first (models sometimes prepend
    # a sentence of reasoning before the token), then the whole response.
    $lastLine = ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    foreach ($candidate in @($lastLine, $text)) {
        if (-not $candidate) { continue }
        if ($candidate -match '(?i)\b(EndProcess|OpenTab)\s*:\s*([^\s,.;]+)') {
            $token = $script:CommandBarActionTokens | Where-Object { $_ -ieq $matches[1] } | Select-Object -First 1
            if ($token) { return [PSCustomObject]@{ Action = $token; Arg = $matches[2].Trim() } }
        }
        foreach ($known in $script:CommandBarActionTokens) {
            if ($candidate -match "(?i)\b$known\b") {
                return [PSCustomObject]@{ Action = $known; Arg = $null }
            }
        }
    }

    return [PSCustomObject]@{ Action = 'None'; Arg = $null }
}

function Invoke-OllamaPullModel {
    param([string]$ModelName, [string]$BaseUrl = 'http://localhost:11434')
    try {
        $body = @{ model = $ModelName; stream = $false } | ConvertTo-Json
        Invoke-RestMethod -Uri "$BaseUrl/api/pull" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1800 -ErrorAction Stop | Out-Null
        [PSCustomObject]@{ Success = $true; Message = "Pulled '$ModelName'." }
    } catch {
        [PSCustomObject]@{ Success = $false; Message = $_.Exception.Message }
    }
}

function Invoke-OllamaDeleteModel {
    param([string]$ModelName, [string]$BaseUrl = 'http://localhost:11434')
    try {
        Invoke-RestMethod -Uri "$BaseUrl/api/delete" -Method Delete -Body (@{ model = $ModelName } | ConvertTo-Json) -ContentType 'application/json' -ErrorAction Stop | Out-Null
        [PSCustomObject]@{ Success = $true; Message = "Deleted '$ModelName'." }
    } catch {
        [PSCustomObject]@{ Success = $false; Message = $_.Exception.Message }
    }
}

function Invoke-AiChat {
    param([string]$Model, [string]$UserMessage, [string]$LogDir = $null, [string]$BaseUrl = 'http://localhost:11434')
    $context = Get-AiSystemContext
    $baseline = if ($LogDir) { Get-AiHistoricalBaseline -LogDir $LogDir } else { $null }
    $systemPrompt = $script:AiSystemPrompt + "`n`nCurrent system snapshot (for your reference, don't repeat it verbatim unless asked):`n$context"
    if ($baseline) { $systemPrompt += "`n`n$baseline" }
    Invoke-OllamaGenerate -Model $Model -Prompt $UserMessage -SystemPrompt $systemPrompt -BaseUrl $BaseUrl -TimeoutSec 60
}

function Invoke-ClaudeGenerate {
    # Calls the Anthropic Messages API directly. Unlike every Ollama-backed
    # function in this module, this sends the prompt (and whatever system
    # data it contains) over the internet to Anthropic - callers must make
    # that tradeoff explicit to the user, this function does not.
    param(
        [string]$ApiKey,
        [string]$Model = 'claude-sonnet-5-5',
        [string]$Prompt,
        [string]$SystemPrompt = '',
        [int]$MaxTokens = 1024
    )
    if (-not $ApiKey) {
        return [PSCustomObject]@{ Success = $false; Response = 'No Anthropic API key configured. Add one in Settings.'; Prompt = $Prompt; SystemPrompt = $SystemPrompt }
    }
    try {
        $body = @{
            model      = $Model
            max_tokens = $MaxTokens
            system     = $SystemPrompt
            messages   = @(@{ role = 'user'; content = $Prompt })
        } | ConvertTo-Json -Depth 6
        $headers = @{
            'x-api-key'         = $ApiKey
            'anthropic-version' = '2023-06-01'
            'content-type'      = 'application/json'
        }
        $result = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -Headers $headers -Body $body -TimeoutSec 60 -ErrorAction Stop
        $text = ($result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
        [PSCustomObject]@{ Success = $true; Response = $text; Prompt = $Prompt; SystemPrompt = $SystemPrompt }
    } catch {
        $msg = $_.Exception.Message
        try {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($errBody.error.message) { $msg = $errBody.error.message }
        } catch {}
        [PSCustomObject]@{ Success = $false; Response = $msg; Prompt = $Prompt; SystemPrompt = $SystemPrompt }
    }
}

function Invoke-ClaudeChat {
    # Follow-up turns for an existing Claude conversation (seeded from a
    # Network Monitor / Storage Manager analysis). Unlike Invoke-ClaudeGenerate
    # (always a single fresh user turn), this sends the full message history
    # so Claude actually remembers what it already said - real multi-turn
    # chat, not independent one-shot calls.
    param(
        [string]$ApiKey,
        [string]$Model = 'claude-sonnet-5-5',
        [array]$Messages,
        [string]$SystemPrompt = '',
        [int]$MaxTokens = 1024
    )
    if (-not $ApiKey) {
        return [PSCustomObject]@{ Success = $false; Response = 'No Anthropic API key configured. Add one in Settings.' }
    }
    try {
        $body = @{
            model      = $Model
            max_tokens = $MaxTokens
            system     = $SystemPrompt
            messages   = $Messages
        } | ConvertTo-Json -Depth 8
        $headers = @{
            'x-api-key'         = $ApiKey
            'anthropic-version' = '2023-06-01'
            'content-type'      = 'application/json'
        }
        $result = Invoke-RestMethod -Uri 'https://api.anthropic.com/v1/messages' -Method Post -Headers $headers -Body $body -TimeoutSec 60 -ErrorAction Stop
        $text = ($result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
        [PSCustomObject]@{ Success = $true; Response = $text }
    } catch {
        $msg = $_.Exception.Message
        try {
            $errBody = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($errBody.error.message) { $msg = $errBody.error.message }
        } catch {}
        [PSCustomObject]@{ Success = $false; Response = $msg }
    }
}

function Invoke-ClaudeNetworkAnalysis {
    # Cortexa's "Network Monitor" agent - reviews live connections/adapters
    # for anything worth a second look. Advisory only: it reports, it never
    # blocks a connection or changes firewall/network settings.
    param([string]$ApiKey, [string]$Model = 'claude-sonnet-5-5')
    $net = Get-NetworkStats
    $conns = @(Get-ActiveConnections -Top 40)
    $adapterLines = ($net.Adapters | ForEach-Object { "$($_.Name): sent $($_.SentMB) MB, received $($_.ReceivedMB) MB" }) -join "`n"
    $connLines = ($conns | ForEach-Object { "$($_.Process) (PID $($_.Pid)): $($_.LocalAddress):$($_.LocalPort) -> $($_.RemoteAddress):$($_.RemotePort) [$($_.State)]" }) -join "`n"
    $prompt = "Network adapters (totals since last reset):`n$adapterLines`n`nActive connections (up to 40):`n$connLines`n`nAnalyze this network snapshot."
    $sys = "You are Cortexa's network monitoring agent. Review the provided snapshot (adapters, active connections) and flag anything unusual or worth the user's attention - e.g. unexpected remote connections, unfamiliar processes talking to the network, high-traffic adapters. Be concise, use a short bullet list. If everything looks ordinary, say so plainly rather than inventing concerns. You cannot block, close, or change any connection or setting - only report findings for the user to act on themselves."
    Invoke-ClaudeGenerate -ApiKey $ApiKey -Model $Model -Prompt $prompt -SystemPrompt $sys -MaxTokens 1024
}

function Invoke-ClaudeStorageAnalysis {
    # Cortexa's "Storage Manager" agent - combines disk free space with the
    # biggest installed apps (and whether they're actually used) into one
    # prioritized cleanup plan. Advisory only: recommends, never deletes or
    # uninstalls anything itself.
    param([string]$ApiKey, [string]$Model = 'claude-sonnet-5-5', [string]$RootDir)
    $health = Get-SystemHealth -TopProcessCount 1
    $diskLines = ($health.Disks | ForEach-Object { "$($_.Drive) $($_.FreePercent)% free ($($_.FreeGB) GB of $($_.SizeGB) GB)" }) -join "`n"
    $bigApps = @(Get-CombinedAppsSummary -RootDir $RootDir -SortBy 'Size' -Top 12)
    $appLines = ($bigApps | ForEach-Object { "$($_.Name): $($_.Size), $($_.Status)" }) -join "`n"
    $prompt = "Disk space:`n$diskLines`n`nBiggest installed apps (with usage status):`n$appLines`n`nGive a short, prioritized storage cleanup plan."
    $sys = "You are Cortexa's storage management agent. Given disk space and the biggest installed apps with whether each is actually used, produce a short, prioritized cleanup plan - what to consider removing first and why, focusing on big-and-unused items over big-and-used ones. Be concise, use a short list. You cannot delete or uninstall anything yourself - only recommend; the user acts via Cortexa's Apps & Features or Disk Analysis tools."
    Invoke-ClaudeGenerate -ApiKey $ApiKey -Model $Model -Prompt $prompt -SystemPrompt $sys -MaxTokens 1024
}

function Get-ListeningServices {
    # Every process with a port in Listen state - the actual security-relevant
    # attack surface (what's reachable, not just what's currently connected).
    # Deliberately samples a large pool from Get-ActiveConnections BEFORE
    # filtering, since that function's own -Top limits the RAW connection
    # list before filtering/sorting - passing a small Top here would silently
    # drop real listening services that weren't in an arbitrary early slice.
    param([int]$Top = 100)
    @(Get-ActiveConnections -Top 500 | Where-Object { $_.State -eq 'Listen' } | Sort-Object Process, LocalPort | Select-Object -First $Top)
}

function Get-SecurityEventLog {
    # Realtime security monitoring data source: events Windows already
    # records as they happen (logons, account/group changes, firewall and
    # Defender changes, new services) - no packet capture or custom driver
    # needed. Each log is queried independently so one log having no
    # matches (e.g. account-management auditing not enabled) doesn't wipe
    # out results from the others - Get-WinEvent throws when a query finds
    # zero matches, so each is its own try/catch.
    param([int]$Hours = 24, [int]$Top = 40)
    $since = (Get-Date).AddHours(-$Hours)
    $events = @()

    try {
        $events += Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625, 4624, 4740, 4720, 4732, 4946, 4950, 4954; StartTime = $since } -MaxEvents 200 -ErrorAction Stop
    } catch {}
    try {
        $events += Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117, 5007; StartTime = $since } -MaxEvents 200 -ErrorAction Stop
    } catch {}
    try {
        $events += Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7045; StartTime = $since } -MaxEvents 200 -ErrorAction Stop
    } catch {}

    @($events | Sort-Object TimeCreated -Descending | Select-Object -First $Top | ForEach-Object {
        $category = switch ($_.Id) {
            4625 { 'Failed logon attempt' }
            4624 { 'Successful logon' }
            4740 { 'Account lockout' }
            4720 { 'User account created' }
            4732 { 'User added to security group' }
            4946 { 'Firewall exception rule added' }
            4950 { 'Firewall setting changed' }
            4954 { 'Firewall policy changed' }
            1116 { 'Defender detected a threat' }
            1117 { 'Defender took action on a threat' }
            5007 { 'Defender configuration changed' }
            7045 { 'New service installed' }
            default { "Event $($_.Id)" }
        }
        [PSCustomObject]@{
            Time     = $_.TimeCreated
            EventId  = $_.Id
            Log      = $_.LogName
            Category = $category
            Message  = (($_.Message -split "`r?`n")[0])
        }
    })
}

function Get-SecurityStatsSnapshot {
    # Rollup counts for the Security tab's stat tiles and trend chart - one
    # snapshot per refresh, which the GUI appends to a rolling in-memory
    # series to build the "realtime" trend without needing its own log file.
    param([int]$Hours = 24)
    $status = Get-SecurityStatus
    $listening = @(Get-ListeningServices -Top 100)
    $events = @(Get-SecurityEventLog -Hours $Hours -Top 200)

    [PSCustomObject]@{
        Timestamp             = Get-Date
        FailedLogons          = @($events | Where-Object { $_.EventId -eq 4625 }).Count
        SuccessfulLogons      = @($events | Where-Object { $_.EventId -eq 4624 }).Count
        DefenderDetections    = @($events | Where-Object { $_.EventId -in 1116, 1117 }).Count
        FirewallChanges       = @($events | Where-Object { $_.EventId -in 4946, 4950, 4954 }).Count
        NewServices           = @($events | Where-Object { $_.EventId -eq 7045 }).Count
        ListeningPorts        = $listening.Count
        FirewallProfilesOn    = @($status.Firewall | Where-Object { $_.Enabled }).Count
        FirewallProfilesTotal = $status.Firewall.Count
        BitLockerProtected    = @($status.BitLocker | Where-Object { $_.ProtectionStatus -eq 'On' }).Count
    }
}

function Invoke-ClaudeSecurityAnalysis {
    # Cortexa's "Security Monitor" agent - reviews firewall, antivirus,
    # encryption, driver-error, and listening-service configuration for
    # weaknesses. Deliberately does NOT claim knowledge of live CVE databases
    # or specific unpatched-software vulnerabilities (that would require a
    # feed this function doesn't have, and a model could easily hallucinate a
    # plausible-looking but wrong CVE number) - it sticks to configuration
    # risks actually visible in the data given. Advisory only: it cannot
    # change any setting itself.
    param([string]$ApiKey, [string]$Model = 'claude-sonnet-5-5')
    $status = Get-SecurityStatus
    $diskHealth = @(Get-DiskHealth)
    $listening = Get-ListeningServices -Top 100
    $events = @(Get-SecurityEventLog -Hours 24 -Top 30)
    $stats = Get-SecurityStatsSnapshot

    $defenderLine = "Windows Defender enabled: $($status.DefenderEnabled); real-time protection: $($status.RealTimeProtection); signature age: $($status.SignaturesAge) day(s)"
    $firewallLine = ($status.Firewall | ForEach-Object { "$($_.Name)=$(if ($_.Enabled) { 'On' } else { 'Off' })" }) -join ', '
    $bitlockerLine = if ($status.BitLocker.Count -gt 0) { ($status.BitLocker | ForEach-Object { "$($_.MountPoint)=$($_.ProtectionStatus)" }) -join ', ' } else { 'Not enabled on any volume' }
    $pnpLine = if ($status.PnpErrors.Count -gt 0) { ($status.PnpErrors | ForEach-Object { $_.FriendlyName }) -join ', ' } else { 'None' }
    $diskHealthLine = ($diskHealth | ForEach-Object { "$($_.FriendlyName): $($_.HealthStatus)" }) -join '; '
    $listenLines = ($listening | ForEach-Object { "$($_.Process) (PID $($_.Pid)) listening on $($_.LocalAddress):$($_.LocalPort)" }) -join "`n"
    $statsLine = "Last 24h: $($stats.FailedLogons) failed logon attempt(s), $($stats.SuccessfulLogons) successful logon(s), $($stats.DefenderDetections) Defender detection(s), $($stats.FirewallChanges) firewall setting change(s), $($stats.NewServices) new service(s) installed."
    $eventLines = if ($events.Count -gt 0) { ($events | ForEach-Object { "[$($_.Time)] $($_.Category): $($_.Message)" }) -join "`n" } else { 'No security events recorded in the last 24h (or account-management/object-access auditing is not enabled on this PC - logon success/failure is still captured where shown above).' }

    $prompt = "Security snapshot:`nFirewall profiles: $firewallLine`n$defenderLine`nBitLocker: $bitlockerLine`nDevices with driver errors: $pnpLine`nDisk health: $diskHealthLine`n`n$statsLine`n`nRecent security events (last 24h, most recent first):`n$eventLines`n`nServices currently listening for network connections:`n$listenLines`n`nReview this for security vulnerabilities, misconfigurations, and any suspicious patterns in the event log (e.g. repeated failed logons could indicate a brute-force attempt)."
    $sys = "You are Cortexa's security monitoring agent. Review firewall, antivirus, encryption, listening-services configuration, and the recent Windows security event log for weaknesses or suspicious activity - e.g. a firewall profile disabled, real-time protection off, stale virus signatures, BitLocker not enabled, a service listening on all interfaces (0.0.0.0 or :::) that should be localhost-only, or a cluster of failed logon attempts that could indicate a brute-force attempt. You do NOT have access to live CVE databases - never invent specific CVE numbers or claim knowledge of unpatched software vulnerabilities; stick to configuration-level risks and event patterns actually visible in the data given. Be concise, use a short bullet list prioritized by severity. If everything looks fine, say so plainly rather than inventing concerns. You cannot change any setting yourself - only report and recommend."
    Invoke-ClaudeGenerate -ApiKey $ApiKey -Model $Model -Prompt $prompt -SystemPrompt $sys -MaxTokens 1024
}

function Write-AiActionLog {
    # Append-only audit trail of every AI-suggested action and what the user
    # decided about it. One JSON object per line (easy to parse, easy to tail).
    param([string]$RootDir, [string]$Source, [string]$Action, [string]$Label, [string]$Decision, [string]$Detail = '')
    $logDir = Join-Path $RootDir 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $logFile = Join-Path $logDir 'ai_actions.log'
    $entry = [PSCustomObject]@{
        Time     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Source   = $Source
        Action   = $Action
        Label    = $Label
        Decision = $Decision
        Detail   = $Detail
    }
    Add-Content -Path $logFile -Value ($entry | ConvertTo-Json -Compress)
}

function Get-AiActionLog {
    param([string]$RootDir, [int]$Top = 50)
    $logFile = Join-Path $RootDir 'logs\ai_actions.log'
    if (-not (Test-Path $logFile)) { return @() }
    $lines = @(Get-Content $logFile -Tail 500 -ErrorAction SilentlyContinue)
    $parsed = @()
    foreach ($line in $lines) {
        try { $parsed += (ConvertFrom-Json $line) } catch {}
    }
    return @($parsed | Select-Object -Last $Top | Sort-Object Time -Descending)
}

$script:AppUsageExcluded = @(
    'System', 'Idle', 'Registry', 'MemCompression', 'smss', 'csrss', 'wininit', 'winlogon', 'services',
    'lsass', 'svchost', 'dwm', 'fontdrvhost', 'WmiPrvSE', 'RuntimeBroker', 'SearchIndexer', 'SearchHost',
    'conhost', 'dllhost', 'backgroundTaskHost', 'ShellExperienceHost', 'StartMenuExperienceHost',
    'TextInputHost', 'ApplicationFrameHost', 'SecurityHealthService', 'SecurityHealthSystray',
    'sihost', 'ctfmon', 'explorer', 'powershell', 'pwsh', 'PCGuard-GUI', 'Cortexa', 'PCGuard'
)

function Get-AppUsageStorePath {
    param([string]$RootDir)
    Join-Path $RootDir 'logs\app_usage.json'
}

function Get-AppUsageStore {
    param([string]$RootDir)
    $path = Get-AppUsageStorePath -RootDir $RootDir
    if (-not (Test-Path $path)) { return @{} }
    try {
        $raw = Get-Content $path -Raw | ConvertFrom-Json
        $store = @{}
        foreach ($prop in $raw.PSObject.Properties) { $store[$prop.Name] = $prop.Value }
        return $store
    } catch {
        return @{}
    }
}

function Save-AppUsageStore {
    param([string]$RootDir, [hashtable]$Store)
    $logDir = Join-Path $RootDir 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $Store | ConvertTo-Json -Depth 5 | Set-Content -Path (Get-AppUsageStorePath -RootDir $RootDir) -Encoding UTF8
}

function Add-AppUsageSample {
    # Called periodically (every ~15s while the GUI is open, every 15 min from
    # the watchdog) - adds $MinutesElapsed to every currently-running,
    # non-system process's accumulated time. This is sampling, not precise
    # instrumentation: a process "counts" for the whole interval if it was
    # running at the moment of the sample, which is a reasonable approximation
    # at these intervals, not a claim of second-accurate tracking.
    param([string]$RootDir, [double]$MinutesElapsed)

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $store = Get-AppUsageStore -RootDir $RootDir

    $seenNames = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        # Only count processes with an actual visible window at sample time -
        # this is what separates "an app the user is using" from the dozens
        # of background services/drivers that are always running.
        if ($p.MainWindowHandle -eq [IntPtr]::Zero) { continue }
        if (-not $p.MainWindowTitle) { continue }
        if ($script:AppUsageExcluded -contains $p.ProcessName) { continue }
        $key = $p.ProcessName.ToLower()
        if ($seenNames.ContainsKey($key)) { continue }
        $seenNames[$key] = $true

        if (-not $store.ContainsKey($key)) {
            $store[$key] = @{
                FriendlyName = $p.ProcessName
                TotalMinutes = 0.0
                TodayMinutes = 0.0
                TodayDate    = $today
                FirstSeen    = $now
                LastSeen     = $now
                ExePath      = $null
            }
        }
        $entry = $store[$key]
        if ($entry.TodayDate -ne $today) {
            $entry.TodayDate = $today
            $entry.TodayMinutes = 0.0
        }
        $entry.TotalMinutes = [double]$entry.TotalMinutes + $MinutesElapsed
        $entry.TodayMinutes = [double]$entry.TodayMinutes + $MinutesElapsed
        $entry.LastSeen = $now
        if (-not $entry.ExePath) {
            try { if ($p.Path) { $entry.ExePath = $p.Path } } catch {}
        }
        $store[$key] = $entry
    }

    Save-AppUsageStore -RootDir $RootDir -Store $store
}

function Format-AppUsageMinutes {
    param([double]$Minutes)
    $h = [math]::Floor($Minutes / 60)
    $m = [math]::Round($Minutes % 60)
    if ($h -gt 0) { "{0}h {1}m" -f $h, $m } else { "{0}m" -f $m }
}

function Get-AppUsageSummary {
    param([string]$RootDir, [string]$SortBy = 'Today', [int]$Top = 30)
    $store = Get-AppUsageStore -RootDir $RootDir
    $today = (Get-Date).ToString('yyyy-MM-dd')

    $rows = foreach ($key in $store.Keys) {
        $e = $store[$key]
        $todayMinutes = if ($e.TodayDate -eq $today) { [double]$e.TodayMinutes } else { 0.0 }
        [PSCustomObject]@{
            Key           = $key
            App           = $e.FriendlyName
            TodayMinutes  = $todayMinutes
            Today         = Format-AppUsageMinutes -Minutes $todayMinutes
            TotalMinutes  = [double]$e.TotalMinutes
            Total         = Format-AppUsageMinutes -Minutes ([double]$e.TotalMinutes)
            LastSeen      = $e.LastSeen
            ExePath       = $e.ExePath
            Size          = 'Not calculated'
            SizeMB        = -1
        }
    }

    $sorted = if ($SortBy -eq 'Total') {
        $rows | Sort-Object TotalMinutes -Descending
    } else {
        $rows | Sort-Object TodayMinutes -Descending
    }
    return @($sorted | Select-Object -First $Top)
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    $bytes = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $bytes) { return 0 }
    [math]::Round($bytes / 1MB, 1)
}

function Get-AppSizeOnDisk {
    # "App size" = the size of the folder containing the app's main
    # executable, computed fresh each time (not cached/static) since installs
    # grow/shrink (updates, caches, etc). Approximate by design: the true
    # "install root" isn't reliably knowable for every app, so this reports
    # the exe's own containing folder, recursively.
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path $ExePath)) { return $null }
    $folder = Split-Path -Parent $ExePath
    Get-FolderSizeMB -Path $folder
}

function Get-InstalledPrograms {
    # Standard Windows "Add/Remove Programs" inventory, read directly from the
    # registry (the same source Settings > Apps uses). Filters out OS
    # components and update/patch sub-entries, dedupes by name.
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $seen = @{}
    $results = foreach ($regPath in $regPaths) {
        Get-ItemProperty $regPath -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $_.DisplayName) { return }
            if ($_.SystemComponent -eq 1) { return }
            if ($_.ParentKeyName) { return }
            $key = $_.DisplayName.Trim().ToLower()
            if ($seen.ContainsKey($key)) { return }
            $seen[$key] = $true
            [PSCustomObject]@{
                Name            = $_.DisplayName
                Publisher       = $_.Publisher
                InstallLocation = $_.InstallLocation
                EstimatedSizeMB = if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1024, 1) } else { $null }
                InstallDate     = $_.InstallDate
            }
        }
    }
    return @($results | Sort-Object Name)
}

function Convert-Rot13String {
    param([string]$Text)
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        if ($c -ge 'a' -and $c -le 'z') { $chars[$i] = [char]((([int]$c - [int][char]'a' + 13) % 26) + [int][char]'a') }
        elseif ($c -ge 'A' -and $c -le 'Z') { $chars[$i] = [char]((([int]$c - [int][char]'A' + 13) % 26) + [int][char]'A') }
    }
    -join $chars
}

function Get-UserAssistLastRunData {
    # Windows records a last-run timestamp for GUI-launched apps in the
    # UserAssist registry key, independent of whether Cortexa was running at
    # the time - this is how "Last Seen" can be populated even for apps
    # Cortexa has never observed. Names are ROT13-encoded; the last-run
    # FILETIME lives at a fixed offset in the binary value (a long-documented,
    # if undocumented-by-Microsoft, reverse-engineered format: Session
    # Prefetch tools, forensics literature). Returns two lookups keyed by
    # lowercase exe filename and lowercase "friendly" shortcut/app name,
    # since UserAssist entries come in both forms.
    $byExe = @{}
    $byFriendly = @{}
    $guidKeys = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist" -ErrorAction SilentlyContinue
    foreach ($g in $guidKeys) {
        $item = Get-Item (Join-Path $g.PSPath 'Count') -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($encName in $item.GetValueNames()) {
            if ($encName -like 'UEME_CTL*') { continue }
            $bytes = $item.GetValue($encName)
            if (-not $bytes -or $bytes.Length -lt 68) { continue }
            try {
                $fileTimeLong = [BitConverter]::ToInt64($bytes, 60)
                if ($fileTimeLong -le 0) { continue }
                $lastRun = [DateTime]::FromFileTime($fileTimeLong)
                if ($lastRun.Year -lt 2000 -or $lastRun -gt (Get-Date).AddDays(1)) { continue }
            } catch { continue }

            $decName = Convert-Rot13String -Text $encName
            if ($decName -match '([^\\]+)\.exe$') {
                $exeKey = $matches[1].ToLower() + '.exe'
                if (-not $byExe.ContainsKey($exeKey) -or $lastRun -gt $byExe[$exeKey]) { $byExe[$exeKey] = $lastRun }
            } elseif ($decName -match '([^\\]+)\.lnk$') {
                $friendlyKey = $matches[1].ToLower()
                if (-not $byFriendly.ContainsKey($friendlyKey) -or $lastRun -gt $byFriendly[$friendlyKey]) { $byFriendly[$friendlyKey] = $lastRun }
            } elseif ($decName -match '^([A-Za-z0-9.]+)!') {
                $friendlyKey = ($matches[1] -replace '^Microsoft\.', '').ToLower()
                if (-not $byFriendly.ContainsKey($friendlyKey) -or $lastRun -gt $byFriendly[$friendlyKey]) { $byFriendly[$friendlyKey] = $lastRun }
            }
        }
    }
    [PSCustomObject]@{ ByExe = $byExe; ByFriendly = $byFriendly }
}

function Get-UnusedAppsSummary {
    # The complement of Get-AppUsageSummary: installed programs (from the
    # registry) cross-referenced against what Cortexa has actually tracked
    # running, matched by INSTALL FOLDER PATH rather than fuzzy name matching
    # (process name "chrome" vs. display name "Google Chrome" can't be
    # reliably string-matched; comparing the tracked exe's folder against
    # each program's InstallLocation is far more reliable). Apps with no
    # path match are labeled "not seen running" - an honest statement about
    # what Cortexa has observed since you started monitoring, not a claim
    # about your lifetime usage of that app.
    param([string]$RootDir, [int]$Top = 40)
    $installed = @(Get-InstalledPrograms | Where-Object { $_.InstallLocation })
    $store = Get-AppUsageStore -RootDir $RootDir

    $rows = foreach ($app in $installed) {
        $normInstall = $app.InstallLocation.TrimEnd('\').ToLower()
        $match = $null
        foreach ($key in $store.Keys) {
            $e = $store[$key]
            if (-not $e.ExePath) { continue }
            $exeFolder = (Split-Path -Parent $e.ExePath).ToLower()
            if ($exeFolder -eq $normInstall -or $exeFolder.StartsWith("$normInstall\") -or $normInstall.StartsWith("$exeFolder\")) {
                $match = $e
                break
            }
        }
        $totalMinutes = if ($match) { [double]$match.TotalMinutes } else { 0.0 }
        [PSCustomObject]@{
            Name                 = $app.Name
            Publisher            = $app.Publisher
            InstallLocation      = $app.InstallLocation
            Status               = if ($match) { "Used: $(Format-AppUsageMinutes -Minutes $totalMinutes) total (tracked)" } else { "Not seen running since tracking started" }
            TotalMinutesTracked  = $totalMinutes
            LastSeen             = if ($match) { $match.LastSeen } else { 'Never (tracked)' }
            Size                 = if ($app.EstimatedSizeMB) { "{0:N0} MB (registry est.)" -f $app.EstimatedSizeMB } else { 'Not calculated' }
            SizeMB               = if ($app.EstimatedSizeMB) { $app.EstimatedSizeMB } else { -1 }
        }
    }

    return @($rows | Sort-Object -Property @{Expression = 'TotalMinutesTracked'; Descending = $false }, @{Expression = 'SizeMB'; Descending = $true } | Select-Object -First $Top)
}

function Get-CombinedAppsSummary {
    # The single, merged App Usage view: every installed program (from the
    # registry) PLUS every tracked-but-not-separately-installed process (e.g.
    # system utilities, store apps) that doesn't match an installed program,
    # in one list. Each row carries both usage (if any) and size, so it can
    # be sorted by either - this is the one table the GUI's App Usage tab
    # renders; Get-AppUsageSummary and Get-UnusedAppsSummary above remain as
    # their own narrower, independently useful building blocks.
    param([string]$RootDir, [string]$SortBy = 'Size', [int]$Top = 60)

    $installed = @(Get-InstalledPrograms | Where-Object { $_.InstallLocation })
    $store = Get-AppUsageStore -RootDir $RootDir
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $matchedKeys = @{}
    $userAssist = Get-UserAssistLastRunData

    $installedRows = foreach ($app in $installed) {
        $normInstall = $app.InstallLocation.TrimEnd('\').ToLower()
        $match = $null
        $matchKey = $null
        foreach ($key in $store.Keys) {
            $e = $store[$key]
            if (-not $e.ExePath) { continue }
            $exeFolder = (Split-Path -Parent $e.ExePath).ToLower()
            if ($exeFolder -eq $normInstall -or $exeFolder.StartsWith("$normInstall\") -or $normInstall.StartsWith("$exeFolder\")) {
                $match = $e
                $matchKey = $key
                break
            }
        }
        if ($matchKey) { $matchedKeys[$matchKey] = $true }
        $totalM = if ($match) { [double]$match.TotalMinutes } else { 0.0 }
        $todayM = if ($match -and $match.TodayDate -eq $today) { [double]$match.TodayMinutes } else { 0.0 }

        $lastSeen = $null
        $status = $null
        if ($match) {
            $lastSeen = $match.LastSeen
            $status = "Used - $(Format-AppUsageMinutes -Minutes $totalM) total"
        } else {
            # No precise tracking data - fall back to Windows' own UserAssist
            # record (real last-run date, independent of Cortexa ever running)
            # before giving up and calling it unseen.
            $uaDate = $null
            $candidateExes = @()
            if (Test-Path -LiteralPath $app.InstallLocation -PathType Container -ErrorAction SilentlyContinue) {
                try {
                    $candidateExes = @(Get-ChildItem -LiteralPath $app.InstallLocation -Filter '*.exe' -File -ErrorAction Stop | Select-Object -ExpandProperty Name)
                } catch {
                    $candidateExes = @()
                }
            }
            foreach ($exe in $candidateExes) {
                $key = $exe.ToLower()
                if ($userAssist.ByExe.ContainsKey($key)) {
                    if (-not $uaDate -or $userAssist.ByExe[$key] -gt $uaDate) { $uaDate = $userAssist.ByExe[$key] }
                }
            }
            if (-not $uaDate) {
                $nameLower = $app.Name.ToLower()
                foreach ($friendlyKey in $userAssist.ByFriendly.Keys) {
                    if ($nameLower.Contains($friendlyKey) -or $friendlyKey.Contains($nameLower)) {
                        if (-not $uaDate -or $userAssist.ByFriendly[$friendlyKey] -gt $uaDate) { $uaDate = $userAssist.ByFriendly[$friendlyKey] }
                    }
                }
            }
            $status = "Not used (installed)"
            $lastSeen = if ($uaDate) { "$($uaDate.ToString('yyyy-MM-dd HH:mm')) (Windows usage record)" } else { 'No usage record found' }
        }

        [PSCustomObject]@{
            Name         = $app.Name
            Publisher    = $app.Publisher
            Status       = $status
            TotalMinutes = $totalM
            TodayMinutes = $todayM
            LastSeen     = $lastSeen
            SizePath     = $app.InstallLocation
            SizeMB       = if ($app.EstimatedSizeMB) { $app.EstimatedSizeMB } else { -1 }
            Size         = if ($app.EstimatedSizeMB) { "{0:N0} MB (est.)" -f $app.EstimatedSizeMB } else { 'Not calculated' }
        }
    }

    $trackedOnlyRows = foreach ($key in $store.Keys) {
        if ($matchedKeys.ContainsKey($key)) { continue }
        $e = $store[$key]
        $totalM = [double]$e.TotalMinutes
        $todayM = if ($e.TodayDate -eq $today) { [double]$e.TodayMinutes } else { 0.0 }
        [PSCustomObject]@{
            Name         = $e.FriendlyName
            Publisher    = $null
            Status       = "Used - $(Format-AppUsageMinutes -Minutes $totalM) total"
            TotalMinutes = $totalM
            TodayMinutes = $todayM
            LastSeen     = $e.LastSeen
            SizePath     = if ($e.ExePath) { Split-Path -Parent $e.ExePath } else { $null }
            SizeMB       = -1
            Size         = 'Not calculated'
        }
    }

    $all = @($installedRows) + @($trackedOnlyRows)
    $sorted = switch ($SortBy) {
        'Today' { $all | Sort-Object TodayMinutes -Descending }
        'Total' { $all | Sort-Object TotalMinutes -Descending }
        default { $all | Sort-Object SizeMB -Descending }
    }
    return @($sorted | Select-Object -First $Top)
}

function Reset-AppUsageStats {
    param([string]$RootDir)
    $path = Get-AppUsageStorePath -RootDir $RootDir
    if (Test-Path $path) { Remove-Item $path -Force }
}

Export-ModuleMember -Function Get-SystemHealth, Invoke-SafeCleanup, Test-WatchdogInstalled, Install-Watchdog, Uninstall-Watchdog, Get-RecentAlerts, Get-HealthHistory, Get-TopFolders, Get-WslDockerInfo, Invoke-WslShutdown, Get-PCGuardConfig, Save-PCGuardConfig, Export-HealthReport, Get-NetworkStats, Get-ActiveConnections, Get-NetworkHistory, Get-SystemInfo, Get-DiskIoStats, Get-RecentSystemEvents, Get-ScheduledTasksList, Set-ScheduledTaskState, Get-ProcessesDetailed, Stop-ProcessTree, Set-ProcessPriority, Get-ProcessFilePath, Invoke-FreeUpRam, Invoke-StopUnwantedProcesses, Invoke-CreateRestorePoint, Get-StartupItemsDetailed, Disable-StartupItem, Enable-StartupItem, Get-SecurityStatus, Get-DiskHealth, Get-BatteryHealthReport, Get-LargestFiles, Export-PCGuardSettings, Import-PCGuardSettings, Send-WebhookAlert, Test-OllamaAvailable, Start-OllamaServer, Invoke-OllamaGenerate, Get-AiSystemContext, Invoke-AiSystemAnalysis, Invoke-AiChat, Get-AiSuggestedActions, Invoke-AiExplainProcess, Invoke-AiReviewStartupItems, Invoke-AiParseCommand, Get-AiParsedCommand, Invoke-OllamaPullModel, Invoke-OllamaDeleteModel, Write-AiActionLog, Get-AiActionLog, Get-AiHistoricalBaseline, Invoke-AiExplainAlert, Invoke-AiParseRule, Get-AiParsedRule, Add-CustomRule, Remove-CustomRule, Get-CustomRuleViolations, Get-AutoApproveEligibleActions, Add-AppUsageSample, Get-AppUsageSummary, Get-AppSizeOnDisk, Reset-AppUsageStats, Get-FolderSizeMB, Get-InstalledPrograms, Get-UnusedAppsSummary, Get-CombinedAppsSummary, Get-UserAssistLastRunData, Invoke-AiAppDecision, Invoke-ClaudeGenerate, Invoke-ClaudeNetworkAnalysis, Invoke-ClaudeStorageAnalysis, Invoke-ClaudeChat, Invoke-ClaudeSecurityAnalysis, Get-ListeningServices, Get-SecurityEventLog, Get-SecurityStatsSnapshot
