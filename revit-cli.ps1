# revit-cli-v2.ps1 — Revit Named Pipe CLI (파이프 서버 v2 규약 클라이언트)
# 규약 원문: revit-addins/docs/specs/2026-09-30-pipe-server-v2.md (1장 + 7장 1·9·10·11·16)
#
# 사용법:
#   powershell -File revit-cli-v2.ps1 -Code "Doc.Title"
#   powershell -File revit-cli-v2.ps1 -File "C:\temp\script.cs" -Timeout 900000
#   powershell -File revit-cli-v2.ps1 -Code "Doc.Title" -Doc "프로젝트1" -Label "제목확인" -NoGroup
#   powershell -File revit-cli-v2.ps1 -Status
#
# 출력 규칙 (호출처 호환):
#   stdout = 성공이면 result 그대로 / 실패면 첫 줄 "Error: ..." (그 외에는 아무것도 쓰지 않음)
#   stderr = 보고(팝업·그룹 결과·다른 변경·비활성 문서 경고 등). 보고할 게 없으면 아무것도 안 씀.
#   종료 코드 = 서버가 응답한 경우 0(Revit 쪽 오류 포함), 연결 실패 2, 기타 예외 3, 사용법 오류 1.
#
# 이 파일은 PowerShell 5.1(Windows PowerShell)에서 돌아야 한다 — 삼항·??·&& 등 PS7 전용 구문 금지.
# 한글 리터럴이 있으므로 저장 인코딩은 UTF-8 BOM 유지(BOM 없으면 5.1이 ANSI로 읽어 깨짐).

param(
    [string]$Code,
    [string]$File,
    [int]$Timeout,          # ms. 명시했는지는 $PSBoundParameters로 판별 (기본값 없음)
    [string]$Label,
    [string]$Doc,
    [switch]$NoGroup,
    [switch]$Status,
    [string]$PipeName = 'RevitAIAgent'   # 테스트용 재지정
)

# UTF-8 출력
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ----------------------------------------------------------------------------
# 보조 함수
# ----------------------------------------------------------------------------

# 부모 프로세스 PID (PS 5.1에는 Process.Parent가 없어 CIM 사용). 실패하면 자기 PID.
function Get-ParentPid {
    try {
        $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        if ($p -and $p.ParentProcessId) { return [int]$p.ParentProcessId }
    } catch { }
    return $PID
}

# 예외 메시지 (Task.Wait이 던지는 AggregateException은 안쪽 예외를 꺼냄)
function Get-ErrorMessage($ex) {
    while ($ex -is [System.AggregateException] -and $ex.InnerException) { $ex = $ex.InnerException }
    return $ex.Message
}

# 마감 시각까지 남은 ms (0 이상, int 범위)
function Get-RemainingMs([DateTime]$deadline) {
    $ms = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($ms -lt 0) { return 0 }
    if ($ms -gt 2000000000) { return 2000000000 }
    return [int]$ms
}

# 응답을 한 메시지(Message 모드) 끝까지 읽는다. 마감을 넘기면 TimeoutException.
# 읽기를 비동기로 걸고 Wait(남은 ms)로 기다려서 서버가 멈춰도 영원히 막히지 않는다.
function Read-PipeMessage($pipe, [DateTime]$deadline) {
    $buffer = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    do {
        $task = $pipe.ReadAsync($buffer, 0, $buffer.Length)
        if (-not $task.Wait((Get-RemainingMs $deadline))) {
            throw (New-Object System.TimeoutException('서버 응답 대기 시간 초과'))
        }
        $read = $task.Result
        if ($read -le 0) { break }   # 서버가 연결을 닫음 (무한 루프 방지)
        $ms.Write($buffer, 0, $read)
    } while (-not $pipe.IsMessageComplete)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    # 쉼표 연산자: 빈 배열이 파이프라인에서 $null로 풀리지 않게 감싼다
    return ,$bytes
}

# JSON 텍스트를 들여쓰기만 바꿔 출력한다 (값·이스케이프는 그대로 — PS 5.1 ConvertTo-Json의
# \u0027 같은 재이스케이프와 Depth 잘림을 피하려고 문자열 단위로 직접 처리).
function Format-JsonIndented([string]$Json) {
    $sb = New-Object System.Text.StringBuilder
    $level = 0
    $inStr = $false
    $esc = $false
    $n = $Json.Length
    for ($i = 0; $i -lt $n; $i++) {
        $c = $Json[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); continue }
        if ($c -eq '{' -or $c -eq '[') {
            # 빈 컨테이너는 한 줄로 ({} / [])
            $j = $i + 1
            while ($j -lt $n -and [char]::IsWhiteSpace($Json[$j])) { $j++ }
            $close = if ($c -eq '{') { '}' } else { ']' }
            if ($j -lt $n -and $Json[$j] -eq $close) {
                [void]$sb.Append($c).Append($close)
                $i = $j
                continue
            }
            $level++
            [void]$sb.Append($c).Append("`n").Append(' ', 2 * $level)
            continue
        }
        if ($c -eq '}' -or $c -eq ']') {
            $level--
            if ($level -lt 0) { $level = 0 }
            [void]$sb.Append("`n").Append(' ', 2 * $level).Append($c)
            continue
        }
        if ($c -eq ',') { [void]$sb.Append(",`n").Append(' ', 2 * $level); continue }
        if ($c -eq ':') { [void]$sb.Append(': '); continue }
        if ([char]::IsWhiteSpace($c)) { continue }
        [void]$sb.Append($c)
    }
    return $sb.ToString()
}

# executed 값 -> 한글 문구
function Get-ExecutedText($executed) {
    switch ([string]$executed) {
        'no'    { return '실행 안 됨' }
        'maybe' { return '실행 중이거나 끝났을 수 있음 — 재전송 금지, 상태부터 확인' }
        'yes'   { return '실행됨' }
        default { return '' }
    }
}

# 항목(팝업 등) 텍스트 한 줄: "  - [머리] 본문"
function Format-Item([string]$head, [string]$text) {
    if ($head) { return "  - [$head] $text" }
    return "  - $text"
}

# ----------------------------------------------------------------------------
# 입력 해석
# ----------------------------------------------------------------------------

# 코드 결정: -File이 있으면 파일에서 읽기, 아니면 -Code 사용
if ($File -and (Test-Path -LiteralPath $File)) {
    $Code = Get-Content -LiteralPath $File -Raw -Encoding UTF8
}

$op = 'run'
if ($Status) {
    $op = 'status'
    $Code = ''
}

if ($op -eq 'run' -and -not $Code) {
    if ($File) {
        Write-Error "파일을 찾을 수 없거나 비어 있습니다: $File"
    } else {
        Write-Error "Usage: revit-cli-v2.ps1 -Code 'Doc.Title' or -File 'script.cs' or -Status"
    }
    exit 1
}

# session: CLAUDE_CODE_SESSION_ID 앞 8자, 없으면 "pid" + 부모 PID
$sessionSource = $env:CLAUDE_CODE_SESSION_ID
if ($sessionSource -and $sessionSource.Trim().Length -gt 0) {
    $sessionSource = $sessionSource.Trim()
    $session = $sessionSource.Substring(0, [Math]::Min(8, $sessionSource.Length))
} else {
    $session = 'pid' + (Get-ParentPid)
}

# label: -Label, 없으면 -File 파일명, 그것도 없으면 inline
if ($PSBoundParameters.ContainsKey('Label') -and $Label) {
    $labelText = $Label
} elseif ($File) {
    $labelText = Split-Path -Path $File -Leaf
} else {
    $labelText = 'inline'
}

# timeout(초) = max(ceil(명시한 -Timeout/1000), 코드 첫 줄 //TIMEOUT:n 힌트, 30), 상한 3600
[double]$timeoutSec = 30
if ($PSBoundParameters.ContainsKey('Timeout')) {
    $explicitSec = [Math]::Ceiling($Timeout / 1000.0)
    if ($explicitSec -gt $timeoutSec) { $timeoutSec = $explicitSec }
}
if ($Code) {
    $firstLine = ($Code -split "`n", 2)[0].TrimEnd("`r")
    if ($firstLine -match '^//TIMEOUT:\s*(\d+)\s*$') {
        $hintSec = [double]$Matches[1]
        if ($hintSec -gt $timeoutSec) { $timeoutSec = $hintSec }
    }
}
if ($timeoutSec -gt 3600) { $timeoutSec = 3600 }
$timeoutSec = [int]$timeoutSec

# 요청 = 첫 줄 "//@raa " + 한 줄 JSON, 다음 줄부터 코드
$docValue = $null
if ($Doc) { $docValue = $Doc }
$header = [ordered]@{
    v       = 2
    op      = $op
    session = $session
    label   = $labelText
    doc     = $docValue
    timeout = $timeoutSec
    group   = (-not $NoGroup.IsPresent)
}
$request = '//@raa ' + ($header | ConvertTo-Json -Compress -Depth 10) + "`n" + $Code

# 클라이언트 읽기 제한 = timeout + 10초
$readSec = $timeoutSec + 10

# ----------------------------------------------------------------------------
# 통신
# ----------------------------------------------------------------------------

$exitCode = 0
$pipe = $null
try {
    # 비동기 옵션: 읽기/쓰기에 마감을 걸고, 마감 뒤 Dispose로 대기 중인 I/O를 취소할 수 있게 함
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)

    $connected = $false
    try {
        $pipe.Connect(5000)
        $connected = $true
    } catch [TimeoutException] {
        Write-Error "Revit에 연결할 수 없습니다. Revit이 실행 중인지 확인하세요."
        $exitCode = 2
    }

    if ($connected) {
        $pipe.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message
        $deadline = [DateTime]::UtcNow.AddSeconds($readSec)

        # 요청 전송 (한 번의 Write = 한 메시지). WaitForPipeDrain은 마감이 없어 쓰지 않는다.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($request)
        $wtask = $pipe.WriteAsync($bytes, 0, $bytes.Length)
        if (-not $wtask.Wait((Get-RemainingMs $deadline))) {
            throw (New-Object System.TimeoutException('서버로 요청 전송 시간 초과'))
        }
        $pipe.Flush()

        # 응답 수신
        $respBytes = Read-PipeMessage $pipe $deadline
        if ($respBytes.Length -eq 0) {
            throw (New-Object System.IO.IOException('서버가 응답 없이 연결을 닫았습니다.'))
        }
        $text = [System.Text.Encoding]::UTF8.GetString($respBytes)
        $probe = $text.TrimStart([char]0xFEFF)

        if (-not $probe.StartsWith('{"v":2', [StringComparison]::Ordinal)) {
            # 옛 서버: 원문 그대로 stdout, 무시된 인자 안내는 stderr
            Write-Output $text
            [Console]::Error.WriteLine('구버전 서버 — -Doc/-NoGroup/-Label 무시됨')
        }
        elseif ($op -eq 'status') {
            # -Status: 응답 JSON을 들여써서 그대로 출력
            $null = $probe | ConvertFrom-Json   # JSON 유효성 확인 (깨졌으면 예외 -> 3)
            Write-Output (Format-JsonIndented $probe)
        }
        else {
            $r = $probe | ConvertFrom-Json
            $st = [string]$r.status
            $result = ''
            if ($null -ne $r.result) { $result = [string]$r.result }
            $hasResult = ($result.Trim().Length -gt 0)

            # ---- stdout ----
            if ($st -eq 'ok') {
                Write-Output $result
            }
            else {
                $tail = $true   # 첫 줄 뒤에 result를 이어 쓸지
                if ($st -eq 'expired') {
                    $head = 'Error: Timeout — 대기 중 만료, 실행 안 됨'
                }
                elseif ($st -eq 'timeout_running') {
                    $head = 'Error: Timeout — 실행 중이거나 끝났을 수 있음. 재전송 금지, 상태부터 확인'
                }
                elseif ($st -eq 'blocked') {
                    $title = ''
                    if ($r.blocked -and $r.blocked.title) { $title = [string]$r.blocked.title }
                    if (-not $title) { $title = '(제목 없음)' }
                    $execText = Get-ExecutedText $r.executed
                    if (-not $execText) { $execText = '실행 여부 불명 — 재전송 금지, 상태부터 확인' }
                    $head = "Error: 모달 창이 Revit을 막고 있음 (`"$title`") — $execText"
                }
                elseif ($st -eq 'error') {
                    # 서버가 result에 오류 문구를 담아 보냄. 이미 "Error:"로 시작하면 중복 접두를 붙이지 않는다.
                    $tail = $false
                    if (-not $hasResult) { $head = 'Error: 스크립트 오류 (상세 없음)' }
                    elseif ($result -match '^\s*Error\s*:') { $head = $result }
                    else { $head = 'Error: ' + $result }
                }
                else {
                    # doc_not_found / doc_ambiguous / doc_not_active / bad_request / 알 수 없는 status
                    $tail = $false
                    $name = $st
                    if (-not $name) { $name = '(status 없음)' }
                    if ($hasResult) { $head = "Error: $name — $result" }
                    else { $head = "Error: $name" }
                }
                if ($tail -and $hasResult) { Write-Output ($head + "`n" + $result) }
                else { Write-Output $head }
            }

            # ---- stderr 보고 (없으면 아무것도 쓰지 않음) ----
            $report = New-Object 'System.Collections.Generic.List[string]'

            $warnings = @($r.popups.warnings | Where-Object { $null -ne $_ })
            if ($warnings.Count -gt 0) {
                $report.Add("경고 팝업 $($warnings.Count)건 (자동 삭제됨)")
                foreach ($w in $warnings) { $report.Add((Format-Item ([string]$w.tx) ([string]$w.text))) }
            }
            $errors = @($r.popups.errors | Where-Object { $null -ne $_ })
            if ($errors.Count -gt 0) {
                $report.Add("오류 팝업 $($errors.Count)건")
                foreach ($e in $errors) { $report.Add((Format-Item ([string]$e.tx) ([string]$e.text))) }
            }
            $dialogs = @($r.popups.dialogs | Where-Object { $null -ne $_ })
            if ($dialogs.Count -gt 0) {
                $report.Add("대화상자 $($dialogs.Count)건")
                foreach ($d in $dialogs) { $report.Add((Format-Item ([string]$d.id) ([string]$d.text))) }
            }

            # 그룹 결과: assimilated / none 이외는 모두 보고
            $group = [string]$r.group
            # rolledback-empty = 읽기만 한 요청(가장 흔함) — 보고할 일이 아니다
            $quietGroups = @('assimilated', 'none', 'rolledback-empty')
            if ($group -and ($quietGroups -notcontains $group)) {
                $report.Add("트랜잭션 그룹: $group")
            }

            if ($r.othersChanged -is [ValueType] -and [double]$r.othersChanged -gt 0) {
                $report.Add("직전 실행 이후 이 문서가 다른 곳에서 $($r.othersChanged)건 변경됨 (사용자·다른 세션·Undo 포함)")
            }
            $otherDocs = @($r.otherDocsChanged | Where-Object { $null -ne $_ })
            if ($otherDocs.Count -gt 0) {
                $report.Add("대상 외 문서 변경 (그룹 밖이라 개별 Undo 필요):")
                foreach ($od in $otherDocs) { $report.Add("  - $($od.title): $($od.count)건") }
            }
            if ($r.doc -and $r.doc.active -eq $false) {
                $report.Add("경고: 대상 문서 '$($r.doc.title)'가 활성 문서가 아님 (UIDoc 없음)")
            }

            if ($st -ne 'ok') {
                $execText = Get-ExecutedText $r.executed
                if ($execText) { $report.Add("실행 여부: $execText") }
                if ($st -eq 'blocked' -and $r.blocked -and $null -ne $r.blocked.lastDialog) {
                    $ld = $r.blocked.lastDialog
                    if ($ld -is [string]) { $ldText = $ld }
                    else { $ldText = ($ld | ConvertTo-Json -Compress -Depth 5) }
                    $report.Add("최근 대화상자 기록: $ldText")
                }
            }

            foreach ($line in $report) { [Console]::Error.WriteLine("[revit-cli] $line") }
        }
    }
}
catch {
    Write-Error "오류: $(Get-ErrorMessage $_.Exception)"
    $exitCode = 3
}
finally {
    if ($pipe) { $pipe.Dispose() }
}

exit $exitCode
