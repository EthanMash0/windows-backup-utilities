# Runs the real scan worker against a temporary folder tree. On Windows it
# uses the real native type. Elsewhere a managed stand-in replaces it, and the
# worker gets a model copy whose long-path helpers accept Unix paths:
#   - a name containing "sparse" is stored as 0 bytes
#   - a reparse point whose name ends in "-cloud" reports a cloud tag (walked)
#   - every other reparse point reports a symlink tag (skipped)

BeforeDiscovery {
	$script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
}

BeforeAll {
	. (Join-Path $PSScriptRoot 'TestSetup.ps1')

	$script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
	if (-not $script:OnWindows -and $null -eq ('FolderSizeNative' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class FolderSizeNative {
	public static ulong StoredSize(string path) {
		if (Path.GetFileName(path).Contains("sparse")) return 0;
		return (ulong)new FileInfo(path).Length;
	}

	public static uint ReparseTag(string path) {
		if (path.TrimEnd('/').EndsWith("-cloud")) return 0x9000001A;
		return 0xA000000C;
	}

	public static string SkippedReparseKind(uint tag) {
		if (tag == 0xA000000C) return "symlink";
		if (tag == 0xA0000003) return "junction or mount point";
		return null;
	}
}
'@
	}

	$script:SavedLibRoot = $script:FolderSizeLibRoot
	$script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('fs-scan-test-' + [guid]::NewGuid().ToString('N'))
	[void][System.IO.Directory]::CreateDirectory($script:Work)
	if (-not $script:OnWindows) {
		$libCopy = Join-Path $script:Work 'lib'
		[void][System.IO.Directory]::CreateDirectory($libCopy)
		$model = [System.IO.File]::ReadAllText((Join-Path $script:LibRoot 'FolderSizeModel.ps1'))
		$model += @'

function ConvertTo-FolderSizeLongPath {
	param([string]$Path)
	return $Path
}

function Get-FolderSizeComparablePath {
	param([string]$Path)
	return $Path.Replace('/', '\')
}
'@
		[System.IO.File]::WriteAllText((Join-Path $libCopy 'FolderSizeModel.ps1'), $model)
		$script:FolderSizeLibRoot = $libCopy
	}

	function New-TestFile {
		param([string]$Path, [int]$Bytes)
		[void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
		[System.IO.File]::WriteAllBytes($Path, [byte[]]::new($Bytes))
	}

	function Invoke-TestScan {
		param([string]$Path, [switch]$CollectFiles)
		$scans = [ordered]@{}
		try {
			$scans.Source = Start-FolderSizeScan -Path $Path -CollectFiles:$CollectFiles
			$progress = @{ Source = $null }
			Wait-FolderSizeScans -Scans $scans -Progress $progress
			return (Complete-FolderSizeScans -Scans $scans).Source
		}
		finally { Stop-FolderSizeScans $scans }
	}

	$script:Tree = Join-Path $script:Work 'src'
	New-TestFile (Join-Path $script:Tree 'a.txt') 10
	New-TestFile (Join-Path $script:Tree 'sub/b.txt') 20
	New-TestFile (Join-Path $script:Tree 'sub/sparse.bin') 100
	[void][System.IO.Directory]::CreateDirectory((Join-Path $script:Tree 'Empty'))
	New-TestFile (Join-Path $script:Work 'outside/c.txt') 5
	if (-not $script:OnWindows) {
		[void](New-Item -ItemType SymbolicLink -Path (Join-Path $script:Tree 'link') -Target (Join-Path $script:Tree 'sub'))
		[void](New-Item -ItemType SymbolicLink -Path (Join-Path $script:Tree 'data-cloud') -Target (Join-Path $script:Work 'outside'))
		$script:Denied = Join-Path $script:Tree 'denied'
		New-TestFile (Join-Path $script:Denied 'hidden.txt') 1
		chmod 000 $script:Denied
	}
}

AfterAll {
	if ($script:Denied) { chmod 755 $script:Denied }
	$script:FolderSizeLibRoot = $script:SavedLibRoot
	Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Folder scan worker' {
	BeforeEach {
		Reset-UiScreen
		Mock Update-UiScreen { }
	}

	It 'totals ordinary files and records every folder' {
		$result = Invoke-TestScan -Path $script:Tree -CollectFiles
		$result.Files | Should -BeGreaterOrEqual 3
		$result.FilesByPath['a.txt'] | Should -Be 10
		$result.FilesByPath['SUB\B.TXT'] | Should -Be 20
		$result.Directories.ContainsKey('Empty') | Should -BeTrue
		$result.Directories.ContainsKey('sub') | Should -BeTrue
	}
	It 'reports a sparse file as stored smaller than its logical size' -Skip:$script:OnWindows {
		$result = Invoke-TestScan -Path $script:Tree
		$result.Logical | Should -Be 135
		$result.Stored | Should -Be 35
		$entries = Get-FolderSizeRollup -DirectoryStats $result.DirectoryStats -Differences $result.Differences
		$entries.RelativePath | Should -Be @('sub\sparse.bin')
	}
	It 'skips a symlink and records its kind' -Skip:$script:OnWindows {
		$result = Invoke-TestScan -Path $script:Tree -CollectFiles
		@($result.Reparse | Where-Object { $_.RelativePath -eq 'link' -and $_.Kind -eq 'symlink' }).Count | Should -Be 1
		$result.Directories.ContainsKey('link') | Should -BeFalse
	}
	It 'walks into a cloud placeholder folder' -Skip:$script:OnWindows {
		$result = Invoke-TestScan -Path $script:Tree -CollectFiles
		$result.FilesByPath['data-cloud\c.txt'] | Should -Be 5
		$result.Directories.ContainsKey('data-cloud') | Should -BeTrue
	}
	It 'records a folder it cannot list with the error and keeps going' -Skip:$script:OnWindows {
		$result = Invoke-TestScan -Path $script:Tree -CollectFiles
		$denied = @($result.Unreadable | Where-Object { $_.RelativePath -eq 'denied' })
		$denied.Count | Should -Be 1
		$denied[0].Error | Should -Not -BeNullOrEmpty
		$result.Directories.ContainsKey('denied') | Should -BeTrue
		$result.FilesByPath['a.txt'] | Should -Be 10
	}
	It 'reports a root that is a file as not a folder' {
		$result = Invoke-TestScan -Path (Join-Path $script:Tree 'a.txt')
		$result.Files | Should -Be 0
		$result.Unreadable.Count | Should -Be 1
		$result.Unreadable[0].RelativePath | Should -BeExactly ''
		$result.Unreadable[0].Error | Should -BeExactly 'The path is not a folder.'
	}
	It 'reports a missing root as unreadable instead of failing' {
		$result = Invoke-TestScan -Path (Join-Path $script:Work 'does-not-exist')
		$result.Unreadable.Count | Should -Be 1
		$result.Unreadable[0].Error | Should -Not -BeNullOrEmpty
	}
	It 'publishes the final snapshot to the progress table' {
		$scans = [ordered]@{}
		try {
			$scans.Source = Start-FolderSizeScan -Path $script:Tree
			$progress = @{ Source = $null }
			Wait-FolderSizeScans -Scans $scans -Progress $progress
			$result = (Complete-FolderSizeScans -Scans $scans).Source
		}
		finally { Stop-FolderSizeScans $scans }
		$progress.Source.Files | Should -Be $result.Files
		$progress.Source.Logical | Should -Be $result.Logical
	}
	It 'returns one result per scan for a comparison' {
		$scans = [ordered]@{}
		try {
			$scans.Source = Start-FolderSizeScan -Path $script:Tree -CollectFiles
			$scans.Backup = Start-FolderSizeScan -Path (Join-Path $script:Work 'outside') -CollectFiles
			$progress = @{ Source = $null; Backup = $null }
			Wait-FolderSizeScans -Scans $scans -Progress $progress
			$results = Complete-FolderSizeScans -Scans $scans
		}
		finally { Stop-FolderSizeScans $scans }
		$results.Backup.FilesByPath['c.txt'] | Should -Be 5
		$results.Source.FilesByPath['a.txt'] | Should -Be 10
	}
}
