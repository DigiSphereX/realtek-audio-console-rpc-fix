# parse-check.ps1 - validate every PowerShell file in src/ (GitLab CI + local use).
# Exits 1 if any file has a parse error, 0 otherwise.

$ErrorActionPreference = 'Stop'
$failed = $false
$srcDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'src'
$files = Get-ChildItem -Path $srcDir -Filter '*.ps1' -File | Sort-Object Name

if (-not $files) {
    Write-Error 'No PowerShell files found in src/.'
    exit 1
}

foreach ($file in $files) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $failed = $true
        foreach ($e in $errors) {
            Write-Host ("FAIL {0}:{1} {2}" -f $file.Name, $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Host ("OK   {0}" -f $file.Name)
    }
}

if ($failed) { exit 1 }
Write-Host 'Parse OK'
exit 0
