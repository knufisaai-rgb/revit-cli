# revit-cli.ps1 — Revit Named Pipe CLI (MCP 대체)
# 사용법:
#   powershell -File revit-cli.ps1 -Code "Doc.Title"
#   powershell -File revit-cli.ps1 -File "C:\temp\script.cs"

param(
    [string]$Code,
    [string]$File,
    [int]$Timeout = 35000
)

# UTF-8 출력
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 코드 결정: -File이 있으면 파일에서 읽기, 아니면 -Code 사용
if ($File -and (Test-Path $File)) {
    $Code = Get-Content -Path $File -Raw -Encoding UTF8
}

if (-not $Code) {
    Write-Error "Usage: revit-cli.ps1 -Code 'Doc.Title' or -File 'script.cs'"
    exit 1
}

try {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'RevitAIAgent', [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $pipe.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message

    # 코드 전송
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Code)
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
    $pipe.WaitForPipeDrain()

    # 결과 수신
    $buffer = New-Object byte[] 65536
    $ms = New-Object System.IO.MemoryStream
    do {
        $read = $pipe.Read($buffer, 0, $buffer.Length)
        $ms.Write($buffer, 0, $read)
    } while (-not $pipe.IsMessageComplete)

    $result = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    Write-Output $result
}
catch [TimeoutException] {
    Write-Error "Revit에 연결할 수 없습니다. Revit이 실행 중인지 확인하세요."
    exit 2
}
catch {
    Write-Error "오류: $($_.Exception.Message)"
    exit 3
}
finally {
    if ($pipe) { $pipe.Dispose() }
    if ($ms) { $ms.Dispose() }
}
