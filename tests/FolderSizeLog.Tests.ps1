BeforeAll {
	. (Join-Path $PSScriptRoot 'TestSetup.ps1')

	$script:Esc = [string][char]27
	$script:DeepFolder = 'Projects\' + ((1..12 | ForEach-Object { 'Segment{0:00} with a long descriptive name' -f $_ }) -join '\')
	$script:DeepFile = $script:DeepFolder + '\final quarterly report.docx'
	$script:C1Name = 'odd' + [char]0x85 + 'name' + [char]0x9B + '.txt'

	function New-TestLongReport {
		$source = New-TestScanResult -Files @(
			@($script:DeepFile, 1000, 1000),
			@(($script:DeepFolder + '\same.txt'), 5, 5),
			@(('Odd\' + $script:C1Name), 7, 7),
			@('Cloud\placeholder.bin', 4096, 0)
		) -Unreadable @(
			@{ RelativePath = 'Locked\Inner'; Error = 'Access to the path is denied.' }
		) -Reparse @(
			@{ RelativePath = 'Shortcuts\Link'; Kind = 'symlink' },
			@{ RelativePath = 'Mounts\Drive'; Kind = 'junction or mount point' }
		) -EmptyDirectories @('Cloud\Empty')
		$backup = New-TestScanResult -Files @(
			@($script:DeepFile, 2000, 2000),
			@(($script:DeepFolder + '\same.txt'), 5, 5),
			@('Cloud\placeholder.bin', 4096, 4096)
		) -Unreadable @(
			@{ RelativePath = 'Other'; Error = 'The network name is no longer available.' }
		)
		return New-TestCompareReport -Source 'D:\Users\student' -Dest 'Z:\Backups\student' -SourceResult $source -BackupResult $backup
	}
}

Describe 'Format-FolderCompareLogLines' {
	BeforeEach {
		$script:SavedUseVt = $global:UiState.UseVt
		$global:UiState.UseVt = $true
	}
	AfterEach {
		$global:UiState.UseVt = $script:SavedUseVt
	}

	It 'writes both absolute paths of a deep mismatch without shortening them' {
		$lines = Format-FolderCompareLogLines -Report (New-TestLongReport)
		$sourcePath = 'D:\Users\student\' + $script:DeepFile
		$backupPath = 'Z:\Backups\student\' + $script:DeepFile
		$sourcePath.Length | Should -BeGreaterThan 300
		($lines | Where-Object { $_.EndsWith($sourcePath) }).Count | Should -Be 1
		($lines | Where-Object { $_.EndsWith($backupPath) }).Count | Should -Be 1
		($lines -join "`n") | Should -Not -Match '\.\.\.'
	}
	It 'contains no escape codes even when the console uses color' {
		$text = (Format-FolderCompareLogLines -Report (New-TestLongReport)) -join "`n"
		$text.Contains($script:Esc) | Should -BeFalse
	}
	It 'keeps C1 control characters in names' {
		$text = (Format-FolderCompareLogLines -Report (New-TestLongReport)) -join "`n"
		$text.Contains('D:\Users\student\Odd') | Should -BeTrue
		$lines = Format-FolderSizeLogCrossLines -SourceRoot 'D:\s' -BackupRoot 'Z:\b' -Entries @(
			(New-CrossTreeEntry -RelativePath ('Odd\' + $script:C1Name) -State 'OnlyInSource' -FileCount 1 -SourceLogical 7 -DestLogical 0)
		)
		($lines -join "`n").Contains('D:\s\Odd\' + $script:C1Name) | Should -BeTrue
	}
	It 'lists every unreadable path with its error and every reparse point with its kind' {
		$lines = Format-FolderCompareLogLines -Report (New-TestLongReport)
		$text = $lines -join "`n"
		$text | Should -Match ([regex]::Escape('  D:\Users\student\Locked\Inner'))
		$text | Should -Match 'Error:\s+Access to the path is denied\.'
		$text | Should -Match ([regex]::Escape('  Z:\Backups\student\Other'))
		$text | Should -Match 'Error:\s+The network name is no longer available\.'
		$text | Should -Match ([regex]::Escape('  D:\Users\student\Shortcuts\Link'))
		$text | Should -Match 'Kind:\s+symlink'
		$text | Should -Match 'Kind:\s+junction or mount point'
	}
	It 'lists an empty folder that exists only in the source' {
		$text = (Format-FolderCompareLogLines -Report (New-TestLongReport)) -join "`n"
		$text | Should -Match ([regex]::Escape('  D:\Users\student\Cloud\Empty') + '\s+Files:\s+0 \(empty folder\)')
	}
	It 'keeps the detail sections in the log in order' {
		$lines = Format-FolderCompareLogLines -Report (New-TestLongReport)
		$titles = @($lines | Where-Object { $_ -match '^(Result|Totals|Cross-tree|Source logical|Backup logical|Unreadable|Reparse)' } | ForEach-Object { ($_ -replace ' \(\d+\)$', '') })
		$titles | Should -Be @(
			'Result'
			'Totals'
			'Cross-tree: only in source'
			'Cross-tree: only in backup'
			'Cross-tree: logical size mismatch'
			'Source logical vs stored'
			'Backup logical vs stored'
			'Unreadable: source'
			'Unreadable: backup'
			'Reparse points skipped: source'
			'Reparse points skipped: backup'
		)
	}
	It 'writes the header with timestamps and both roots' {
		$lines = Format-FolderCompareLogLines -Report (New-TestLongReport)
		$lines[0] | Should -BeExactly 'Folder Size Comparison'
		$lines[1] | Should -BeExactly 'Started:         2026-01-02 03:04:05'
		$lines[2] | Should -BeExactly 'Finished:        2026-01-02 03:09:10'
		$lines[3] | Should -BeExactly 'Source:          D:\Users\student'
		$lines[4] | Should -BeExactly 'Backup:          Z:\Backups\student'
	}
}

Describe 'Format-FolderSizeLogPath' {
	It 'names the root itself instead of printing an empty path' {
		Format-FolderSizeLogPath -Root 'D:\Data' -Relative '' | Should -BeExactly 'D:\Data (entire folder)'
	}
	It 'joins a drive root without doubling the backslash' {
		Format-FolderSizeLogPath -Root 'E:\' -Relative 'a\b.txt' | Should -BeExactly 'E:\a\b.txt'
	}
}

Describe 'Format-FolderSizeLogTotalLines' {
	It 'shows exact byte counts and widens a row instead of cutting a long number' {
		$big = [decimal]'123456789012345678901234567'
		$lines = Format-FolderSizeLogTotalLines -Rows @(
			@{ Name = 'Logical'; Kind = 'Bytes'; Source = $big; Backup = [decimal]0; Gap = $big }
		)
		$lines[3] | Should -Match ([regex]::Escape(('{0:N0}' -f $big)))
	}
}

Describe 'Format-FolderSizeLogLines' {
	It 'writes the single-folder log with full paths and no escape codes' {
		$saved = $global:UiState.UseVt
		$global:UiState.UseVt = $true
		try {
			$result = New-TestScanResult -Files @(@($script:DeepFile, 4096, 0), @('a.txt', 1, 1)) -Unreadable @(@{ RelativePath = 'Locked'; Error = 'Access to the path is denied.' })
			$metrics = Get-FolderSizeRollup -DirectoryStats $result.DirectoryStats -Differences $result.Differences
			$lines = Format-FolderSizeLogLines -Path 'D:\Users\student' -Result $result -MetricEntries $metrics -Started (Get-Date) -Finished (Get-Date)
		}
		finally { $global:UiState.UseVt = $saved }
		$text = $lines -join "`n"
		$text.Contains($script:Esc) | Should -BeFalse
		$text.Contains('D:\Users\student\Projects') | Should -BeTrue
		$text | Should -Match 'Error:\s+Access to the path is denied\.'
		$text | Should -Match 'Logical:\s+4\.00 KB \(4,096 bytes\)'
	}
}

Describe 'Write-FolderSizeReportFile' {
	BeforeEach {
		$script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('fs-log-test-' + [guid]::NewGuid().ToString('N'))
		[void][System.IO.Directory]::CreateDirectory($script:Work)
		$script:Blocker = Join-Path $script:Work 'blocker'
		[System.IO.File]::WriteAllText($script:Blocker, 'a file where a folder should be')
	}
	AfterEach {
		Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
	}

	It 'writes UTF-8 without a byte order mark and keeps every character' {
		$lines = @('plain', ('C1 ' + $script:C1Name), ('x' * 400))
		$log = Write-FolderSizeReportFile -Directories @($script:Work) -Prefix 'folder-compare' -Lines $lines
		$log.Path | Should -Not -BeNullOrEmpty
		$log.Failures.Count | Should -Be 0
		$bytes = [System.IO.File]::ReadAllBytes($log.Path)
		($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
		[System.IO.File]::ReadAllLines($log.Path, [System.Text.Encoding]::UTF8) | Should -Be $lines
	}
	It 'falls back to the next folder and reports the failure' {
		$bad = Join-Path $script:Blocker 'logs'
		$good = Join-Path $script:Work 'fallback'
		$log = Write-FolderSizeReportFile -Directories @($bad, $good) -Prefix 'folder-size' -Lines @('x')
		$log.Path | Should -BeLike ($good + '*')
		Test-Path -LiteralPath $log.Path | Should -BeTrue
		$log.Failures.Count | Should -Be 1
		$log.Failures[0] | Should -BeLike ($bad + ': *')
	}
	It 'tries each folder once and returns no path when all of them fail' {
		$bad = Join-Path $script:Blocker 'logs'
		$log = Write-FolderSizeReportFile -Directories @($bad, ($bad + '\'), $null, '') -Prefix 'folder-size' -Lines @('x')
		$log.Path | Should -BeNullOrEmpty
		$log.Failures.Count | Should -Be 1
	}
	It 'lists the preferred folder first, then the default and temp folders' {
		$dirs = Get-FolderSizeLogDirectories -Preferred 'Q:\logs'
		$dirs | Should -Be @('Q:\logs', 'C:\Temp\backup_logs\folder_size', [System.IO.Path]::GetTempPath())
	}
}
