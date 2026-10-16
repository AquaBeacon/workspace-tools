# task_resume.ps1 -- multi-tenant auto-resume for Claude Code work in this repo.
# ASCII ONLY (PowerShell 5.1 fails to parse BOM-less UTF-8 Japanese).
#
# Why this exists next to auto_resume.ps1:
#   auto_resume.ps1 is single-tenant. It owns one prompt file, one DONE marker and
#   one scheduled task, and it resumes with `claude --continue`, which picks the
#   MOST RECENT conversation in the project directory. With two agents working in
#   the same repo that is a coin flip: task A's timer can resume task B's session.
#   It also skips whenever ANY claude.exe exists -- but an interactive session that
#   hit the 5-hour limit is still running, so that guard blocks the very case it is
#   supposed to cover.
#
# This script fixes both:
#   * every task gets its own directory, prompt, log, DONE marker and Windows task
#   * a task is pinned to a session id and resumed with `--resume <id> --fork-session`
#   * "is a live session working on this?" is decided by the mtime of that session's
#     transcript, not by the existence of a claude.exe process
#   * before spending the real session it sends a cheap Haiku probe to learn whether
#     the account is still rate-limited, and backs off to the reported reset time
#
# Layout:
#   tools/autoresume/tasks/<task>/resume_prompt.txt   prompt fed on stdin
#   tools/autoresume/tasks/<task>/session_id.txt      session to resume (chained on fork)
#   tools/autoresume/tasks/<task>/PROGRESS.md         the agent's own progress notes
#   tools/autoresume/tasks/<task>/state/              log, lock, retry_after, DONE
#
# Modes:
#   -Task <id> -SelfTest    verify every moving part (does not touch other tasks)
#   -Task <id> -RunOnce     one polling iteration (this is what the timer calls)
#   -Task <id> -Install     register the Windows scheduled task
#   -Task <id> -Uninstall   remove it
#   -Task <id> -Status      print current state
#   -Task <id> -Unblock     clear the BLOCKED marker and re-arm the timer
#   -List                   list all tasks and their state
#
# The timer stops by itself on DONE and on BLOCKED, and each tick runs through
# conhost --headless so it never shows a console window. Deleting the BLOCKED
# marker by hand is no longer enough to resume -- use -Unblock, which re-registers
# the scheduled task as well.

[CmdletBinding()]
param(
    [string]$Task = '',
    [switch]$SelfTest,
    [switch]$RunOnce,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$List,
    [switch]$Unblock,
    [int]$IntervalMin = 10,
    # A session whose transcript changed within this many minutes is considered
    # owned by a live interactive session; the timer stays out of the way.
    [int]$IdleMin = 20,
    [int]$RunTimeoutMin = 240
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = 'C:\Users\ryupc\WorkSpace\Mitou26'
$TasksDir   = Join-Path $Root 'tasks'
$ProbeModel = 'claude-haiku-4-5-20251001'

# ---------------------------------------------------------------- task paths
function Resolve-TaskPaths {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'a -Task <id> is required' }
    if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw "invalid task id: $Name" }
    $dir   = Join-Path $TasksDir $Name
    $state = Join-Path $dir 'state'
    return [pscustomobject]@{
        Name      = $Name
        Dir       = $dir
        State     = $state
        Log       = Join-Path $state 'autoresume.log'
        Done      = Join-Path $state 'DONE'
        Blocked   = Join-Path $state 'BLOCKED'
        Retry     = Join-Path $state 'retry_after.txt'
        Lock      = Join-Path $state 'lock.pid'
        Prompt    = Join-Path $dir 'resume_prompt.txt'
        SessionId = Join-Path $dir 'session_id.txt'
        Progress  = Join-Path $dir 'PROGRESS.md'
        TaskName  = 'AquaBeacon_AutoResume_' + $Name
    }
}

$TaskCtx = $null
if ($Task) {
    $TaskCtx = Resolve-TaskPaths $Task
    if (-not (Test-Path $TaskCtx.State)) { New-Item -ItemType Directory -Path $TaskCtx.State -Force | Out-Null }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($TaskCtx) { Add-Content -Path $TaskCtx.Log -Value $line -Encoding utf8 }
    Write-Output $line
}

# ---------------------------------------------------------------- helpers
function Get-ClaudeExe {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

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
    foreach ($p in $patterns) { if ($Text -match $p) { return $true } }
    return $false
}

# Understands "usage limit reached|<epoch>", "resets at 3:00pm" / "resets at 15:00".
# Falls back to now + 65 min: a 5-hour window seen from an arbitrary point never
# has more than that left once we are already polling, and we re-poll anyway.
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

# ~/.claude/projects/<dir with : and \ replaced by ->/<session>.jsonl
function Get-TranscriptPath {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }
    $slug = $ProjectDir.Replace(':', '-').Replace('\', '-')
    return Join-Path $env:USERPROFILE (Join-Path '.claude\projects' (Join-Path $slug ($SessionId + '.jsonl')))
}

function Get-TaskSessionId {
    param($Paths)
    if (-not (Test-Path $Paths.SessionId)) { return '' }
    return (Get-Content $Paths.SessionId -Raw).Trim()
}

# $true when the pinned session's transcript changed within $IdleMin minutes,
# i.e. a live interactive session is actively working on this task.
function Test-SessionLive {
    param([string]$SessionId, [int]$Minutes = 20)
    $p = Get-TranscriptPath $SessionId
    if (-not $p -or -not (Test-Path $p)) { return $false }
    $age = ((Get-Date) - (Get-Item $p).LastWriteTime).TotalMinutes
    return ($age -lt $Minutes)
}

function Get-Lock {
    param($Paths)
    if (Test-Path $Paths.Lock) {
        $old = (Get-Content $Paths.Lock -Raw).Trim()
        $alive = $false
        if ($old -match '^\d+$') {
            $alive = [bool](Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)
        }
        if ($alive) { return $false }
        Remove-Item $Paths.Lock -Force -ErrorAction SilentlyContinue
    }
    Set-Content -Path $Paths.Lock -Value $PID -Encoding ascii
    return $true
}

function Release-Lock { param($Paths) Remove-Item $Paths.Lock -Force -ErrorAction SilentlyContinue }

function Get-RetryAfter {
    param($Paths)
    if (-not (Test-Path $Paths.Retry)) { return $null }
    $raw = (Get-Content $Paths.Retry -Raw).Trim()
    try { return [datetime]::Parse($raw) } catch { return $null }
}

function Set-RetryAfter {
    param($Paths, [datetime]$When)
    Set-Content -Path $Paths.Retry -Value ($When.ToString('o')) -Encoding ascii
}

# Run claude headless, return @{ExitCode;Text;Json}. Prompt always via stdin file:
# Start-Process on PS 5.1 does not quote argv elements, and the prompts are
# multi-line Japanese.
function Invoke-Claude {
    param(
        [string]$ClaudeExe,
        [string[]]$Arguments,
        [string]$StdinFile,
        [int]$TimeoutSec,
        [string]$OutFile
    )
    # Start-Process refuses identical stdout/stderr targets, so always derive a
    # distinct name by suffix rather than by pattern-replacing the extension.
    $err = $OutFile + '.err'
    $p = Start-Process -FilePath $ClaudeExe -ArgumentList $Arguments -WorkingDirectory $ProjectDir `
                       -RedirectStandardInput $StdinFile `
                       -RedirectStandardOutput $OutFile -RedirectStandardError $err `
                       -NoNewWindow -PassThru
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ ExitCode = -1; Text = 'TIMEOUT'; Json = $null }
    }
    $text = ''
    foreach ($f in @($OutFile, $err)) {
        if (Test-Path $f) { $text += (Get-Content $f -Raw -Encoding utf8) }
    }
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch { $json = $null }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Text = $text; Json = $json }
}

# Cheap account-level probe: is the usage limit still in force?
function Test-LimitActive {
    param([string]$ClaudeExe, $Paths)
    $tmp = Join-Path $Paths.State 'probe'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    $i = Join-Path $tmp 'in.txt'
    Set-Content -Path $i -Value 'Reply with exactly: PROBE_OK' -Encoding ascii
    $r = Invoke-Claude -ClaudeExe $ClaudeExe `
                       -Arguments @('--print', '--model', $ProbeModel, '--no-session-persistence') `
                       -StdinFile $i -TimeoutSec 180 -OutFile (Join-Path $tmp 'out.txt')
    if ($r.Text -match 'PROBE_OK') { return [pscustomobject]@{ Limited = $false; Text = $r.Text } }
    if (Test-UsageLimit $r.Text)  { return [pscustomobject]@{ Limited = $true;  Text = $r.Text } }
    # Neither a clean answer nor a recognisable limit: treat as limited so we
    # retry later rather than burning the real session on a broken environment.
    return [pscustomobject]@{ Limited = $true; Text = $r.Text }
}

# ---------------------------------------------------------------- scheduled task
function Test-TaskInstalled {
    param([string]$Name)
    return ($null -ne (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue))
}

function Install-Task {
    param($Paths)
    $ps  = (Get-Command powershell.exe).Source
    $inner = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Task {1} -RunOnce' -f `
             (Join-Path $Root 'task_resume.ps1'), $Paths.Name
    # A bare powershell.exe action under an InteractiveToken principal pops a
    # console window on EVERY tick -- at a 10 min interval that is a terminal
    # flashing on the desktop 144 times a day, and -WindowStyle Hidden still
    # flashes because the console is allocated before the style is applied.
    # conhost --headless gives the child a pseudoconsole with no window at all.
    # It is preferred over an S4U principal ("run whether logged on or not"),
    # which is also windowless but drops the user's credentials from the token,
    # so claude.exe could no longer read its DPAPI-protected login.
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    if (Test-Path $conhost) {
        $exe = $conhost
        $arg = '--headless "{0}" {1}' -f $ps, $inner
    } else {
        Write-Log 'conhost.exe not found; falling back to a visible powershell window' 'WARN'
        $exe = $ps
        $arg = $inner
    }
    $action  = New-ScheduledTaskAction -Execute $exe -Argument $arg -WorkingDirectory $ProjectDir
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                 -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 8) `
                 -MultipleInstances IgnoreNew
    if (Test-TaskInstalled $Paths.TaskName) { Unregister-ScheduledTask -TaskName $Paths.TaskName -Confirm:$false }
    Register-ScheduledTask -TaskName $Paths.TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description ('AquaBeacon auto-resume for task: ' + $Paths.Name) | Out-Null
    Write-Log ("scheduled task '{0}' installed (every {1} min)" -f $Paths.TaskName, $IntervalMin)
}

function Uninstall-Task {
    param($Paths)
    if (Test-TaskInstalled $Paths.TaskName) {
        Unregister-ScheduledTask -TaskName $Paths.TaskName -Confirm:$false
        Write-Log ("scheduled task '{0}' removed" -f $Paths.TaskName)
    } else {
        Write-Log ("scheduled task '{0}' was not installed" -f $Paths.TaskName)
    }
}

# ---------------------------------------------------------------- resume
function Invoke-Resume {
    param([string]$ClaudeExe, $Paths)

    $sid = Get-TaskSessionId $Paths
    if (-not $sid) { Write-Log 'session_id.txt missing or empty' 'ERROR'; return }
    $prompt = Get-Content $Paths.Prompt -Raw -Encoding utf8

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $out   = Join-Path $Paths.State ('run_{0}.out.txt' -f $stamp)

    # --fork-session: never write into a transcript an interactive session may still
    # own. The fork inherits the full history and returns a fresh session id, which
    # becomes the pin for the next resume so context keeps chaining forward.
    $argList = @('--resume', $sid, '--fork-session', '--print', '--output-format', 'json')

    Write-Log ('resuming session {0} (fork, prompt {1} chars)' -f $sid, $prompt.Length)
    $r = Invoke-Claude -ClaudeExe $ClaudeExe -Arguments $argList -StdinFile $Paths.Prompt `
                       -TimeoutSec ($RunTimeoutMin * 60) -OutFile $out

    if ($r.Text -eq 'TIMEOUT') { Write-Log ('resume killed after {0} min' -f $RunTimeoutMin) 'WARN'; return }

    if ($r.Json -and $r.Json.session_id) {
        Set-Content -Path $Paths.SessionId -Value $r.Json.session_id -Encoding ascii
        Write-Log ('session chained: {0} -> {1}' -f $sid, $r.Json.session_id)
    }

    if (Test-UsageLimit $r.Text) {
        $reset = (Get-ResetTime $r.Text).AddMinutes(2)
        Set-RetryAfter $Paths $reset
        Write-Log ('usage limit hit during resume; backing off until {0}' -f $reset) 'WARN'
        return
    }

    Remove-Item $Paths.Retry -Force -ErrorAction SilentlyContinue
    $tail = ''
    if ($r.Json -and $r.Json.result) { $tail = ($r.Json.result -replace '\s+', ' ') }
    if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) }
    Write-Log ('resume finished exit={0}. tail: {1}' -f $r.ExitCode, $tail)
}

function Invoke-RunOnce {
    param($Paths)
    if (Test-Path $Paths.Done) {
        Write-Log 'DONE marker present -> work finished; removing scheduled task'
        Uninstall-Task $Paths
        return
    }
    # Everything left needs a person. Nothing this timer can do will change that,
    # so it must stop ticking rather than skip: an earlier version kept the task
    # installed so that deleting the marker would resume automatically, and it
    # then woke up every 10 min for two days producing nothing but 300 identical
    # log lines. Re-arming is now an explicit -Unblock.
    if (Test-Path $Paths.Blocked) {
        # -Encoding UTF8 is not optional: PS 5.1 otherwise reads a BOM-less
        # UTF-8 file as cp932 and the reason comes out as mojibake.
        $why = (Get-Content $Paths.Blocked -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        Write-Log ('BLOCKED on human input -> stopping the timer. Re-arm with: task_resume.ps1 -Task {0} -Unblock. Reason: {1}' `
                   -f $Paths.Name, ($why -replace '\s+', ' ').Trim())
        Uninstall-Task $Paths
        return
    }
    if (-not (Get-Lock $Paths)) { Write-Log 'another instance holds the lock; skip'; return }
    try {
        $retry = Get-RetryAfter $Paths
        if ($retry -and $retry -gt (Get-Date)) {
            Write-Log ('inside usage-limit window (until {0}); skip' -f $retry)
            return
        }
        $sid = Get-TaskSessionId $Paths
        if (Test-SessionLive $sid $IdleMin) {
            Write-Log ('session {0} was active < {1} min ago; a live session owns the work; skip' -f $sid, $IdleMin)
            return
        }
        $claude = Get-ClaudeExe
        if (-not $claude) { Write-Log 'claude CLI not found' 'ERROR'; return }

        $probe = Test-LimitActive $claude $Paths
        if ($probe.Limited) {
            $reset = (Get-ResetTime $probe.Text).AddMinutes(2)
            Set-RetryAfter $Paths $reset
            Write-Log ('probe says still limited/unavailable; retry after {0}' -f $reset) 'WARN'
            return
        }
        Invoke-Resume $claude $Paths
    } finally {
        Release-Lock $Paths
    }
}

# ---------------------------------------------------------------- self test
function Invoke-SelfTest {
    param($Paths)
    $fail = 0
    $n = 0
    Write-Log ("=== SELF TEST START (task '{0}') ===" -f $Paths.Name)

    $claude = Get-ClaudeExe
    $n++
    if ($claude) { Write-Log ("[{0}] PASS claude CLI: {1}" -f $n, $claude) }
    else { Write-Log ("[{0}] FAIL claude CLI not found" -f $n) 'ERROR'; $fail++ }

    $n++
    if ((Test-Path $Paths.Prompt) -and (Get-Item $Paths.Prompt).Length -gt 50) {
        Write-Log ("[{0}] PASS prompt file: {1} bytes" -f $n, (Get-Item $Paths.Prompt).Length)
    } else { Write-Log ("[{0}] FAIL prompt file missing or too short" -f $n) 'ERROR'; $fail++ }

    $n++
    $sid = Get-TaskSessionId $Paths
    $tp  = Get-TranscriptPath $sid
    if ($sid -and $tp -and (Test-Path $tp)) {
        Write-Log ("[{0}] PASS session pinned: {1} (transcript {2:N0} KB)" -f $n, $sid, ((Get-Item $tp).Length / 1KB))
    } else { Write-Log ("[{0}] FAIL session id / transcript not found ({1})" -f $n, $sid) 'ERROR'; $fail++ }

    $n++
    $pos = @(
        'Claude AI usage limit reached|1785000000',
        'You have reached your 5-hour limit. Try again later.',
        'API Error: rate_limit_error',
        'Usage limit reached - resets at 3:00pm'
    )
    $neg = @('Build finished: exit=0', 'Wrote parts/child/exterior/frame.scad', 'PROBE_OK')
    $ok = $true
    foreach ($t in $pos) { if (-not (Test-UsageLimit $t)) { $ok = $false; Write-Log "  missed positive: $t" 'ERROR' } }
    foreach ($t in $neg) { if (Test-UsageLimit $t) { $ok = $false; Write-Log "  false positive: $t" 'ERROR' } }
    if ($ok) { Write-Log ("[{0}] PASS usage-limit detection (4 pos / 3 neg)" -f $n) }
    else { Write-Log ("[{0}] FAIL usage-limit detection" -f $n) 'ERROR'; $fail++ }

    $n++
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    $d = ((Get-ResetTime ("Claude AI usage limit reached|{0}" -f $epoch)) - (Get-Date)).TotalMinutes
    if ($d -gt 50 -and $d -lt 70) { Write-Log ("[{0}] PASS reset-time parse: +{1:N0} min" -f $n, $d) }
    else { Write-Log ("[{0}] FAIL reset-time parse: +{1:N0} min" -f $n, $d) 'ERROR'; $fail++ }

    $n++
    if (Get-Lock $Paths) {
        $second = Get-Lock $Paths
        Release-Lock $Paths
        if (-not $second) { Write-Log ("[{0}] PASS lock is exclusive" -f $n) }
        else { Write-Log ("[{0}] FAIL lock is not exclusive" -f $n) 'ERROR'; $fail++ }
    } else { Write-Log ("[{0}] FAIL could not acquire lock" -f $n) 'ERROR'; $fail++ }

    # live-session detection: fresh transcript -> live, backdated -> idle
    $n++
    $probeDir = Join-Path $Paths.State 'selftest'
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    $slug  = $ProjectDir.Replace(':', '-').Replace('\', '-')
    $projD = Join-Path $env:USERPROFILE (Join-Path '.claude\projects' $slug)
    $fakeId = 'selftest-' + $PID
    $fake   = Join-Path $projD ($fakeId + '.jsonl')
    try {
        Set-Content -Path $fake -Value '{}' -Encoding ascii
        $liveNow = Test-SessionLive $fakeId $IdleMin
        (Get-Item $fake).LastWriteTime = (Get-Date).AddMinutes(-($IdleMin + 30))
        $liveOld = Test-SessionLive $fakeId $IdleMin
        $liveMissing = Test-SessionLive 'no-such-session-id' $IdleMin
        if ($liveNow -and (-not $liveOld) -and (-not $liveMissing)) {
            Write-Log ("[{0}] PASS live-session detection (fresh=live, stale=idle, missing=idle)" -f $n)
        } else {
            Write-Log ("[{0}] FAIL live-session detection: fresh={1} stale={2} missing={3}" -f $n, $liveNow, $liveOld, $liveMissing) 'ERROR'
            $fail++
        }
    } finally { Remove-Item $fake -Force -ErrorAction SilentlyContinue }

    # a real headless probe must answer
    $n++
    if ($claude) {
        $p = Test-LimitActive $claude $Paths
        if (-not $p.Limited) { Write-Log ("[{0}] PASS headless probe answered PROBE_OK" -f $n) }
        elseif (Test-UsageLimit $p.Text) { Write-Log ("[{0}] PASS(limit) probe reports the limit; back-off path is what would run" -f $n) }
        else { Write-Log ("[{0}] FAIL probe output: {1}" -f $n, ($p.Text -replace '\s+', ' ')) 'ERROR'; $fail++ }
    } else { Write-Log ("[{0}] SKIP probe (no claude CLI)" -f $n) 'WARN'; $fail++ }

    # resume + fork + json parsing, on a throwaway session (never the real one)
    $n++
    if ($claude) {
        $sdir = Join-Path $Paths.State 'selftest'
        New-Item -ItemType Directory -Path $sdir -Force | Out-Null
        $seedId = [guid]::NewGuid().ToString()
        $i1 = Join-Path $sdir 'seed_in.txt'
        Set-Content -Path $i1 -Value 'Remember this token: ZEBRA42. Reply with exactly: SEEDED' -Encoding ascii
        $r1 = Invoke-Claude -ClaudeExe $claude `
                -Arguments @('--print', '--model', $ProbeModel, '--session-id', $seedId) `
                -StdinFile $i1 -TimeoutSec 180 -OutFile (Join-Path $sdir 'seed_out.txt')
        $i2 = Join-Path $sdir 'resume_in.txt'
        Set-Content -Path $i2 -Value 'What token did I ask you to remember? Reply with the token only.' -Encoding ascii
        $r2 = Invoke-Claude -ClaudeExe $claude `
                -Arguments @('--resume', $seedId, '--fork-session', '--print', '--output-format', 'json', '--model', $ProbeModel) `
                -StdinFile $i2 -TimeoutSec 180 -OutFile (Join-Path $sdir 'resume_out.txt')
        $recalled = ($r2.Json -and $r2.Json.result -match 'ZEBRA42')
        $forked   = ($r2.Json -and $r2.Json.session_id -and $r2.Json.session_id -ne $seedId)
        if ($recalled -and $forked) {
            Write-Log ("[{0}] PASS resume+fork carries context (seed {1} -> fork {2})" -f $n, $seedId.Substring(0,8), $r2.Json.session_id.Substring(0,8))
        } elseif (Test-UsageLimit ($r1.Text + $r2.Text)) {
            Write-Log ("[{0}] PASS(limit) resume path blocked by the usage limit; back-off is what would run" -f $n)
        } else {
            Write-Log ("[{0}] FAIL resume+fork: recalled={1} forked={2} out={3}" -f $n, $recalled, $forked, ($r2.Text -replace '\s+', ' ')) 'ERROR'
            $fail++
        }
    } else { Write-Log ("[{0}] SKIP resume test (no claude CLI)" -f $n) 'WARN'; $fail++ }

    # scheduled task lifecycle -- name is task-scoped, so other tasks are untouched
    $n++
    $wasInstalled = Test-TaskInstalled $Paths.TaskName
    try {
        if (-not $wasInstalled) { Install-Task $Paths }
        if (Test-TaskInstalled $Paths.TaskName) { Write-Log ("[{0}] PASS scheduled task create/query works" -f $n) }
        else { Write-Log ("[{0}] FAIL scheduled task not found after create" -f $n) 'ERROR'; $fail++ }
        if (-not $wasInstalled) { Uninstall-Task $Paths }
    } catch {
        Write-Log ("[{0}] FAIL scheduled task: {1}" -f $n, $_.Exception.Message) 'ERROR'; $fail++
    }

    # do no harm: the other agent's single-tenant task must still be registered
    $n++
    if (Test-TaskInstalled 'AquaBeacon_AutoResume') {
        Write-Log ("[{0}] PASS legacy task 'AquaBeacon_AutoResume' still installed (other agent unaffected)" -f $n)
    } else {
        Write-Log ("[{0}] WARN legacy task 'AquaBeacon_AutoResume' is not installed (was it already removed?)" -f $n) 'WARN'
    }

    if ($fail -eq 0) { Write-Log ("=== SELF TEST: ALL PASS ({0} checks) ===" -f $n); exit 0 }
    Write-Log ("=== SELF TEST: {0} FAILURE(S) ===" -f $fail) 'ERROR'
    exit 1
}

function Show-Status {
    param($Paths)
    $sid = Get-TaskSessionId $Paths
    Write-Output ('task         : {0}' -f $Paths.Name)
    Write-Output ('scheduled    : {0} -> {1}' -f $Paths.TaskName, $(if (Test-TaskInstalled $Paths.TaskName) { 'INSTALLED' } else { 'not installed' }))
    Write-Output ('session      : {0}' -f $(if ($sid) { $sid } else { '-' }))
    Write-Output ('live now     : {0} (idle window {1} min)' -f (Test-SessionLive $sid $IdleMin), $IdleMin)
    Write-Output ('DONE marker  : {0}' -f $(if (Test-Path $Paths.Done) { 'present (auto-resume disabled)' } else { 'absent (armed)' }))
    if (Test-Path $Paths.Blocked) {
        Write-Output ('BLOCKED      : yes -- waiting on a human. Reason:')
        Get-Content $Paths.Blocked -Encoding UTF8 | ForEach-Object { Write-Output ('               ' + $_) }
        Write-Output ('               clear with: -Task {0} -Unblock' -f $Paths.Name)
    } else {
        Write-Output ('BLOCKED      : no')
    }
    $r = Get-RetryAfter $Paths
    Write-Output ('retry after  : {0}' -f $(if ($r) { $r } else { '-' }))
    if (Test-Path $Paths.Log) {
        Write-Output '--- last 15 log lines ---'
        Get-Content $Paths.Log -Tail 15
    }
}

function Show-List {
    Write-Output ('legacy AquaBeacon_AutoResume : {0}' -f $(if (Test-TaskInstalled 'AquaBeacon_AutoResume') { 'INSTALLED' } else { 'not installed' }))
    if (-not (Test-Path $TasksDir)) { Write-Output 'no multi-tenant tasks yet'; return }
    foreach ($d in Get-ChildItem $TasksDir -Directory) {
        $p = Resolve-TaskPaths $d.Name
        $state = if (Test-Path $p.Done) { 'DONE' }
                 elseif (Test-Path $p.Blocked) { 'BLOCKED' }
                 elseif (Test-TaskInstalled $p.TaskName) { 'armed' }
                 else { 'not installed' }
        Write-Output ('{0,-24} {1,-14} session={2}' -f $d.Name, $state, (Get-TaskSessionId $p))
    }
}

# ---------------------------------------------------------------- dispatch
if     ($List)      { Show-List }
elseif ($SelfTest)  { Invoke-SelfTest $TaskCtx }
elseif ($Install)   { Install-Task $TaskCtx }
elseif ($Uninstall) { Uninstall-Task $TaskCtx }
elseif ($Unblock)   {
    if (Test-Path $TaskCtx.Blocked) {
        Remove-Item $TaskCtx.Blocked -Force
        Write-Log 'BLOCKED marker cleared'
    } else { Write-Log 'not blocked' }
    # Blocking uninstalls the timer, so clearing the marker has to put it back.
    if (Test-Path $TaskCtx.Done) {
        Write-Log 'DONE marker present; leaving the timer uninstalled'
    } elseif (Test-TaskInstalled $TaskCtx.TaskName) {
        Write-Log 'timer already armed'
    } else {
        Install-Task $TaskCtx
    }
}
elseif ($RunOnce)   { Invoke-RunOnce $TaskCtx }
elseif ($Status)    { Show-Status $TaskCtx }
elseif ($TaskCtx)         { Show-Status $TaskCtx }
else                { Show-List }
