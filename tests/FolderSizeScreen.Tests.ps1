BeforeAll {
	. (Join-Path $PSScriptRoot 'TestSetup.ps1')

	$script:LogPath = 'C:\Temp\backup_logs\folder_size\folder-compare-20260102-030910-abcdef12.txt'

	function New-TestScreenReport {
		param($Log = @{ Path = $script:LogPath; Failures = @() })

		$source = New-TestScanResult -Files @(
			@('Docs\a.txt', 1258291, 1258291),
			@('Docs\b.txt', 10, 10),
			@('Only\c.txt', 50, 50),
			@('Cloud\d.bin', 5000000, 0)
		) -Unreadable @(@{ RelativePath = 'Locked'; Error = 'Access to the path is denied.' })
		$backup = New-TestScanResult -Files @(
			@('Docs\a.txt', 40960, 40960),
			@('Docs\b.txt', 10, 10),
			@('Cloud\d.bin', 5000000, 5000000)
		)
		return New-TestCompareReport -Source 'D:\Users\student' -Dest 'Z:\Backups\student' -SourceResult $source -BackupResult $backup -Log $Log
	}

	function Get-TestBoxText {
		param([string[]]$Lines)

		# Inner text of every box row, borders removed, joined so wrapped rows
		# read as one string.
		$inner = foreach ($line in $Lines) {
			if ($line.Length -ge 2 -and $line[0] -eq [char]0x2502) { $line.Substring(1, $line.Length - 2) }
		}
		return ($inner -join '')
	}
}

Describe 'New-FolderCompareReportLines' {
	It 'shows only the Totals and Result boxes at width <Width>' -ForEach @(
		@{ Width = 40 }
		@{ Width = 80 }
		@{ Width = 160 }
	) {
		$lines = @(New-FolderCompareReportLines -WindowWidth $Width -Report (New-TestScreenReport))
		$text = $lines -join "`n"
		$text | Should -MatchExactly 'Totals'
		$text | Should -MatchExactly 'Result'
		$text | Should -Not -MatchExactly 'Cross-tree'
		$text | Should -Not -MatchExactly 'Logical vs stored'
		$text | Should -Not -MatchExactly 'Unreadable:'
		foreach ($line in $lines) {
			(Get-VisibleTextLength $line) | Should -BeLessThan $Width
		}
	}
	It 'wraps the log path instead of cutting it at width <Width>' -ForEach @(
		@{ Width = 40 }
		@{ Width = 80 }
	) {
		$lines = @(New-FolderCompareReportLines -WindowWidth $Width -Report (New-TestScreenReport))
		(Get-TestBoxText $lines) | Should -Match ([regex]::Escape($script:LogPath))
	}
	It 'leaves exact byte rows out of the Totals box at width <Width>' -ForEach @(
		@{ Width = 60 }
		@{ Width = 80 }
	) {
		$lines = @(New-FolderCompareReportLines -WindowWidth $Width -Report (New-TestScreenReport))
		($lines | Where-Object { $_ -match '^\S bytes\s' }).Count | Should -Be 0
		($lines | Where-Object { $_ -match '\(\d[\d,]* bytes\)' }).Count | Should -Be 0
	}
	It 'puts the columns side by side at width 80 and stacks them at width 60' {
		$wide = @(New-FolderCompareReportLines -WindowWidth 80 -Report (New-TestScreenReport))
		($wide | Where-Object { $_ -match 'Source\s+Backup\s+Gap' }).Count | Should -Be 1
		$narrow = @(New-FolderCompareReportLines -WindowWidth 60 -Report (New-TestScreenReport))
		($narrow | Where-Object { $_ -match 'Source\s+Backup\s+Gap' }).Count | Should -Be 0
		($narrow | Where-Object { $_ -match '^\S Source\s' }).Count | Should -BeGreaterThan 0
	}
}

Describe 'Get-FolderCompareResultRows' {
	It 'states the verdict, notes, detail counts, and log location' {
		$rows = Get-FolderCompareResultRows -Report (New-TestScreenReport)
		$text = $rows -join "`n"
		$text | Should -Match 'Source and backup differ\.'
		$text | Should -Not -Match 'Size check only'
		$text | Should -Match 'Stored size differs from logical size\.'
		$text | Should -Match 'Details in log: 2 cross-tree, 1 logical vs stored, 1 unreadable\.'
		$text | Should -Match ([regex]::Escape('Log: ' + $script:LogPath))
	}
	It 'says where the log could not be written and drops the detail counts' {
		$log = @{ Path = $null; Failures = @('Z:\logs: Could not find a part of the path.', 'C:\Temp\backup_logs\folder_size: Access denied.') }
		$text = (Get-FolderCompareResultRows -Report (New-TestScreenReport -Log $log)) -join "`n"
		$text | Should -Match 'The log could not be written\.'
		$text | Should -Match ([regex]::Escape('Could not write the log to Z:\logs: Could not find a part of the path.'))
		$text | Should -Match ([regex]::Escape('Could not write the log to C:\Temp\backup_logs\folder_size: Access denied.'))
		$text | Should -Not -Match 'Details in log'
	}
	It 'notes a fallback location when the first choice failed' {
		$log = @{ Path = $script:LogPath; Failures = @('Z:\logs: Could not find a part of the path.') }
		$text = (Get-FolderCompareResultRows -Report (New-TestScreenReport -Log $log)) -join "`n"
		$text | Should -Match ([regex]::Escape('Log: ' + $script:LogPath))
		$text | Should -Match ([regex]::Escape('Could not write the log to Z:\logs'))
	}
}

Describe 'New-FolderCompareScreenLines' {
	It 'shows the comparison progress bar while matching files' {
		$progress = @{
			Source = (New-FolderSizeSnapshot -CurrentPath 'D:\Users\student')
			Backup = (New-FolderSizeSnapshot -CurrentPath 'Z:\Backups\student')
			Status = ''
			Compared = 5
			Total = 10
		}
		$text = (New-FolderCompareScreenLines -WindowWidth 80 -Progress $progress) -join "`n"
		$text | Should -Match 'Comparing: \[.*\] 50\.00%'
	}
	It 'shows a status line once matching is done' {
		$progress = @{
			Source = (New-FolderSizeSnapshot -CurrentPath 'D:\a')
			Backup = (New-FolderSizeSnapshot -CurrentPath 'Z:\b')
			Status = 'Writing the log'
			Compared = $null
			Total = $null
		}
		$text = (New-FolderCompareScreenLines -WindowWidth 80 -Progress $progress) -join "`n"
		$text | Should -Match 'Writing the log'
		$text | Should -Not -Match 'Comparing:'
	}
	It 'fits every line at width <Width>' -ForEach @(
		@{ Width = 40 }
		@{ Width = 160 }
	) {
		$progress = @{
			Source = (New-FolderSizeSnapshot -CurrentPath ('D:\' + ('deep\' * 60)))
			Backup = (New-FolderSizeSnapshot -CurrentPath 'Z:\b')
			Status = ''
			Compared = 1
			Total = 3
		}
		foreach ($line in (New-FolderCompareScreenLines -WindowWidth $Width -Progress $progress)) {
			(Get-VisibleTextLength $line) | Should -BeLessThan $Width
		}
	}
}

Describe 'New-FolderSizePathsLines' {
	It 'shows the source and destination under the tool title' {
		$data = @{ Title = 'Folder Size Comparison'; Rows = @('  Source:      D:\Users\student', '  Destination: Z:\Backups\student') }
		$lines = @(New-FolderSizePathsLines -WindowWidth 80 -Data $data)
		$lines[0] | Should -BeExactly ''
		$lines[2] | Should -Match '^\S  Folder Size Comparison\s+\S$'
		$lines[4] | Should -Match ([regex]::Escape('  Source:      D:\Users\student '))
		$lines[5] | Should -Match ([regex]::Escape('  Destination: Z:\Backups\student '))
	}
	It 'wraps a long path instead of shortening it at width <Width>' -ForEach @(
		@{ Width = 40 }
		@{ Width = 80 }
	) {
		$long = 'D:\Users\student\' + ((1..20 | ForEach-Object { 'Segment{0:00}' -f $_ }) -join '\')
		$data = @{ Title = 'Folder Size Counter'; Rows = @("  Folder: $long") }
		$lines = @(New-FolderSizePathsLines -WindowWidth $Width -Data $data)
		foreach ($line in $lines) { (Get-VisibleTextLength $line) | Should -BeLessThan $Width }
		(Get-TestBoxText $lines) -replace '\s', '' | Should -Match ([regex]::Escape($long))
	}
}

Describe 'Format-ByteSizeDetail' {
	It 'writes sizes under 1 KB as whole bytes so a small gap is not shown as zero' {
		Format-ByteSizeDetail 0 | Should -BeExactly '0 bytes'
		Format-ByteSizeDetail 5 | Should -BeExactly '5 bytes'
		Format-ByteSizeDetail -103 | Should -BeExactly '-103 bytes'
		Format-ByteSizeDetail 1023 -Exact | Should -BeExactly '1,023 bytes'
	}
	It 'writes larger sizes in units, with the exact count on request' {
		Format-ByteSizeDetail 4096 | Should -BeExactly '4.00 KB'
		Format-ByteSizeDetail -1048576 -Exact | Should -BeExactly '-1.00 MB (-1,048,576 bytes)'
	}
}

Describe 'Get-FolderSizeSummaryRows' {
	It 'summarizes the scan and points to the log for details' {
		$result = New-TestScanResult -Files @(, @('a.txt', 4096, 0)) -Reparse @(@{ RelativePath = 'Link'; Kind = 'symlink' })
		$rows = Get-FolderSizeSummaryRows -Path 'D:\Data' -Result $result -MetricCount 1 -Log @{ Path = 'C:\Temp\x.txt'; Failures = @() }
		$text = $rows -join "`n"
		$text | Should -Match 'Logical size:\s+4\.00 KB \(4,096 bytes\)'
		$text | Should -Match 'Details in log: 1 logical vs stored, 0 unreadable, 1 reparse points\.'
		$text | Should -Match ([regex]::Escape('Log: C:\Temp\x.txt'))
	}
}

Describe 'Format-UiProgressBar' {
	It 'clamps the fill to the bar width' {
		$saved = $global:UiState.UseVt
		$global:UiState.UseVt = $false
		try {
			Format-UiProgressBar -Percent 50 -BarWidth 4 | Should -BeExactly ('[' + [string][char]0x2588 * 2 + [string][char]0x2500 * 2 + ']')
			Format-UiProgressBar -Percent 150 -BarWidth 3 | Should -BeExactly ('[' + [string][char]0x2588 * 3 + ']')
			Format-UiProgressBar -Percent -10 -BarWidth 2 | Should -BeExactly ('[' + [string][char]0x2500 * 2 + ']')
		}
		finally { $global:UiState.UseVt = $saved }
	}
}
