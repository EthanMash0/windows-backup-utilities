# Log text is written exactly as built. Nothing here may pass through the
# screen fitting helpers, which truncate paths and add color codes.

function Format-FolderSizeLogPath {
	param(
		[string]$Root,
		[AllowEmptyString()]
		[string]$Relative
	)

	if ([string]::IsNullOrEmpty($Relative)) { return ('{0} (entire folder)' -f $Root) }
	return Join-FolderSizeDisplayPath -Root $Root -Relative $Relative
}

function Format-FolderSizeLogField {
	param(
		[string]$Label,
		[string]$Value,
		[int]$Indent = 4
	)

	return ('{0}{1,-17}{2}' -f (' ' * $Indent), ($Label + ':'), $Value)
}

function Format-FolderSizeLogTime {
	param([datetime]$Time)

	return $Time.ToString('yyyy-MM-dd HH:mm:ss')
}

function Format-FolderSizeLogHeader {
	param(
		[string]$Title,
		[datetime]$Started,
		[datetime]$Finished,
		[System.Collections.Specialized.OrderedDictionary]$Paths
	)

	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add($Title)
	[void]$lines.Add((Format-FolderSizeLogField -Indent 0 -Label 'Started' -Value (Format-FolderSizeLogTime $Started)))
	[void]$lines.Add((Format-FolderSizeLogField -Indent 0 -Label 'Finished' -Value (Format-FolderSizeLogTime $Finished)))
	foreach ($label in $Paths.Keys) {
		[void]$lines.Add((Format-FolderSizeLogField -Indent 0 -Label $label -Value ([string]$Paths[$label])))
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeLogMetricLines {
	param(
		[string]$Title,
		[string]$Root,
		$Entries
	)

	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add(('{0} ({1:N0})' -f $Title, $Entries.Count))
	if ($Entries.Count -eq 0) { [void]$lines.Add('  none') }
	foreach ($entry in $Entries) {
		[void]$lines.Add(('  ' + (Format-FolderSizeLogPath -Root $Root -Relative $entry.RelativePath)))
		[void]$lines.Add((Format-FolderSizeLogField -Label 'Files' -Value ('{0:N0}' -f [long]$entry.FileCount)))
		[void]$lines.Add((Format-FolderSizeLogField -Label 'Logical' -Value (Format-ByteSizeDetail $entry.Logical -Exact)))
		[void]$lines.Add((Format-FolderSizeLogField -Label 'Stored' -Value (Format-ByteSizeDetail $entry.Stored -Exact)))
		$gap = [decimal]$entry.Logical - [decimal]$entry.Stored
		[void]$lines.Add((Format-FolderSizeLogField -Label 'Gap' -Value (Format-ByteSizeDetail $gap -Exact)))
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeLogFileCount {
	param($Entry)

	if ([long]$Entry.FileCount -eq 0) { return '0 (empty folder)' }
	return ('{0:N0}' -f [long]$Entry.FileCount)
}

function Format-FolderSizeLogCrossLines {
	param(
		[string]$SourceRoot,
		[string]$BackupRoot,
		$Entries
	)

	$lines = New-Object System.Collections.Generic.List[string]
	foreach ($group in @(
		@{ State = 'OnlyInSource'; Title = 'Cross-tree: only in source' }
		@{ State = 'OnlyInBackup'; Title = 'Cross-tree: only in backup' }
		@{ State = 'LogicalMismatch'; Title = 'Cross-tree: logical size mismatch' }
	)) {
		$members = @($Entries | Where-Object { $_.State -eq $group.State })
		if ($lines.Count -gt 0) { [void]$lines.Add('') }
		[void]$lines.Add(('{0} ({1:N0})' -f $group.Title, $members.Count))
		if ($members.Count -eq 0) { [void]$lines.Add('  none') }
		foreach ($entry in $members) {
			if ($group.State -eq 'OnlyInSource') {
				[void]$lines.Add(('  ' + (Format-FolderSizeLogPath -Root $SourceRoot -Relative $entry.RelativePath)))
				[void]$lines.Add((Format-FolderSizeLogField -Label 'Files' -Value (Format-FolderSizeLogFileCount $entry)))
				[void]$lines.Add((Format-FolderSizeLogField -Label 'Logical' -Value (Format-ByteSizeDetail $entry.SourceLogical -Exact)))
			}
			elseif ($group.State -eq 'OnlyInBackup') {
				[void]$lines.Add(('  ' + (Format-FolderSizeLogPath -Root $BackupRoot -Relative $entry.RelativePath)))
				[void]$lines.Add((Format-FolderSizeLogField -Label 'Files' -Value (Format-FolderSizeLogFileCount $entry)))
				[void]$lines.Add((Format-FolderSizeLogField -Label 'Logical' -Value (Format-ByteSizeDetail $entry.DestLogical -Exact)))
			}
			else {
				[void]$lines.Add((Format-FolderSizeLogField -Indent 2 -Label 'Source' -Value (Format-FolderSizeLogPath -Root $SourceRoot -Relative $entry.RelativePath)))
				[void]$lines.Add((Format-FolderSizeLogField -Indent 2 -Label 'Backup' -Value (Format-FolderSizeLogPath -Root $BackupRoot -Relative $entry.RelativePath)))
				[void]$lines.Add((Format-FolderSizeLogField -Label 'Files' -Value (Format-FolderSizeLogFileCount $entry)))
				[void]$lines.Add((Format-FolderSizeLogField -Label 'Source logical' -Value (Format-ByteSizeDetail $entry.SourceLogical -Exact)))
				[void]$lines.Add((Format-FolderSizeLogField -Label 'Backup logical' -Value (Format-ByteSizeDetail $entry.DestLogical -Exact)))
			}
		}
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeLogUnreadableLines {
	param(
		[string]$Title,
		[string]$Root,
		$Records
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$sorted = @($Records | Sort-Object { [string]$_.RelativePath })
	[void]$lines.Add(('{0} ({1:N0})' -f $Title, $sorted.Count))
	if ($sorted.Count -eq 0) { [void]$lines.Add('  none') }
	foreach ($record in $sorted) {
		[void]$lines.Add(('  ' + (Format-FolderSizeLogPath -Root $Root -Relative $record.RelativePath)))
		[void]$lines.Add((Format-FolderSizeLogField -Label 'Error' -Value ([string]$record.Error)))
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeLogReparseLines {
	param(
		[string]$Title,
		[string]$Root,
		$Records
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$sorted = @($Records | Sort-Object { [string]$_.RelativePath })
	[void]$lines.Add(('{0} ({1:N0})' -f $Title, $sorted.Count))
	if ($sorted.Count -eq 0) { [void]$lines.Add('  none') }
	foreach ($record in $sorted) {
		[void]$lines.Add(('  ' + (Format-FolderSizeLogPath -Root $Root -Relative $record.RelativePath)))
		[void]$lines.Add((Format-FolderSizeLogField -Label 'Kind' -Value ([string]$record.Kind)))
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeLogTotalLines {
	param($Rows)

	# Alignment widths are minimums, so a long number widens its row instead
	# of being cut.
	$format = '  {0,-12}{1,24}{2,24}{3,24}'
	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add('Totals')
	[void]$lines.Add(($format -f '', 'Source', 'Backup', 'Gap'))
	foreach ($row in $Rows) {
		if ($row.Kind -eq 'Bytes') {
			[void]$lines.Add(($format -f $row.Name, (Format-ByteSizeDetail $row.Source), (Format-ByteSizeDetail $row.Backup), (Format-ByteSizeDetail $row.Gap)))
			[void]$lines.Add(($format -f 'bytes', ('{0:N0}' -f $row.Source), ('{0:N0}' -f $row.Backup), ('{0:N0}' -f $row.Gap)))
		}
		else {
			[void]$lines.Add(($format -f $row.Name, ('{0:N0}' -f $row.Source), ('{0:N0}' -f $row.Backup), ('{0:N0}' -f $row.Gap)))
		}
	}
	return ,$lines.ToArray()
}

function Add-FolderSizeLogSection {
	param(
		[System.Collections.Generic.List[string]]$Lines,
		$Section
	)

	[void]$Lines.Add('')
	foreach ($line in $Section) { [void]$Lines.Add([string]$line) }
}

function Format-FolderSizeLogLines {
	param(
		[string]$Path,
		[hashtable]$Result,
		$MetricEntries,
		[datetime]$Started,
		[datetime]$Finished
	)

	$lines = New-Object System.Collections.Generic.List[string]
	foreach ($line in (Format-FolderSizeLogHeader -Title 'Folder Size' -Started $Started -Finished $Finished -Paths ([ordered]@{ Path = $Path }))) {
		[void]$lines.Add($line)
	}
	$gap = [decimal]$Result.Logical - [decimal]$Result.Stored
	Add-FolderSizeLogSection -Lines $lines -Section @(
		'Summary'
		(Format-FolderSizeLogField -Indent 2 -Label 'Logical size' -Value (Format-ByteSizeDetail $Result.Logical -Exact))
		(Format-FolderSizeLogField -Indent 2 -Label 'Stored size' -Value (Format-ByteSizeDetail $Result.Stored -Exact))
		(Format-FolderSizeLogField -Indent 2 -Label 'Gap' -Value (Format-ByteSizeDetail $gap -Exact))
		(Format-FolderSizeLogField -Indent 2 -Label 'Files' -Value ('{0:N0}' -f $Result.Files))
		(Format-FolderSizeLogField -Indent 2 -Label 'Folders' -Value ('{0:N0}' -f $Result.Folders))
		(Format-FolderSizeLogField -Indent 2 -Label 'Unreadable' -Value ('{0:N0}' -f $Result.Unreadable.Count))
		(Format-FolderSizeLogField -Indent 2 -Label 'Reparse' -Value ('{0:N0}' -f $Result.Reparse.Count))
	)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogMetricLines -Title 'Logical vs stored' -Root $Path -Entries $MetricEntries)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogUnreadableLines -Title 'Unreadable' -Root $Path -Records $Result.Unreadable)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogReparseLines -Title 'Reparse points skipped' -Root $Path -Records $Result.Reparse)
	return ,$lines.ToArray()
}

function Format-FolderCompareLogLines {
	param([hashtable]$Report)

	$source = [string]$Report.Source
	$backup = [string]$Report.Dest
	$lines = New-Object System.Collections.Generic.List[string]
	foreach ($line in (Format-FolderSizeLogHeader -Title 'Folder Size Comparison' -Started $Report.Started -Finished $Report.Finished -Paths ([ordered]@{ Source = $source; Backup = $backup }))) {
		[void]$lines.Add($line)
	}
	$result = New-Object System.Collections.Generic.List[string]
	[void]$result.Add('Result')
	[void]$result.Add(('  ' + [string]$Report.Status))
	[void]$result.Add('  Size check only. Equal logical size does not prove identical bytes.')
	foreach ($note in (Get-FolderCompareResultNotes -Report $Report)) { [void]$result.Add(('  ' + $note)) }
	Add-FolderSizeLogSection -Lines $lines -Section $result
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogTotalLines -Rows (Get-FolderCompareTotalRows -SourceResult $Report.SourceResult -BackupResult $Report.BackupResult))
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogCrossLines -SourceRoot $source -BackupRoot $backup -Entries $Report.Cross)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogMetricLines -Title 'Source logical vs stored' -Root $source -Entries $Report.SourceMetrics)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogMetricLines -Title 'Backup logical vs stored' -Root $backup -Entries $Report.BackupMetrics)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogUnreadableLines -Title 'Unreadable: source' -Root $source -Records $Report.SourceResult.Unreadable)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogUnreadableLines -Title 'Unreadable: backup' -Root $backup -Records $Report.BackupResult.Unreadable)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogReparseLines -Title 'Reparse points skipped: source' -Root $source -Records $Report.SourceResult.Reparse)
	Add-FolderSizeLogSection -Lines $lines -Section (Format-FolderSizeLogReparseLines -Title 'Reparse points skipped: backup' -Root $backup -Records $Report.BackupResult.Reparse)
	return ,$lines.ToArray()
}

function Get-FolderSizeLogDirectories {
	param([string]$Preferred)

	return ,@($Preferred, $script:FolderSizeLogRoot, [System.IO.Path]::GetTempPath())
}

function Write-FolderSizeReportFile {
	param(
		$Directories,
		[string]$Prefix,
		[string[]]$Lines
	)

	$name = '{0}-{1}-{2}.txt' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
	$utf8 = New-Object System.Text.UTF8Encoding $false
	$failures = New-Object System.Collections.Generic.List[string]
	$tried = New-FolderSizeKeyTable
	foreach ($directory in $Directories) {
		if ([string]::IsNullOrWhiteSpace($directory)) { continue }
		$key = ([string]$directory).TrimEnd('\', '/')
		if ($tried.ContainsKey($key)) { continue }
		$tried[$key] = $true
		try {
			# Path.Combine, not Join-Path: Join-Path fails on a drive letter that
			# is not mapped in this session before the write is even tried.
			$path = [System.IO.Path]::Combine([string]$directory, $name)
			[void][System.IO.Directory]::CreateDirectory([string]$directory)
			[System.IO.File]::WriteAllLines($path, $Lines, $utf8)
			return @{ Path = $path; Failures = $failures.ToArray() }
		}
		catch [System.Management.Automation.PipelineStoppedException] { throw }
		catch {
			[void]$failures.Add(('{0}: {1}' -f $directory, (Get-FolderSizeErrorMessage $_)))
		}
	}
	return @{ Path = $null; Failures = $failures.ToArray() }
}
