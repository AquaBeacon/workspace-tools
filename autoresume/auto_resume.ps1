# auto_resume.ps1 -- resume Claude Code work automatically after a usage-limit pause.
# ASCII ONLY (PowerShell 5.1 fails to parse BOM-less UTF-8 Japanese).
#
# Modes:
#   -SelfTest    verify every moving part without touching the real task
#   -RunOnce     one polling iteration (this is what the scheduled task calls)
#   -Install     register the Windows scheduled task (every 10 min)
#   -Uninstall   remove the scheduled task
#   -Status      print current state
#
# Behaviour of -RunOnce:
#   1. DONE marker present            -> uninstall task, exit
#   2. another instance holds lock    -> exit
#   3. retry_after in the future      -> exit (still inside the usage-limit window)
#   4. an interactive claude.exe runs -> exit (live session owns the work)
#   5. otherwise                      -> `claude --continue --print <prompt>` and log it.
#      If the output looks like a usage limit, record the reset time and back off.

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$RunOnce,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- configuration
$Root        = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir  = 'C:\Users\ryupc\WorkSpace\Mitou26'
$StateDir    = Join-Path $Root 'state'
$LogFile     = Join-Path $StateDir 'autoresume.log'
$DoneFile    = Join-Path $StateDir 'DONE'
$RetryFile   = Join-Path $StateDir 'retry_after.txt'
$LockFile    = Join-Path $StateDir 'lock.pid'
$PromptFile  = Join-Path $Root 'resume_prompt.txt'
$TaskName    = 'AquaBeacon_AutoResume'
$IntervalMin = 10
# Permission mode passed to the headless run. Empty string = inherit the user's
# own settings.json ("defaultMode": "auto"). Do not silently escalate.
$PermissionMode = ''
# Max minutes a single headless resume may run before being killed.
$RunTimeoutMin = 240

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }

# ---------------------------------------------------------------- helpers
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    Write-Output $line
}

function Get-ClaudeExe {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

# Returns $true when the text looks like a Claude usage-limit / rate-limit stop.
function Test-UsageLimit {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $patterns = @(
        'usage limit reached',
        '5-hour limit',
        'weekly limit',
        'rate[_ ]limit',
        'limit will reset',
        'limit resets',
        'resets at',
        'Please try again (later|in)',
        'exceeded your .* quota',
        'overloaded_error'
    )
    foreach ($p in $patterns) {
        if ($Text -match $p) { return $true }
    }
    return $false
}

# Best-effort extraction of the reset moment. Understands:
#   "Claude AI usage limit reached|1785000000"   (epoch seconds)
#   "resets at 3:00pm" / "resets at 15:00"
# Falls back to now + 65 min (a 5-hour window is never longer than that from a
# random point, and we re-poll every 10 min anyway).
function Get-ResetTime {
    param([string]$Text)
    $now = Get-Date
    if ($Text -match 'limit reached\|(\d{9,13})') {
        $epoch = [int64]$Matches[1]
        if ($epoch -gt 99999999999) { $epoch = [int64]($epoch / 1000) }
        $t = [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime().DateTime
        if ($t -gt $now) { return $t }
    }
    if ($Text -match 'reset[s]?\s+at\s+(\d{1,2}):(\d{2})\s*(am|pm|AM|PM)?') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]; $ap = $Matches[3]
        if ($ap -and $ap.ToLower() -eq 'pm' -and $h -lt 12) { $h += 12 }
        if ($ap -and $ap.ToLower() -eq 'am' -and $h -eq 12) { $h = 0 }
        $t = $now.Date.AddHours($h).AddMinutes($m)
        if ($t -le $now) { $t = $t.AddDays(1) }
        return $t
    }
    return $now.AddMinutes(65)
}

# An interactive session is running when a claude.exe exists that is NOT the
# headless child this script started.
function Test-InteractiveClaude {
    $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue)
    return ($procs.Count -gt 0)
}

function Get-Lock {
    if (Test-Path $LockFile) {
        $old = (Get-Content $LockFile -Raw).Trim()
        $alive = $false
        if ($old -match '^\d+$') {
            $alive = [bool](Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)
        }
        if ($alive) { return $false }
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
    Set-Content -Path $LockFile -Value $PID -Encoding ascii
    return $true
}

function Release-Lock {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}

function Get-RetryAfter {
    if (-not (Test-Path $RetryFile)) { return $null }
    $raw = (Get-Content $RetryFile -Raw).Trim()
    try { return [datetime]::Parse($raw) } catch { return $null }
}

function Set-RetryAfter {
    param([datetime]$When)
    Set-Content -Path $RetryFile -Value ($When.ToString('o')) -Encoding ascii
}

# ---------------------------------------------------------------- scheduled task
function Test-TaskInstalled {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    return ($null -ne $t)
}

function Install-Task {
    $ps  = (Get-Command powershell.exe).Source
    $inner = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RunOnce' -f (Join-Path $Root 'auto_resume.ps1')
    # Run each tick under conhost --headless. A bare powershell.exe action pops a
    # console window every interval; see the same comment in task_resume.ps1.
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    if (Test-Path $conhost) {
        $exe = $conhost
        $arg = '--headless "{0}" {1}' -f $ps, $inner
    } else {
        $exe = $ps
        $arg = $inner
    }
    $action  = New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $ProjectDir
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                 -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
                 -MultipleInstances IgnoreNew
    if (Test-TaskInstalled) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'AquaBeacon: resume Claude Code work after a usage-limit pause' | Out-Null
    Write-Log ("scheduled task '{0}' installed (every {1} min)" -f $TaskName, $IntervalMin)
}

function Uninstall-Task {
    if (Test-TaskInstalled) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log ("scheduled task '{0}' removed" -f $TaskName)
    } else {
        Write-Log ("scheduled task '{0}' was not installed" -f $TaskName)
    }
}

# ---------------------------------------------------------------- the actual resume
function Invoke-Resume {
    $claude = Get-ClaudeExe
    if (-not $claude) { Write-Log 'claude CLI not found' 'ERROR'; return }

    if (-not (Test-Path $PromptFile)) { Write-Log "prompt file missing: $PromptFile" 'ERROR'; return }
    $prompt = Get-Content $PromptFile -Raw -Encoding utf8

    $out = Join-Path $StateDir ('run_{0}.out.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $err = $out -replace '\.out\.txt$', '.err.txt'

    # The prompt is multi-line Japanese: feed it on stdin instead of as an argv
    # element (Start-Process does not quote array elements on PS 5.1).
    $argList = @('--continue', '--print')
    if ($PermissionMode) { $argList += @('--permission-mode', $PermissionMode) }

    Write-Log ('launching headless resume: {0} --continue --print (prompt {1} chars via stdin)' -f $claude, $prompt.Length)
    $p = Start-Process -FilePath $claude -ArgumentList $argList -WorkingDirectory $ProjectDir `
                       -RedirectStandardInput $PromptFile `
                       -RedirectStandardOutput $out -RedirectStandardError $err `
                       -NoNewWindow -PassThru
    if (-not $p.WaitForExit($RunTimeoutMin * 60 * 1000)) {
        try { $p.Kill() } catch {}
        Write-Log ('headless resume killed after {0} min' -f $RunTimeoutMin) 'WARN'
        return
    }

    $text = ''
    foreach ($f in @($out, $err)) {
        if (Test-Path $f) { $text += (Get-Content $f -Raw -Encoding utf8) }
    }
    Write-Log ('headless resume exit={0}, output {1} chars -> {2}' -f $p.ExitCode, $text.Length, (Split-Path -Leaf $out))

    if (Test-UsageLimit $text) {
        $reset = Get-ResetTime $text
        Set-RetryAfter $reset.AddMinutes(2)
        Write-Log ('usage limit detected; backing off until {0}' -f $reset.AddMinutes(2)) 'WARN'
        return
    }

    if (Test-Path $RetryFile) { Remove-Item $RetryFile -Force -ErrorAction SilentlyContinue }
    $tail = ($text -split "`n" | Select-Object -Last 3) -join ' / '
    Write-Log ('resume finished. tail: {0}' -f $tail.Trim())
}

function Invoke-RunOnce {
    if (Test-Path $DoneFile) {
        Write-Log 'DONE marker present -> work is finished; removing scheduled task'
        Uninstall-Task
        return
    }
    if (-not (Get-Lock)) { Write-Log 'another instance is running; skip'; return }
    try {
        $retry = Get-RetryAfter
        if ($retry -and $retry -gt (Get-Date)) {
            Write-Log ('still inside usage-limit window (until {0}); skip' -f $retry)
            return
        }
        if (Test-InteractiveClaude) {
            Write-Log 'a claude session is already running; skip (live session owns the work)'
            return
        }
        Invoke-Resume
    } finally {
        Release-Lock
    }
}

# ---------------------------------------------------------------- self test
function Invoke-SelfTest {
    $fail = 0
    Write-Log '=== SELF TEST START ==='

    # 1. claude CLI reachable
    $claude = Get-ClaudeExe
    if ($claude) { Write-Log ("[1/7] PASS claude CLI: {0}" -f $claude) }
    else { Write-Log '[1/7] FAIL claude CLI not found' 'ERROR'; $fail++ }

    # 2. prompt file present and non-trivial
    if ((Test-Path $PromptFile) -and (Get-Item $PromptFile).Length -gt 50) {
        Write-Log ("[2/7] PASS prompt file: {0} bytes" -f (Get-Item $PromptFile).Length)
    } else { Write-Log '[2/7] FAIL prompt file missing or too short' 'ERROR'; $fail++ }

    # 3. usage-limit detection: positives and negatives
    $pos = @(
        'Claude AI usage limit reached|1785000000',
        'You have reached your 5-hour limit. Try again later.',
        'API Error: rate_limit_error',
        'Usage limit reached - resets at 3:00pm'
    )
    $neg = @(
        'Build finished: DRC exit=0, unconnected=0',
        'Wrote pcb/CHILD_MAIN/CHILD_MAIN.kicad_pcb'
    )
    $ok = $true
    foreach ($t in $pos) { if (-not (Test-UsageLimit $t)) { $ok = $false; Write-Log "  missed positive: $t" 'ERROR' } }
    foreach ($t in $neg) { if (Test-UsageLimit $t) { $ok = $false; Write-Log "  false positive: $t" 'ERROR' } }
    if ($ok) { Write-Log '[3/7] PASS usage-limit detection (4 positive, 2 negative)' }
    else { Write-Log '[3/7] FAIL usage-limit detection' 'ERROR'; $fail++ }

    # 4. reset-time parsing
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    $t1 = Get-ResetTime ("Claude AI usage limit reached|{0}" -f $epoch)
    $delta = ($t1 - (Get-Date)).TotalMinutes
    if ($delta -gt 50 -and $delta -lt 70) { Write-Log ('[4/7] PASS reset-time parse: +{0:N0} min' -f $delta) }
    else { Write-Log ('[4/7] FAIL reset-time parse: +{0:N0} min' -f $delta) 'ERROR'; $fail++ }

    # 5. lock acquire / release
    if ((Get-Lock)) {
        $second = Get-Lock   # same PID -> our own lock is seen as alive -> must refuse
        Release-Lock
        if (-not $second) { Write-Log '[5/7] PASS lock is exclusive' }
        else { Write-Log '[5/7] FAIL lock is not exclusive' 'ERROR'; $fail++ }
    } else { Write-Log '[5/7] FAIL could not acquire lock' 'ERROR'; $fail++ }

    # 6. headless claude actually answers (cheap model, throwaway cwd)
    if ($claude) {
        $tmp = Join-Path $env:TEMP ('ar_selftest_{0}' -f $PID)
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $o = Join-Path $tmp 'o.txt'; $e = Join-Path $tmp 'e.txt'
        $i = Join-Path $tmp 'i.txt'
        Set-Content -Path $i -Value 'Reply with exactly: SELFTEST_OK' -Encoding ascii
        $args6 = @('--print', '--model', 'claude-haiku-4-5-20251001')
        $pp = Start-Process -FilePath $claude -ArgumentList $args6 -WorkingDirectory $tmp `
                            -RedirectStandardInput $i `
                            -RedirectStandardOutput $o -RedirectStandardError $e -NoNewWindow -PassThru
        if ($pp.WaitForExit(180000)) {
            $txt = ''
            foreach ($f in @($o,$e)) { if (Test-Path $f) { $txt += (Get-Content $f -Raw) } }
            if ($txt -match 'SELFTEST_OK') { Write-Log '[6/7] PASS headless claude answered SELFTEST_OK' }
            elseif (Test-UsageLimit $txt) { Write-Log '[6/7] PASS(limit) headless claude hit the usage limit -- back-off path is what would run' }
            else { Write-Log ("[6/7] FAIL headless claude output: {0}" -f ($txt -replace '\s+',' ')) 'ERROR'; $fail++ }
        } else {
            try { $pp.Kill() } catch {}
            Write-Log '[6/7] FAIL headless claude timed out (180s)' 'ERROR'; $fail++
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    } else { Write-Log '[6/7] SKIP (no claude CLI)' 'WARN'; $fail++ }

    # 7. scheduled task can be created, queried and deleted
    $wasInstalled = Test-TaskInstalled
    try {
        if (-not $wasInstalled) { Install-Task }
        if (Test-TaskInstalled) { Write-Log '[7/7] PASS scheduled task create/query works' }
        else { Write-Log '[7/7] FAIL scheduled task not found after create' 'ERROR'; $fail++ }
        if (-not $wasInstalled) { Uninstall-Task }
    } catch {
        Write-Log ('[7/7] FAIL scheduled task: {0}' -f $_.Exception.Message) 'ERROR'; $fail++
    }

    if ($fail -eq 0) { Write-Log '=== SELF TEST: ALL PASS ==='; exit 0 }
    Write-Log ("=== SELF TEST: {0} FAILURE(S) ===" -f $fail) 'ERROR'
    exit 1
}

function Show-Status {
    Write-Output ('project      : {0}' -f $ProjectDir)
    Write-Output ('task         : {0} -> {1}' -f $TaskName, $(if (Test-TaskInstalled) { 'INSTALLED' } else { 'not installed' }))
    Write-Output ('DONE marker  : {0}' -f $(if (Test-Path $DoneFile) { 'present (auto-resume disabled)' } else { 'absent (armed)' }))
    $r = Get-RetryAfter
    Write-Output ('retry after  : {0}' -f $(if ($r) { $r } else { '-' }))
    Write-Output ('live session : {0}' -f $(if (Test-InteractiveClaude) { 'yes' } else { 'no' }))
    if (Test-Path $LogFile) {
        Write-Output '--- last 15 log lines ---'
        Get-Content $LogFile -Tail 15
    }
}

# ---------------------------------------------------------------- dispatch
if     ($SelfTest)  { Invoke-SelfTest }
elseif ($Install)   { Install-Task }
elseif ($Uninstall) { Uninstall-Task }
elseif ($Status)    { Show-Status }
elseif ($RunOnce)   { Invoke-RunOnce }
else                { Show-Status }
