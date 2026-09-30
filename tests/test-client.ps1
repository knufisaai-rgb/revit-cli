# test-client.ps1 — revit-cli.ps1 검증
#
# 가짜 파이프 서버(NamedPipeServerStream, Message 모드, 케이스마다 고유 이름)를 백그라운드 runspace에서
# 돌려 요청을 캡처하고 준비한 응답을 돌려준다. 클라이언트는 실제 사용 방식 그대로
# `powershell -NoProfile -File revit-cli.ps1 -PipeName <이름> ...` 로 실행하고
# stdout/stderr를 바이트 단위로 따로 받아 검사한다. 실제 'RevitAIAgent' 파이프에는 연결하지 않는다.
#
# 실행:  powershell -NoProfile -File tests\test-client-v2.ps1            (빠른 케이스, 약 1분)
#        powershell -NoProfile -File tests\test-client-v2.ps1 -IncludeSlow  (읽기 마감 케이스 포함, +40초)
#
# 이 파일도 Windows PowerShell 5.1에서 돌아야 하고, 한글 리터럴이 있어 UTF-8 BOM으로 저장한다.

param(
    [switch]$IncludeSlow
)

$ErrorActionPreference = 'Stop'

# PASS/FAIL 줄의 한글이 깨지지 않도록 콘솔 출력을 UTF-8로
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$client =(Resolve-Path (Join-Path $PSScriptRoot '..\revit-cli.ps1')).Path
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('raa-client-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempDir)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

# ----------------------------------------------------------------------------
# 가짜 서버
# ----------------------------------------------------------------------------

# 서버 본체 (runspace에서 실행): 연결 대기 -> 요청 한 메시지 수신 -> 응답 -> 종료. 요청 텍스트를 반환.
#   $responseBytes = $null 이면 응답 없이 $holdMs 만큼 붙잡고 있다가 닫는다 (0이면 즉시 닫음).
$serverScript = @'
param($server, $responseBytes, $holdMs)
try {
    $conn = $server.WaitForConnectionAsync()
    if (-not $conn.Wait(30000)) { return '#SERVER-ERROR: 클라이언트가 연결하지 않음' }
    $buf = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    do {
        $t = $server.ReadAsync($buf, 0, $buf.Length)
        if (-not $t.Wait(30000)) { return '#SERVER-ERROR: 요청 수신 시간 초과' }
        $n = $t.Result
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
    } while (-not $server.IsMessageComplete)
    $req = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ($null -ne $responseBytes) {
        $server.Write($responseBytes, 0, $responseBytes.Length)
        $server.Flush()
        $server.WaitForPipeDrain()
    } elseif ($holdMs -gt 0) {
        Start-Sleep -Milliseconds $holdMs
    }
    return $req
} catch {
    return '#SERVER-ERROR: ' + $_.Exception.Message
} finally {
    $server.Dispose()
}
'@

function Start-FakeServer([string]$Name, $ResponseBytes, [int]$HoldMs) {
    # 파이프 인스턴스는 여기(메인)에서 만든다 -> 클라이언트가 뜨기 전에 이름이 이미 존재
    $server = New-Object System.IO.Pipes.NamedPipeServerStream($Name,
        [System.IO.Pipes.PipeDirection]::InOut, 1,
        [System.IO.Pipes.PipeTransmissionMode]::Message,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
    $ps = [powershell]::Create()
    [void]$ps.AddScript($serverScript).AddArgument($server).AddArgument($ResponseBytes).AddArgument($HoldMs)
    $async = $ps.BeginInvoke()
    return @{ Server = $server; Ps = $ps; Async = $async }
}

function Complete-FakeServer($Handle, [int]$WaitMs = 60000) {
    $request = $null
    if ($Handle.Async.AsyncWaitHandle.WaitOne($WaitMs)) {
        $out = $Handle.Ps.EndInvoke($Handle.Async)
        if ($out -and $out.Count -gt 0) { $request = [string]$out[0] }
    } else {
        $request = '#SERVER-ERROR: 서버 runspace가 끝나지 않음'
    }
    $Handle.Ps.Dispose()
    return $request
}

# ----------------------------------------------------------------------------
# 클라이언트 실행
# ----------------------------------------------------------------------------

# Windows 명령줄 인자 인용 (백슬래시+따옴표 규칙)
function ConvertTo-QuotedArg([string]$a) {
    $s = $a -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

# 새 powershell.exe 프로세스로 클라이언트를 실행하고 stdout/stderr를 원시 바이트로 따로 받는다.
#   $Env: 자식 프로세스 환경변수 덮어쓰기. 값이 $null이면 제거.
function Invoke-Client([string[]]$ClientArgs, [string]$PipeNameToUse, [hashtable]$Env = @{}, [int]$WaitMs = 90000) {
    $argText = '-NoProfile -NonInteractive -File ' + (ConvertTo-QuotedArg $client) +
               ' -PipeName ' + $PipeNameToUse
    foreach ($a in $ClientArgs) { $argText += ' ' + (ConvertTo-QuotedArg $a) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($k in $Env.Keys) {
        if ($null -eq $Env[$k]) { [void]$psi.EnvironmentVariables.Remove($k) }
        else { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $outMs = New-Object System.IO.MemoryStream
    $errMs = New-Object System.IO.MemoryStream
    $t1 = $p.StandardOutput.BaseStream.CopyToAsync($outMs)
    $t2 = $p.StandardError.BaseStream.CopyToAsync($errMs)
    if (-not $p.WaitForExit($WaitMs)) {
        try { $p.Kill() } catch { }
        throw "클라이언트가 $WaitMs ms 안에 끝나지 않음"
    }
    [void]$t1.Wait(5000)
    [void]$t2.Wait(5000)
    $sw.Stop()
    $exit = $p.ExitCode
    $p.Dispose()
    return [pscustomobject]@{
        ExitCode  = $exit
        Stdout    = $utf8NoBom.GetString($outMs.ToArray())   # BOM이 있으면 U+FEFF로 남는다
        Stderr    = $utf8NoBom.GetString($errMs.ToArray())
        ElapsedMs = $sw.ElapsedMilliseconds
        Request   = $null
    }
}

# 한 케이스 실행: 서버 시작 -> 클라이언트 실행 -> 서버가 받은 요청 회수
function Invoke-Case {
    param(
        $Response,                 # 서버가 보낼 응답 문자열. $null이면 무응답.
        [string[]]$ClientArgs,
        [hashtable]$Env = @{ CLAUDE_CODE_SESSION_ID = 'abcdef1234567890' },
        [int]$HoldMs = 0,
        [int]$ClientWaitMs = 90000
    )
    $name = 'raa-test-' + [Guid]::NewGuid().ToString('N')
    $bytes = $null
    if ($null -ne $Response) { $bytes = $utf8NoBom.GetBytes([string]$Response) }
    $h = Start-FakeServer $name $bytes $HoldMs
    try {
        $r = Invoke-Client $ClientArgs $name $Env $ClientWaitMs
    } finally {
        $req = Complete-FakeServer $h
    }
    $r.Request = $req
    return $r
}

# ----------------------------------------------------------------------------
# 응답 만들기
# ----------------------------------------------------------------------------

# 서버 v2 응답 JSON (컴팩트, "v"가 맨 앞). $Override의 키로 기본값을 덮어쓴다.
function New-Response([hashtable]$Override = @{}) {
    $o = [ordered]@{
        v                = 2
        id               = 1
        status           = 'ok'
        executed         = 'yes'
        result           = 'OK'
        doc              = [ordered]@{ title = '프로젝트1'; path = 'C:\p\프로젝트1.rvt'; active = $true }
        popups           = [ordered]@{ warnings = @(); errors = @(); dialogs = @() }
        group            = 'assimilated'
        othersChanged    = 0
        otherDocsChanged = @()
        waitedMs         = 0
        ranMs            = 12
        blocked          = $null
    }
    foreach ($k in $Override.Keys) { $o[$k] = $Override[$k] }
    return ($o | ConvertTo-Json -Compress -Depth 10)
}

# 요청 텍스트 -> 헤더 객체 / 첫 줄 / 코드
function Split-Request([string]$Request) {
    $nl = $Request.IndexOf("`n")
    if ($nl -lt 0) { return [pscustomobject]@{ First = $Request; Header = $null; Code = '' } }
    $first = $Request.Substring(0, $nl)
    $hdr = $null
    if ($first.StartsWith('//@raa ')) { $hdr = $first.Substring(7) | ConvertFrom-Json }
    return [pscustomobject]@{ First = $first; Header = $hdr; Code = $Request.Substring($nl + 1) }
}

# ----------------------------------------------------------------------------
# 테스트 프레임
# ----------------------------------------------------------------------------

$script:passed = 0
$script:failed = 0
$script:errs = $null

function Expect($cond, [string]$msg) {
    if (-not $cond) { $script:errs.Add($msg) }
}

function FirstLine([string]$s) { return ($s -split "`r?`n", 2)[0] }

function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:errs = New-Object 'System.Collections.Generic.List[string]'
    try { & $Body } catch { $script:errs.Add('예외: ' + $_.Exception.Message) }
    if ($script:errs.Count -eq 0) {
        Write-Host "PASS  $Name"
        $script:passed++
    } else {
        Write-Host "FAIL  $Name"
        foreach ($e in $script:errs) { Write-Host "        - $e" }
        $script:failed++
    }
}

# 공통 검사: 종료 코드 0 + 서버가 요청을 받았음
function Expect-Served($r) {
    Expect ($r.ExitCode -eq 0) "종료 코드 0 기대, 실제 $($r.ExitCode) / stderr: $($r.Stderr)"
    Expect ($r.Request -and -not $r.Request.StartsWith('#SERVER-ERROR')) "서버가 요청을 못 받음: $($r.Request)"
}

# ============================================================================
# 1. 응답 처리 — 성공
# ============================================================================

Test-Case 'ok: stdout = result 그대로(BOM/부가 출력 없음), stderr 비어 있음' {
    $result = "첫 줄 결과`n둘째 줄: it's <b> & `"quote`" \ 백슬래시 [1,2] {x}"
    $r = Invoke-Case (New-Response @{ result = $result }) @('-Code', 'Doc.Title')
    Expect-Served $r
    Expect ($r.Stdout -ceq ($result + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr -eq '') "stderr가 비어 있어야 함: [$($r.Stderr)]"
}

Test-Case 'ok: 큰 응답(64KB 버퍼 여러 번 + 약 900KB) 끝까지 수신, stdout 정확히 일치' {
    $result = ('가나다라마바사 result line ' * 40000)   # 약 1.1M 문자 = UTF-8 약 2.6MB
    $r = Invoke-Case (New-Response @{ result = $result }) @('-Code', 'Doc.Title')
    Expect-Served $r
    Expect ($r.Stdout.Length -eq ($result.Length + 2)) "stdout 길이 불일치: $($r.Stdout.Length) / 기대 $($result.Length + 2)"
    Expect ($r.Stdout -ceq ($result + "`r`n")) "stdout 내용 불일치"
    Expect ($r.Stderr -eq '') "stderr가 비어 있어야 함: [$($r.Stderr)]"
}

Test-Case 'ok: 빈 result도 stdout에 빈 줄 하나만, stderr 비어 있음' {
    $r = Invoke-Case (New-Response @{ result = '' }) @('-Code', 'var x = 1;')
    Expect-Served $r
    Expect ($r.Stdout -ceq "`r`n") "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr -eq '') "stderr가 비어 있어야 함: [$($r.Stderr)]"
}

Test-Case 'ok + 경고 팝업: stdout = result 그대로, stderr에 경고 문구' {
    $resp = New-Response @{
        result = '[OK] 벽 3개 생성'
        popups = [ordered]@{
            warnings = @([ordered]@{ tx = '벽 생성'; text = '벽이 서로 겹칩니다 (겹침경고XYZ)' })
            errors   = @()
            dialogs  = @()
        }
    }
    $r = Invoke-Case $resp @('-Code', 'x')
    Expect-Served $r
    Expect ($r.Stdout -ceq ("[OK] 벽 3개 생성" + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('겹침경고XYZ')) "stderr에 경고 문구 없음: [$($r.Stderr)]"
    Expect ($r.Stderr.Contains('벽 생성')) "stderr에 트랜잭션 이름 없음: [$($r.Stderr)]"
}

Test-Case 'ok + 오류 팝업 / 대화상자: stderr에 문구' {
    $resp = New-Response @{
        popups = [ordered]@{
            warnings = @()
            errors   = @([ordered]@{ tx = '문 이동'; text = '오류본문AAA' })
            dialogs  = @([ordered]@{ id = 'TaskDialog_Foo'; text = '대화상자본문BBB' })
        }
    }
    $r = Invoke-Case $resp @('-Code', 'x')
    Expect-Served $r
    Expect ($r.Stdout -ceq ("OK" + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('오류본문AAA')) "stderr에 오류 팝업 문구 없음: [$($r.Stderr)]"
    Expect ($r.Stderr.Contains('TaskDialog_Foo') -and $r.Stderr.Contains('대화상자본문BBB')) "stderr에 대화상자 없음: [$($r.Stderr)]"
}

Test-Case 'ok + 그룹 skipped는 stderr에 보고, rolledback-empty(읽기 전용)는 조용히' {
    $r = Invoke-Case (New-Response @{ group = 'skipped:열린 트랜잭션' }) @('-Code', 'x')
    Expect-Served $r
    Expect ($r.Stderr.Contains('skipped:열린 트랜잭션')) "stderr에 그룹 결과 없음: [$($r.Stderr)]"
    $r2 = Invoke-Case (New-Response @{ group = 'rolledback-empty' }) @('-Code', 'x')
    Expect-Served $r2
    Expect ($r2.Stderr -eq '') "rolledback-empty인데 stderr가 비어 있지 않음: [$($r2.Stderr)]"
}

Test-Case 'ok + group none / assimilated / othersChanged null·0: stderr 비어 있음' {
    foreach ($g in @('none', 'assimilated')) {
        $r = Invoke-Case (New-Response @{ group = $g; othersChanged = $null }) @('-Code', 'x')
        Expect-Served $r
        Expect ($r.Stderr -eq '') "group=$g 일 때 stderr가 비어 있어야 함: [$($r.Stderr)]"
        Expect ($r.Stdout -ceq ("OK" + "`r`n")) "group=$g 일 때 stdout 불일치: [$($r.Stdout)]"
    }
}

Test-Case 'ok + othersChanged>0 / otherDocsChanged / 문서 비활성: stderr에 각각 보고' {
    $resp = New-Response @{
        othersChanged    = 7
        otherDocsChanged = @([ordered]@{ title = '패밀리ZZZ'; count = 4 })
        doc              = [ordered]@{ title = '뒤쪽문서QQQ'; path = 'C:\p\b.rvt'; active = $false }
    }
    $r = Invoke-Case $resp @('-Code', 'x')
    Expect-Served $r
    Expect ($r.Stdout -ceq ("OK" + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('7')) "stderr에 othersChanged(7) 없음: [$($r.Stderr)]"
    Expect ($r.Stderr.Contains('패밀리ZZZ') -and $r.Stderr.Contains('4')) "stderr에 otherDocsChanged 없음: [$($r.Stderr)]"
    Expect ($r.Stderr.Contains('뒤쪽문서QQQ') -and $r.Stderr.Contains('활성')) "stderr에 비활성 문서 경고 없음: [$($r.Stderr)]"
}

# ============================================================================
# 2. 응답 처리 — 실패 (stdout 첫 줄 "Error:")
# ============================================================================

Test-Case 'expired: 첫 줄 "Error: Timeout", 실행 안 됨' {
    $r = Invoke-Case (New-Response @{ status = 'expired'; executed = 'no'; result = '' }) @('-Code', 'x')
    Expect-Served $r
    $first = FirstLine $r.Stdout
    Expect ($first -ceq 'Error: Timeout — 대기 중 만료, 실행 안 됨') "첫 줄 불일치: [$first]"
    Expect ($r.Stderr.Contains('실행 안 됨')) "stderr에 실행 여부 없음: [$($r.Stderr)]"
}

Test-Case 'timeout_running: 첫 줄 "Error: Timeout", 재전송 금지 (실행 안 됨 아님)' {
    $r = Invoke-Case (New-Response @{ status = 'timeout_running'; executed = 'maybe'; result = '' }) @('-Code', 'x')
    Expect-Served $r
    $first = FirstLine $r.Stdout
    Expect ($first -ceq 'Error: Timeout — 실행 중이거나 끝났을 수 있음. 재전송 금지, 상태부터 확인') "첫 줄 불일치: [$first]"
    Expect (-not $first.Contains('실행 안 됨')) "timeout_running 첫 줄에 '실행 안 됨'이 있으면 안 됨: [$first]"
}

Test-Case 'blocked(no): 첫 줄 Error: + 창 제목 + 실행 안 됨' {
    $resp = New-Response @{
        status   = 'blocked'
        executed = 'no'
        result   = ''
        blocked  = [ordered]@{ title = '경고 - 문제창가나다'; lastDialog = $null }
    }
    $r = Invoke-Case $resp @('-Code', 'x')
    Expect-Served $r
    $first = FirstLine $r.Stdout
    Expect ($first.StartsWith('Error: ')) "첫 줄이 'Error: '로 시작해야 함: [$first]"
    Expect ($first.Contains('경고 - 문제창가나다')) "첫 줄에 창 제목 없음: [$first]"
    Expect ($first.Contains('실행 안 됨')) "첫 줄에 '실행 안 됨' 없음: [$first]"
    Expect (-not $first.Contains('재전송 금지')) "blocked(no) 첫 줄에 재전송 금지가 있으면 안 됨: [$first]"
}

Test-Case 'blocked(maybe): 첫 줄 Error: + 창 제목 + 재전송 금지, lastDialog는 stderr' {
    $resp = New-Response @{
        status   = 'blocked'
        executed = 'maybe'
        result   = ''
        blocked  = [ordered]@{ title = 'Revit 모달다이얼로그'; lastDialog = [ordered]@{ id = 'TaskDialog_Bar'; text = '마지막대화문구' } }
    }
    $r = Invoke-Case $resp @('-Code', 'x')
    Expect-Served $r
    $first = FirstLine $r.Stdout
    Expect ($first.StartsWith('Error: ')) "첫 줄이 'Error: '로 시작해야 함: [$first]"
    Expect ($first.Contains('Revit 모달다이얼로그')) "첫 줄에 창 제목 없음: [$first]"
    Expect ($first.Contains('실행 중이거나 끝났을 수 있음 — 재전송 금지')) "첫 줄에 재전송 금지 문구 없음: [$first]"
    Expect (-not $first.Contains('실행 안 됨')) "blocked(maybe) 첫 줄에 '실행 안 됨'이 있으면 안 됨: [$first]"
    Expect ($r.Stderr.Contains('마지막대화문구')) "stderr에 lastDialog 없음: [$($r.Stderr)]"
}

Test-Case 'bad_request: 첫 줄 "Error: bad_request — 사유"' {
    $r = Invoke-Case (New-Response @{ status = 'bad_request'; executed = 'no'; result = 'op 미지원: foo' }) @('-Code', 'x')
    Expect-Served $r
    $first = FirstLine $r.Stdout
    Expect ($first -ceq 'Error: bad_request — op 미지원: foo') "첫 줄 불일치: [$first]"
}

Test-Case 'doc_not_found / doc_ambiguous / doc_not_active: 첫 줄 "Error: <status> — <result>"' {
    foreach ($s in @('doc_not_found', 'doc_ambiguous', 'doc_not_active')) {
        $r = Invoke-Case (New-Response @{ status = $s; executed = 'no'; result = "사유 $s" }) @('-Code', 'x')
        Expect-Served $r
        $first = FirstLine $r.Stdout
        Expect ($first -ceq "Error: $s — 사유 $s") "$s 첫 줄 불일치: [$first]"
    }
}

Test-Case 'error: "Error: " + result (이미 Error:로 시작하면 중복 접두 없음), 여러 줄 유지' {
    $r = Invoke-Case (New-Response @{ status = 'error'; result = "NullReferenceException`n   at Foo()" }) @('-Code', 'x')
    Expect-Served $r
    Expect ($r.Stdout -ceq ("Error: NullReferenceException`n   at Foo()" + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    $r2 = Invoke-Case (New-Response @{ status = 'error'; result = 'Error: 트랜잭션 롤백됨 — 벽 겹침' }) @('-Code', 'x')
    Expect-Served $r2
    Expect ((FirstLine $r2.Stdout) -ceq 'Error: 트랜잭션 롤백됨 — 벽 겹침') "중복 접두: [$(FirstLine $r2.Stdout)]"
}

Test-Case 'error: 실패 시 팝업/그룹도 stderr에 보고 (stdout은 Error 첫 줄만 유지)' {
    $resp = New-Response @{
        status = 'error'
        result = '오류 롤백됨'
        group  = 'rolledback-error'
        popups = [ordered]@{ warnings = @(); errors = @([ordered]@{ tx = 'T'; text = '롤백사유PPP' }); dialogs = @() }
    }
    $r = Invoke-Case $resp @('-Code', 'x')
    Expect-Served $r
    Expect ((FirstLine $r.Stdout) -ceq 'Error: 오류 롤백됨') "첫 줄 불일치: [$(FirstLine $r.Stdout)]"
    Expect ($r.Stderr.Contains('롤백사유PPP') -and $r.Stderr.Contains('rolledback-error')) "stderr 보고 누락: [$($r.Stderr)]"
    Expect (-not $r.Stdout.Contains('롤백사유PPP')) "팝업 내용이 stdout에 섞이면 안 됨: [$($r.Stdout)]"
}

# ============================================================================
# 3. 옛 서버
# ============================================================================

Test-Case 'old-server: 평문 응답은 stdout에 원문 그대로 + stderr 안내' {
    $plain = "3`n한글 결과 줄"
    $r = Invoke-Case $plain @('-Code', 'Doc.Title')
    Expect-Served $r
    Expect ($r.Stdout -ceq ($plain + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('구버전 서버 — -Doc/-NoGroup/-Label 무시됨')) "stderr 안내 없음: [$($r.Stderr)]"
}

Test-Case 'old-server: "Error: Timeout after 30s"도 원문 통과, 종료 코드 0' {
    $plain = 'Error: Timeout after 30s'
    $r = Invoke-Case $plain @('-Code', 'x')
    Expect-Served $r
    Expect ($r.Stdout -ceq ($plain + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('구버전 서버')) "stderr 안내 없음: [$($r.Stderr)]"
}

# ============================================================================
# 4. 요청 헤더
# ============================================================================

Test-Case 'header: 기본값 (세션 앞 8자, label=inline, doc=null, timeout=30, group=true) + 코드 본문' {
    $r = Invoke-Case (New-Response) @('-Code', 'Doc.Title')
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.First -cmatch '^//@raa \{"v":2,"op":"run",') "첫 줄 형식(컴팩트 JSON) 불일치: [$($q.First)]"
    Expect ($q.Header.v -eq 2) "v != 2"
    Expect ($q.Header.op -ceq 'run') "op: [$($q.Header.op)]"
    Expect ($q.Header.session -ceq 'abcdef12') "session: [$($q.Header.session)]"
    Expect ($q.Header.label -ceq 'inline') "label: [$($q.Header.label)]"
    Expect (($q.Header.PSObject.Properties.Name -contains 'doc') -and $null -eq $q.Header.doc) "doc는 null로 존재해야 함"
    Expect ($q.Header.timeout -eq 30) "timeout: [$($q.Header.timeout)]"
    Expect ($q.Header.group -eq $true) "group: [$($q.Header.group)]"
    Expect ($q.Code -ceq 'Doc.Title') "코드 본문 불일치: [$($q.Code)]"
}

Test-Case 'header: 세션 ID 없으면 "pid" + 부모 PID(= 이 테스트 프로세스)' {
    $r = Invoke-Case (New-Response) @('-Code', 'x') @{ CLAUDE_CODE_SESSION_ID = $null }
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.session -ceq "pid$PID") "session: [$($q.Header.session)] 기대: pid$PID"
}

Test-Case 'header: 세션 ID가 8자보다 짧으면 그대로' {
    $r = Invoke-Case (New-Response) @('-Code', 'x') @{ CLAUDE_CODE_SESSION_ID = 'ab12' }
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.session -ceq 'ab12') "session: [$($q.Header.session)]"
}

Test-Case 'header: -File -> label=파일명, 코드=파일 내용(BOM 제거)' {
    $content = "// 한글 주석`nreturn Doc.Title;`n"
    $path = Join-Path $tempDir 'my_script.cs'
    [System.IO.File]::WriteAllText($path, $content, $utf8Bom)
    $r = Invoke-Case (New-Response) @('-File', $path)
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.label -ceq 'my_script.cs') "label: [$($q.Header.label)]"
    Expect ($q.Code -ceq $content) "코드 본문 불일치: [$($q.Code)]"
}

Test-Case 'header: -Label이 -File 파일명보다 우선' {
    $path = Join-Path $tempDir 'other.cs'
    [System.IO.File]::WriteAllText($path, 'return 1;', $utf8NoBom)
    $r = Invoke-Case (New-Response) @('-File', $path, '-Label', '내 작업 "A"')
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.label -ceq '내 작업 "A"') "label: [$($q.Header.label)]"
}

Test-Case 'header: -Doc / -NoGroup 전달' {
    $r = Invoke-Case (New-Response) @('-Code', 'x', '-Doc', 'C:\Users\한글\프로젝트1.rvt', '-NoGroup')
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.doc -ceq 'C:\Users\한글\프로젝트1.rvt') "doc: [$($q.Header.doc)]"
    Expect ($q.Header.group -eq $false) "group: [$($q.Header.group)]"
}

# timeout 계산: 표 = @(이름, 클라이언트 인자, 코드 첫 줄 힌트 또는 $null, 기대 timeout)
$timeoutTable = @(
    @('명시 없음 -> 30',                        @(),                          $null,                30),
    @('-Timeout 900000 -> 900',                 @('-Timeout', '900000'),      $null,                900),
    @('-Timeout 900500 -> ceil = 901',          @('-Timeout', '900500'),      $null,                901),
    @('-Timeout 10000 (30 미만) -> 30',         @('-Timeout', '10000'),       $null,                30),
    @('//TIMEOUT:120 -> 120',                   @(),                          '//TIMEOUT:120',      120),
    @('//TIMEOUT:10 (30 미만) -> 30',           @(),                          '//TIMEOUT:10',       30),
    @('//TIMEOUT:1000 + -Timeout 900000 -> 1000', @('-Timeout', '900000'),    '//TIMEOUT:1000',     1000),
    @('//TIMEOUT:100 + -Timeout 900000 -> 900', @('-Timeout', '900000'),      '//TIMEOUT:100',      900),
    @('//TIMEOUT:5000 -> 상한 3600',            @(),                          '//TIMEOUT:5000',     3600),
    @('-Timeout 4000000 -> 상한 3600',          @('-Timeout', '4000000'),     $null,                3600),
    @('//TIMEOUT: 240 (공백) -> 240',           @(),                          '//TIMEOUT: 240',     240)
)
foreach ($row in $timeoutTable) {
    $rowName = $row[0]; $rowArgs = $row[1]; $rowHint = $row[2]; $rowExpect = $row[3]
    Test-Case "header: timeout — $rowName" {
        $code = 'return 1;'
        if ($rowHint) { $code = $rowHint + "`n" + $code }
        $args2 = @('-Code', $code) + $rowArgs
        $r = Invoke-Case (New-Response) $args2
        Expect-Served $r
        $q = Split-Request $r.Request
        Expect ($q.Header.timeout -eq $rowExpect) "timeout: [$($q.Header.timeout)] 기대: $rowExpect"
        if ($rowHint) {
            Expect ($q.Code -ceq $code) "힌트 줄을 포함한 코드가 그대로 전달돼야 함: [$($q.Code)]"
        }
    }
}

Test-Case 'header: -File의 CRLF 첫 줄 //TIMEOUT:200 힌트 인식' {
    $path = Join-Path $tempDir 'crlf.cs'
    [System.IO.File]::WriteAllText($path, "//TIMEOUT:200`r`nreturn 2;`r`n", $utf8NoBom)
    $r = Invoke-Case (New-Response) @('-File', $path)
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.timeout -eq 200) "timeout: [$($q.Header.timeout)]"
}

Test-Case 'header: 힌트는 첫 줄에서만 (둘째 줄의 //TIMEOUT:은 무시)' {
    $r = Invoke-Case (New-Response) @('-Code', "var a = 1;`n//TIMEOUT:500`nreturn a;")
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.timeout -eq 30) "timeout: [$($q.Header.timeout)]"
}

# ============================================================================
# 5. -Status
# ============================================================================

Test-Case '-Status: op=status, 코드 없이 호출, 응답 JSON을 들여써서 stdout에 출력' {
    $resp = New-Response @{
        result       = ''
        running      = [ordered]@{ id = 5; session = 'abcdef12'; label = 'a,b:{c}["d"] 작업'; elapsedMs = 1234 }
        queue        = @([ordered]@{ id = 6; session = 'pid99'; label = 'q1'; waitedMs = 10 }, [ordered]@{ id = 7; session = 'x'; label = 'q2'; waitedMs = 5 })
        modal        = $null
        recentDialogs = @()
    }
    $r = Invoke-Case $resp @('-Status')
    Expect-Served $r
    $q = Split-Request $r.Request
    Expect ($q.Header.op -ceq 'status') "op: [$($q.Header.op)]"
    Expect ($q.Code -ceq '') "status 요청에 코드가 있으면 안 됨: [$($q.Code)]"
    Expect ($r.Stderr -eq '') "stderr가 비어 있어야 함: [$($r.Stderr)]"
    $lines = $r.Stdout -split "`r?`n"
    Expect ($lines.Count -gt 10) "여러 줄로 출력돼야 함 (줄 수 $($lines.Count))"
    Expect ($lines[0] -ceq '{') "첫 줄은 '{' 이어야 함: [$($lines[0])]"
    Expect ($r.Stdout.Contains('  "status": "ok"')) "들여쓴 status 줄 없음"
    Expect ($r.Stdout.Contains('  "queue": [')) "들여쓴 queue 줄 없음"
    Expect ($r.Stdout.Contains('"recentDialogs": []')) "빈 배열은 한 줄이어야 함"
    $back = $r.Stdout | ConvertFrom-Json
    Expect ($back.status -ceq 'ok') "되읽은 status: [$($back.status)]"
    Expect ($back.running.label -ceq 'a,b:{c}["d"] 작업') "문자열 안의 구두점 보존 실패: [$($back.running.label)]"
    Expect ($back.running.elapsedMs -eq 1234) "elapsedMs: [$($back.running.elapsedMs)]"
    Expect (@($back.queue).Count -eq 2 -and $back.queue[1].label -ceq 'q2') "queue 되읽기 실패"
    Expect ($null -eq $back.modal) "modal은 null"
}

Test-Case '-Status + 옛 서버: 원문 + 안내 (코드 없이도 종료 코드 0)' {
    $r = Invoke-Case '(옛 서버 응답)' @('-Status')
    Expect-Served $r
    Expect ($r.Stdout -ceq ("(옛 서버 응답)" + "`r`n")) "stdout 불일치: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('구버전 서버')) "stderr 안내 없음"
}

# ============================================================================
# 6. 종료 코드 / 오류 경로
# ============================================================================

Test-Case '사용법 오류(코드·파일 없음): 종료 코드 1, 서버 연결 없음' {
    $r = Invoke-Client @() ('raa-test-none-' + [Guid]::NewGuid().ToString('N')) @{} 30000
    Expect ($r.ExitCode -eq 1) "종료 코드 1 기대, 실제 $($r.ExitCode)"
    Expect ($r.Stdout -eq '') "stdout은 비어 있어야 함: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('Usage')) "stderr에 Usage 없음: [$($r.Stderr)]"
}

Test-Case '연결 실패(파이프 없음): 5초 뒤 종료 코드 2' {
    $r = Invoke-Client @('-Code', 'x') ('raa-test-none-' + [Guid]::NewGuid().ToString('N')) @{} 60000
    Expect ($r.ExitCode -eq 2) "종료 코드 2 기대, 실제 $($r.ExitCode)"
    Expect ($r.Stdout -eq '') "stdout은 비어 있어야 함: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('Revit에 연결할 수 없습니다')) "stderr 문구 없음: [$($r.Stderr)]"
    Expect ($r.ElapsedMs -ge 4500) "5초 연결 제한을 기다렸어야 함 (경과 $($r.ElapsedMs) ms)"
}

Test-Case '서버가 응답 없이 연결을 닫음: 종료 코드 3 (무한 대기 아님)' {
    $r = Invoke-Case $null @('-Code', 'x') @{ CLAUDE_CODE_SESSION_ID = 'abcdef1234567890' } 0
    Expect ($r.ExitCode -eq 3) "종료 코드 3 기대, 실제 $($r.ExitCode) / stderr: $($r.Stderr)"
    Expect ($r.Stdout -eq '') "stdout은 비어 있어야 함: [$($r.Stdout)]"
    Expect ($r.Stderr.Contains('오류')) "stderr에 오류 문구 없음: [$($r.Stderr)]"
}

Test-Case '깨진 v2 JSON: 종료 코드 3, stdout 비어 있음' {
    $r = Invoke-Case '{"v":2,"status":"ok","result":' @('-Code', 'x')
    Expect ($r.ExitCode -eq 3) "종료 코드 3 기대, 실제 $($r.ExitCode) / stderr: $($r.Stderr)"
    Expect ($r.Stdout -eq '') "stdout은 비어 있어야 함: [$($r.Stdout)]"
}

# 프로세스 안에서 `& revit-cli.ps1`로 부르는 호출처(파이프라인 값으로 받는 방식) 호환
Test-Case 'in-process 호출: 파이프라인 출력은 result 문자열 하나뿐' {
    $name = 'raa-test-' + [Guid]::NewGuid().ToString('N')
    $oldSid = $env:CLAUDE_CODE_SESSION_ID
    $env:CLAUDE_CODE_SESSION_ID = 'abcdef1234567890'
    $h = Start-FakeServer $name ($utf8NoBom.GetBytes((New-Response @{ result = "인프로세스`n결과" }))) 0
    try {
        $out = & $client -Code 'x' -PipeName $name
        $code = $LASTEXITCODE
    } finally {
        [void](Complete-FakeServer $h)
        $env:CLAUDE_CODE_SESSION_ID = $oldSid
    }
    Expect ($code -eq 0) "종료 코드: $code"
    Expect (@($out).Count -eq 1) "출력 개수 1 기대, 실제 $(@($out).Count): [$($out -join '|')]"
    Expect ($out -ceq "인프로세스`n결과") "출력 불일치: [$out]"
}

# ============================================================================
# 7. 느린 케이스 (선택)
# ============================================================================

if ($IncludeSlow) {
    Test-Case '읽기 마감: 서버가 요청을 받고 무응답이면 timeout+10초(=40초) 뒤 종료 코드 3' {
        $r = Invoke-Case $null @('-Code', 'x') @{ CLAUDE_CODE_SESSION_ID = 'abcdef1234567890' } 55000 80000
        Expect ($r.ExitCode -eq 3) "종료 코드 3 기대, 실제 $($r.ExitCode) / stderr: $($r.Stderr)"
        Expect ($r.Stderr.Contains('시간 초과')) "stderr에 시간 초과 문구 없음: [$($r.Stderr)]"
        Expect ($r.ElapsedMs -ge 39000 -and $r.ElapsedMs -le 50000) "40초 근처에서 끝나야 함 (경과 $($r.ElapsedMs) ms)"
    }
} else {
    Write-Host 'SKIP  읽기 마감(40초) 케이스 — -IncludeSlow 로 실행'
}

# ----------------------------------------------------------------------------
# 정리 / 요약
# ----------------------------------------------------------------------------

try { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host "결과: PASS $($script:passed) / FAIL $($script:failed)"
if ($script:failed -gt 0) { exit 1 }
exit 0
