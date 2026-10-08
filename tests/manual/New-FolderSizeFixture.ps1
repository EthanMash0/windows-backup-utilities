<#
Builds the folder trees used by tests/manual/FolderSizeChecklist.md.

Run from an elevated Windows PowerShell 5.1 window (symbolic links need
administrator rights):

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\manual\New-FolderSizeFixture.ps1

Run it again with -Remove to restore permissions and delete everything.

    <Root>\src        source tree with every case below
    <Root>\bak        backup tree that differs from src in known ways
    <Root>\same_a     two identical trees, for the "match" verdict
    <Root>\same_b
    <Root>\readonly_logs   a folder you cannot write to, for the log fallback
#>
param(
	[string]$Root = 'C:\Temp\fs_fixture',
	[switch]$Remove
)

$ErrorActionPreference = 'Stop'
$user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

function Get-LongPath {
	param([string]$Path)
	return '\\?\' + $Path
}

function New-FixtureFile {
	param(
		[string]$Path,
		[long]$Bytes,
		[byte]$Fill = 97
	)

	$long = Get-LongPath $Path
	[void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($long))
	$data = New-Object byte[] $Bytes
	for ($i = 0; $i -lt $Bytes; $i++) { $data[$i] = $Fill }
	[System.IO.File]::WriteAllBytes($long, $data)
}

function New-FixtureFolder {
	param([string]$Path)
	[void][System.IO.Directory]::CreateDirectory((Get-LongPath $Path))
}

function Invoke-Native {
	param([string]$File, [string[]]$Arguments)
	$output = & $File @Arguments 2>&1
	if ($LASTEXITCODE -ne 0) { throw ('{0} {1} failed: {2}' -f $File, ($Arguments -join ' '), ($output -join ' ')) }
}

if ($Remove) {
	foreach ($denied in @((Join-Path $Root 'src\denied'), (Join-Path $Root 'readonly_logs'))) {
		if (Test-Path -LiteralPath $denied) { Invoke-Native icacls.exe @($denied, '/remove:d', $user, '/T', '/C', '/Q') }
	}
	if (Test-Path -LiteralPath $Root) {
		# rmdir /s deletes a junction or symlink without following it, and
		# handles the long path.
		Invoke-Native cmd.exe @('/c', 'rmdir', '/s', '/q', (Get-LongPath $Root))
	}
	Write-Host ('Removed {0}' -f $Root)
	return
}

if (Test-Path -LiteralPath $Root) {
	throw ('{0} already exists. Run this script with -Remove first.' -f $Root)
}

$src = Join-Path $Root 'src'
$bak = Join-Path $Root 'bak'

# Files in both trees with the same size.
foreach ($tree in @($src, $bak)) {
	New-FixtureFile (Join-Path $tree 'docs\same.txt') 10
	New-FixtureFile (Join-Path $tree 'compressed\big.txt') 1048576
	New-FixtureFile (Join-Path $tree 'sparse\sparse.bin') 0
}

# Differences in docs: one file on each side only, one file with a different size.
New-FixtureFile (Join-Path $src 'docs\only-in-source.txt') 20
New-FixtureFile (Join-Path $bak 'docs\only-in-backup.txt') 30
New-FixtureFile (Join-Path $src 'docs\different-size.txt') 100
New-FixtureFile (Join-Path $bak 'docs\different-size.txt') 200

# An empty folder only in the source.
New-FixtureFolder (Join-Path $src 'EmptyOnlyInSource')

# A path well over 260 characters. The folder also holds a matching file so
# the mismatch is listed as the file itself, with its full path.
$segments = 1..12 | ForEach-Object { 'Segment{0:00} with a long descriptive folder name' -f $_ }
$deep = 'long\' + ($segments -join '\')
foreach ($tree in @($src, $bak)) { New-FixtureFile (Join-Path $tree ($deep + '\deep-same.txt')) 5 }
New-FixtureFile (Join-Path $src ($deep + '\deep-different.txt')) 50
New-FixtureFile (Join-Path $bak ($deep + '\deep-different.txt')) 60

# Non-ASCII and C1 control characters in names, built from code points so
# this file stays ASCII for Windows PowerShell 5.1.
$accented = 'caf' + [char]0x00E9 + ' ' + [char]0x65E5 + [char]0x672C
$c1 = 'c1-' + [char]0x0085 + '-' + [char]0x009B + '-name'
foreach ($tree in @($src, $bak)) { New-FixtureFile (Join-Path $tree ('names\same-' + $accented + '.txt')) 7 }
New-FixtureFile (Join-Path $src ('names\only-' + $accented + '.txt')) 8
New-FixtureFile (Join-Path $src ('names\only-' + $c1 + '.txt')) 9

# Names that differ only in case match each other.
New-FixtureFile (Join-Path $src 'Case\Report.TXT') 11
New-FixtureFile (Join-Path $bak 'case\report.txt') 11

# Stored size smaller than logical size in the source only.
Invoke-Native compact.exe @('/c', '/q', (Join-Path $src 'compressed\big.txt'))
$sparsePath = Join-Path $src 'sparse\sparse.bin'
Invoke-Native fsutil.exe @('sparse', 'setflag', $sparsePath)
foreach ($tree in @($src, $bak)) {
	$stream = [System.IO.File]::Open((Join-Path $tree 'sparse\sparse.bin'), 'Open', 'ReadWrite')
	try { $stream.SetLength(10MB) } finally { $stream.Close() }
}

# Reparse points in the source only. Both are skipped, like robocopy /XJ.
Invoke-Native cmd.exe @('/c', 'mklink', '/J', (Join-Path $src 'junction'), (Join-Path $src 'docs'))
[void](New-Item -ItemType SymbolicLink -Path (Join-Path $src 'link.txt') -Target (Join-Path $src 'docs\same.txt'))

# A folder the current user cannot list.
New-FixtureFile (Join-Path $src 'denied\secret.txt') 12
Invoke-Native icacls.exe @((Join-Path $src 'denied'), '/deny', ('{0}:(RD)' -f $user))

# Two identical trees.
foreach ($tree in @((Join-Path $Root 'same_a'), (Join-Path $Root 'same_b'))) {
	New-FixtureFile (Join-Path $tree 'a.txt') 10
	New-FixtureFile (Join-Path $tree 'sub\b.txt') 20
	New-FixtureFolder (Join-Path $tree 'empty')
}

# A log folder the current user cannot write to.
$readonlyLogs = Join-Path $Root 'readonly_logs'
New-FixtureFolder $readonlyLogs
Invoke-Native icacls.exe @($readonlyLogs, '/deny', ('{0}:(W,AD)' -f $user))

Write-Host ('Created {0}' -f $Root)
Write-Host ('  src            {0}' -f $src)
Write-Host ('  bak            {0}' -f $bak)
Write-Host ('  same_a/same_b  {0}' -f (Join-Path $Root 'same_a'))
Write-Host ('  readonly_logs  {0}' -f $readonlyLogs)
Write-Host ('Deep mismatch path length: {0}' -f (Join-Path $src ($deep + '\deep-different.txt')).Length)
