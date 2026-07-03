# tests/StdinTimeout.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\StdinTimeout.ps1')

Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public class CcodexTestStream : Stream
{
    private readonly Queue<Tuple<byte[], int>> _chunks;
    public CcodexTestStream(IEnumerable<Tuple<byte[], int>> chunks)
    {
        _chunks = new Queue<Tuple<byte[], int>>(chunks);
    }
    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        if (_chunks.Count == 0) return 0;
        var chunk = _chunks.Dequeue();
        if (chunk.Item2 > 0) await Task.Delay(chunk.Item2, cancellationToken);
        Array.Copy(chunk.Item1, 0, buffer, offset, chunk.Item1.Length);
        return chunk.Item1.Length;
    }
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
"@

function New-CcodexChunk([byte[]]$Bytes, [int]$DelayMs = 0) {
    return [Tuple[byte[], int]]::new($Bytes, $DelayMs)
}

$utf8 = New-Object System.Text.UTF8Encoding($false)

Write-Host "reads data then EOF within timeouts"
$chunks = @(
    (New-CcodexChunk $utf8.GetBytes('hello ') 0),
    (New-CcodexChunk $utf8.GetBytes('world') 50),
    (New-CcodexChunk ([byte[]]@()) 0)
)
$stream = [CcodexTestStream]::new([Tuple[byte[],int][]]$chunks)
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result 'hello world' 'concatenates chunks and stops at EOF'

Write-Host "preserves Traditional Chinese text exactly"
$zhText = '請審查這份規格文件'
$chunks = @((New-CcodexChunk $utf8.GetBytes($zhText) 0), (New-CcodexChunk ([byte[]]@()) 0))
$stream = [CcodexTestStream]::new([Tuple[byte[],int][]]$chunks)
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result $zhText 'decodes UTF-8 Traditional Chinese text exactly'

Write-Host "strips a UTF-8 BOM if present"
$bom = [byte[]]@(0xEF, 0xBB, 0xBF)
$chunks = @((New-CcodexChunk ($bom + $utf8.GetBytes('bom test')) 0), (New-CcodexChunk ([byte[]]@()) 0))
$stream = [CcodexTestStream]::new([Tuple[byte[],int][]]$chunks)
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result 'bom test' 'strips leading UTF-8 BOM before decoding'

Write-Host "empty stdin (immediate EOF) returns empty string, not an error"
$stream = [CcodexTestStream]::new([Tuple[byte[],int][]]@((New-CcodexChunk ([byte[]]@()) 0)))
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result '' 'immediate EOF yields empty string'

Write-Host "first-byte timeout when nothing arrives in time"
$chunks = @((New-CcodexChunk $utf8.GetBytes('late') 600))
$stream = [CcodexTestStream]::new([Tuple[byte[],int][]]$chunks)
Assert-Throws { Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 200 -NoProgressTimeoutMs 200 } 'throws when first byte/EOF does not arrive within the timeout'

Write-Host "no-progress timeout after some data has already arrived"
$chunks = @((New-CcodexChunk $utf8.GetBytes('start') 0), (New-CcodexChunk $utf8.GetBytes('late') 600))
$stream = [CcodexTestStream]::new([Tuple[byte[],int][]]$chunks)
Assert-Throws { Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 200 -NoProgressTimeoutMs 200 } 'throws when a later chunk stalls past the no-progress timeout'

Complete-CcodexTests
