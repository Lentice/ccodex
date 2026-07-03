# lib/StdinTimeout.ps1
function Read-CcodexStdinWithTimeout {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$FirstByteTimeoutMs,
        [Parameter(Mandatory)][int]$NoProgressTimeoutMs
    )

    $buffer = [byte[]]::new(8192)
    $memory = New-Object System.IO.MemoryStream
    $sawAnyByte = $false

    while ($true) {
        $timeoutMs = if ($sawAnyByte) { $NoProgressTimeoutMs } else { $FirstByteTimeoutMs }
        $readTask = $Stream.ReadAsync($buffer, 0, $buffer.Length)
        if (-not $readTask.Wait($timeoutMs)) {
            if (-not $sawAnyByte) {
                throw "ccodex: redirected stdin produced neither data nor EOF within ${FirstByteTimeoutMs}ms. Pass --prompt-file or positional task text instead."
            } else {
                throw "ccodex: redirected stdin stalled for more than ${NoProgressTimeoutMs}ms without new data. Pass --prompt-file or positional task text instead."
            }
        }
        $bytesRead = $readTask.GetAwaiter().GetResult()
        if ($bytesRead -eq 0) {
            break
        }
        $sawAnyByte = $true
        $memory.Write($buffer, 0, $bytesRead)
    }

    $bytes = $memory.ToArray()
    if ($bytes.Length -eq 0) {
        return ''
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return $encoding.GetString($bytes)
}
