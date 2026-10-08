function Format-FolderCompareLogLines {
	param($Report)

	$inner = 96
	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add(('Source: {0}' -f [string]$Report.Source))
	[void]$lines.Add(('Backup: {0}' -f [string]$Report.Dest))
	[void]$lines.Add('')
	[void]$lines.Add('Result')
	[void]$lines.Add(('  {0}' -f [string]$Report.Status))
	[void]$lines.Add('  Size check only. Equal logical size does not prove identical bytes.')
	if ($Report.StoredDiffers) { [void]$lines.Add('  Stored size differs from logical size.') }
	[void]$lines.Add('')
	[void]$lines.Add('Totals')
	foreach ($row in (Format-FolderCompareTotalLines -SourceResult $Report.SourceResult -BackupResult $Report.BackupResult -InnerWidth $inner -Plain)) {
		[void]$lines.Add($row)
	}
	[void]$lines.Add('')
	[void]$lines.Add('Cross-tree')
	foreach ($row in (Format-CrossTreeTableLines -Entries $Report.Cross -InnerWidth $inner -Plain)) { [void]$lines.Add($row) }
	[void]$lines.Add('')
	[void]$lines.Add('Logical vs stored')
	foreach ($row in (Format-MetricCompareTableLines -SourceEntries $Report.SourceMetrics -BackupEntries $Report.BackupMetrics -InnerWidth $inner -Plain)) { [void]$lines.Add($row) }
	[void]$lines.Add('')
	[void]$lines.Add('Unreadable')
	foreach ($row in (Format-UnreadableTableLines -SourcePaths $Report.SourceUnreadable -BackupPaths $Report.BackupUnreadable -InnerWidth $inner -Plain)) {
		[void]$lines.Add($row)
	}
	[void]$lines.Add('')
	[void]$lines.Add('Reparse points skipped')
	foreach ($row in (Format-ReparseLogLines -SourcePaths $Report.SourceReparse -BackupPaths $Report.BackupReparse)) {
		[void]$lines.Add($row)
	}
	return ,$lines.ToArray()
}

function Write-FolderSizeReportFile {
	param(
		[string]$Directory,
		[string]$Prefix,
		[string[]]$Lines
	)

	$name = '{0}-{1}-{2}.txt' -f $Prefix, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
	$path = Join-Path $Directory $name
	[void][System.IO.Directory]::CreateDirectory($Directory)
	$utf8 = New-Object System.Text.UTF8Encoding $false
	[System.IO.File]::WriteAllLines($path, [string[]]@($Lines), $utf8)
	return $path
}
