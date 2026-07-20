# Suite runner for the plain-PowerShell assertion tests (no Pester — deliberate).
#
#   pwsh -NoProfile -File tests/run-tests.ps1                # quick suite (inner dev loop)
#   pwsh -NoProfile -File tests/run-tests.ps1 -Suite full    # everything (gate before finishing)
#
# quick skips the shell-level/E2E files that spawn many child pwsh processes (minutes each on a
# loaded machine) and keeps the function-level tests that cover lib/ logic. The skip list is
# printed on every quick run — nothing is skipped silently. Exit code = number of failed files.
param(
    [ValidateSet('quick', 'full')][string]$Suite = 'quick',
    [string]$TestsPath = $PSScriptRoot,
    # Files worth running only in the full suite: dominated by child-process spawning
    # (shell-level `pwsh -File ccodex.ps1` round-trips, detached workers, E2E chains), not by
    # assertion count. Re-derive with the timing loop in dev-notes "Running the tests" if the
    # suite's shape changes.
    [string[]]$SlowFiles = @(
        'AsyncE2E.tests.ps1',
        'CancelCommand.tests.ps1',
        'Characterization.tests.ps1',
        'Cleanup.tests.ps1',
        'DiffApply.tests.ps1',
        'Doctor.tests.ps1',
        'ImplementE2E.tests.ps1',
        'RealInvocation.tests.ps1',
        'Resume.tests.ps1',
        'ReviewCommand.tests.ps1',
        'RunCommand.tests.ps1',
        'RunTests.tests.ps1',
        'SubmitCommand.tests.ps1'
    )
)

$all = Get-ChildItem -LiteralPath $TestsPath -Filter *.tests.ps1 | Sort-Object Name
$skipped = @()
$toRun = @()
foreach ($file in $all) {
    if ($Suite -eq 'quick' -and $SlowFiles -contains $file.Name) { $skipped += $file.Name }
    else { $toRun += $file }
}

$failed = 0
$total = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($file in $toRun) {
    $output = $null
    # Help.tests.ps1 keeps its pure lib/ assertions in the quick suite and gates only its
    # child-process dispatch matrix behind this full-suite switch. That preserves fast coverage
    # without silently dropping the shell-level cases from the completion gate.
    if ($Suite -eq 'full' -and $file.Name -eq 'Help.tests.ps1') {
        $elapsed = Measure-Command { $output = & pwsh -NoLogo -NoProfile -File $file.FullName -IncludeDispatch 2>&1 }
    } else {
        $elapsed = Measure-Command { $output = & pwsh -NoLogo -NoProfile -File $file.FullName 2>&1 }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  PASS {0} ({1:n1}s)" -f $file.Name, $elapsed.TotalSeconds)
    } else {
        $failed++
        Write-Host ("  FAIL {0} (exit {1}, {2:n1}s)" -f $file.Name, $LASTEXITCODE, $elapsed.TotalSeconds)
        # Echo the failing file's captured output (tail-bounded) so intermittent in-suite
        # failures self-document — a suppressed flake is undiagnosable after the fact.
        $tail = @($output | ForEach-Object { "$_" }) | Select-Object -Last 60
        $tail | ForEach-Object { Write-Host ("    | {0}" -f $_) }
    }
}
$total.Stop()

if ($skipped.Count -gt 0) {
    Write-Host ("skipped (slow, full-suite only): {0}" -f ($skipped -join ', '))
}
Write-Host ("{0} test file(s) failed ({1} run, {2} skipped, {3:n0}s total, suite={4})" -f `
    $failed, $toRun.Count, $skipped.Count, $total.Elapsed.TotalSeconds, $Suite)
exit $failed
