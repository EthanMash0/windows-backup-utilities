function Test-FolderSizeMetricEntry {
	param($Entry)

	if ($null -eq $Entry) { return $false }
	if ($Entry -is [System.Collections.DictionaryEntry] -or $Entry -is [System.Collections.IDictionary]) { return $false }
	if ($null -eq $Entry.FileCount -or $null -eq $Entry.Logical -or $null -eq $Entry.Stored) { return $false }
	$count = 0L
	try { $count = [long]$Entry.FileCount } catch { return $false }
	return ($count -gt 0)
}

function Test-FolderSizeCrossEntry {
	param($Entry)

	if ($null -eq $Entry) { return $false }
	if ($Entry -is [System.Collections.DictionaryEntry] -or $Entry -is [System.Collections.IDictionary]) { return $false }
	if ($null -eq $Entry.FileCount) { return $false }
	$state = [string]$Entry.State
	if ($state -ne 'OnlyInSource' -and $state -ne 'OnlyInBackup' -and $state -ne 'LogicalMismatch') { return $false }
	$count = 0L
	try { $count = [long]$Entry.FileCount } catch { return $false }
	return ($count -gt 0)
}

function Format-FolderSizePlainCount {
	param([decimal]$Bytes)

	if ($Bytes -eq 0) { return '0' }
	$sign = ''
	$absolute = $Bytes
	if ($Bytes -lt 0) {
		$sign = '-'
		$absolute = -$Bytes
	}
	return ('{0}{1}' -f $sign, (Format-ByteSize ([double]$absolute)))
}

function Format-FolderSizePathCell {
	param(
		[AllowEmptyString()]
		[string]$Path,
		[int]$Width
	)

	return (Format-UiPath -Path (Format-FolderSizeRelativePath $Path) -Width $Width)
}

function Format-FolderSizePad {
	param(
		[AllowEmptyString()]
		[string]$Text,
		[int]$Width
	)

	if ($null -eq $Text) { $Text = '' }
	if ($Width -le 0) { return '' }
	if ((Get-VisibleTextLength $Text) -gt $Width) {
		$Text = Format-UiFittedText -Text $Text -Width $Width
	}
	$pad = $Width - (Get-VisibleTextLength $Text)
	if ($pad -le 0) { return $Text }
	return $Text + (' ' * $pad)
}

function New-FolderSizeTextLayout {
	param(
		[int]$InnerWidth,
		[int]$ValueColumns
	)

	if ($ValueColumns -lt 1) { $ValueColumns = 1 }
	$labelWidth = 12
	$gap = 2
	$overhead = 1 + $labelWidth + $gap + ($gap * ($ValueColumns - 1))
	$cellWidth = 8
	if ($InnerWidth -gt $overhead) {
		$cellWidth = [int][Math]::Floor(($InnerWidth - $overhead) / $ValueColumns)
	}
	$sideBySide = $false
	if ($ValueColumns -eq 1) { $sideBySide = $true }
	elseif ($cellWidth -ge 12 -and $InnerWidth -ge 68) { $sideBySide = $true }
	if (-not $sideBySide) {
		$singleOverhead = 1 + $labelWidth + $gap
		$cellWidth = 8
		if ($InnerWidth -gt $singleOverhead) { $cellWidth = $InnerWidth - $singleOverhead }
	}
	return @{
		LabelWidth = $labelWidth
		CellWidth = $cellWidth
		Gap = $gap
		SideBySide = $sideBySide
		ValueColumns = $ValueColumns
		InnerWidth = $InnerWidth
	}
}

function Format-FolderSizeTableRow {
	param(
		$Layout,
		[AllowEmptyString()]
		[string]$Label,
		$Cells
	)

	$gapText = ' ' * [int]$Layout.Gap
	$text = ' ' + (Format-FolderSizePad -Text $Label -Width ([int]$Layout.LabelWidth))
	foreach ($cell in (Get-FolderSizeStringList $Cells)) {
		$text += $gapText + (Format-FolderSizePad -Text $cell -Width ([int]$Layout.CellWidth))
	}
	if ((Get-VisibleTextLength $text) -gt [int]$Layout.InnerWidth) {
		$text = Format-UiFittedText -Text $text -Width ([int]$Layout.InnerWidth)
	}
	return $text
}

function Format-FolderSizeCompareRows {
	param(
		$Layout,
		[AllowEmptyString()]
		[string]$Label,
		$Cells,
		[string[]]$Headers
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$cellList = Get-FolderSizeStringList $Cells
	if ($Layout.SideBySide) {
		[void]$lines.Add((Format-FolderSizeTableRow -Layout $Layout -Label $Label -Cells $cellList))
	}
	else {
		if (-not [string]::IsNullOrEmpty($Label)) { [void]$lines.Add((' ' + $Label)) }
		$single = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 1
		for ($i = 0; $i -lt $cellList.Count; $i++) {
			$header = ''
			if ($null -ne $Headers -and $i -lt $Headers.Count) { $header = $Headers[$i] }
			[void]$lines.Add((Format-FolderSizeTableRow -Layout $single -Label $header -Cells $cellList[$i]))
		}
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeHeaderRow {
	param(
		$Layout,
		[string[]]$Headers,
		[switch]$Plain
	)

	if (-not $Layout.SideBySide) { return $null }
	$cells = New-Object System.Collections.Generic.List[string]
	foreach ($header in $Headers) {
		if ($Plain) { [void]$cells.Add($header) }
		else { [void]$cells.Add((Format-UiText -Text $header -Style Secondary)) }
	}
	return (Format-FolderSizeTableRow -Layout $Layout -Label '' -Cells $cells.ToArray())
}

function Format-FolderSizeRecordLines {
	param($Layout, $Pairs)

	$lines = New-Object System.Collections.Generic.List[string]
	foreach ($pair in $Pairs) {
		[void]$lines.Add((Format-FolderSizeTableRow -Layout $Layout -Label ([string]$pair[0]) -Cells ([string]$pair[1])))
	}
	return ,$lines.ToArray()
}

function Format-MetricRecordLines {
	param($Entries, [int]$InnerWidth)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 1
	$lines = New-Object System.Collections.Generic.List[string]
	$shown = 0
	foreach ($entry in (Get-FolderSizeObjectList $Entries)) {
		if (-not (Test-FolderSizeMetricEntry $entry)) { continue }
		if ($shown -gt 0) { [void]$lines.Add('') }
		$gap = [decimal]$entry.Logical - [decimal]$entry.Stored
		$path = Format-FolderSizePathCell -Path ([string]$entry.RelativePath) -Width ([int]$layout.CellWidth)
		$pairs = New-Object System.Collections.Generic.List[object]
		[void]$pairs.Add(@('Path', $path))
		[void]$pairs.Add(@('Files', ('{0:N0}' -f [long]$entry.FileCount)))
		[void]$pairs.Add(@('Logical', (Format-ByteSize ([double]$entry.Logical))))
		[void]$pairs.Add(@('Stored', (Format-ByteSize ([double]$entry.Stored))))
		[void]$pairs.Add(@('Gap', (Format-FolderSizePlainCount $gap)))
		foreach ($row in (Format-FolderSizeRecordLines -Layout $layout -Pairs $pairs)) {
			[void]$lines.Add($row)
		}
		$shown++
	}
	if ($shown -eq 0) { [void]$lines.Add('  No differences.') }
	return ,$lines.ToArray()
}

function Format-CrossRecordLines {
	param($Entries, [int]$InnerWidth)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 1
	$lines = New-Object System.Collections.Generic.List[string]
	$shown = 0
	foreach ($entry in (Get-FolderSizeObjectList $Entries)) {
		if (-not (Test-FolderSizeCrossEntry $entry)) { continue }
		if ($shown -gt 0) { [void]$lines.Add('') }
		$path = Format-FolderSizePathCell -Path ([string]$entry.RelativePath) -Width ([int]$layout.CellWidth)
		$pairs = New-Object System.Collections.Generic.List[object]
		[void]$pairs.Add(@('Path', $path))
		[void]$pairs.Add(@('Files', ('{0:N0}' -f [long]$entry.FileCount)))
		if ([string]$entry.State -eq 'OnlyInSource') {
			[void]$pairs.Add(@('Source', (Format-ByteSize ([double]$entry.SourceLogical))))
		}
		elseif ([string]$entry.State -eq 'OnlyInBackup') {
			[void]$pairs.Add(@('Backup', (Format-ByteSize ([double]$entry.DestLogical))))
		}
		else {
			[void]$pairs.Add(@('Source', (Format-ByteSize ([double]$entry.SourceLogical))))
			[void]$pairs.Add(@('Backup', (Format-ByteSize ([double]$entry.DestLogical))))
		}
		foreach ($row in (Format-FolderSizeRecordLines -Layout $layout -Pairs $pairs)) {
			[void]$lines.Add($row)
		}
		$shown++
	}
	if ($shown -eq 0) { [void]$lines.Add('  No differences.') }
	return ,$lines.ToArray()
}

function Format-FolderCompareTotalLines {
	param(
		$SourceResult,
		$BackupResult,
		[int]$InnerWidth,
		[switch]$Plain
	)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 3
	$lines = New-Object System.Collections.Generic.List[string]
	$headers = @('Source', 'Backup', 'Gap')
	$header = Format-FolderSizeHeaderRow -Layout $layout -Headers $headers -Plain:$Plain
	if ($null -ne $header) { [void]$lines.Add($header) }

	$metrics = New-Object System.Collections.Generic.List[object]
	[void]$metrics.Add(@{ Name = 'Logical'; Kind = 'bytes'; Source = [decimal]$SourceResult.Logical; Backup = [decimal]$BackupResult.Logical })
	[void]$metrics.Add(@{ Name = 'Stored'; Kind = 'bytes'; Source = [decimal]$SourceResult.Stored; Backup = [decimal]$BackupResult.Stored })
	[void]$metrics.Add(@{ Name = 'Files'; Kind = 'count'; Source = [long]$SourceResult.Files; Backup = [long]$BackupResult.Files })
	[void]$metrics.Add(@{ Name = 'Folders'; Kind = 'count'; Source = [long]$SourceResult.Folders; Backup = [long]$BackupResult.Folders })
	[void]$metrics.Add(@{ Name = 'Unreadable'; Kind = 'count'; Source = [long](Get-FolderSizeItemCount $SourceResult.Unreadable); Backup = [long](Get-FolderSizeItemCount $BackupResult.Unreadable) })
	[void]$metrics.Add(@{ Name = 'Reparse'; Kind = 'count'; Source = [long](Get-FolderSizeItemCount $SourceResult.Reparse); Backup = [long](Get-FolderSizeItemCount $BackupResult.Reparse) })

	foreach ($metric in $metrics) {
		$gap = [decimal]$metric.Source - [decimal]$metric.Backup
		if ($metric.Kind -eq 'bytes') {
			$sourceText = Format-ByteSize ([double]$metric.Source)
			$backupText = Format-ByteSize ([double]$metric.Backup)
			$gapText = Format-FolderSizePlainCount $gap
		}
		else {
			$sourceText = '{0:N0}' -f [long]$metric.Source
			$backupText = '{0:N0}' -f [long]$metric.Backup
			$gapText = '{0:N0}' -f [long]$gap
		}
		foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label ([string]$metric.Name) -Cells @($sourceText, $backupText, $gapText) -Headers $headers)) {
			[void]$lines.Add($row)
		}
		if ($metric.Kind -eq 'bytes') {
			$sourceBytes = '{0:N0}' -f [decimal]$metric.Source
			$backupBytes = '{0:N0}' -f [decimal]$metric.Backup
			$gapBytes = '{0:N0}' -f $gap
			foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label '' -Cells @($sourceBytes, $backupBytes, $gapBytes) -Headers $headers)) {
				[void]$lines.Add($row)
			}
		}
	}
	return ,$lines.ToArray()
}

function Format-UnreadableTableLines {
	param(
		$SourcePaths,
		$BackupPaths,
		[int]$InnerWidth,
		[switch]$SingleTree,
		[switch]$Plain
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$sourceItems = Get-FolderSizeStringList (Select-ShallowestPaths $SourcePaths)
	if ($SingleTree) {
		$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 1
		if ($sourceItems.Count -eq 0) { [void]$lines.Add('  none') }
		else {
			foreach ($path in $sourceItems) {
				$cell = Format-FolderSizePathCell -Path $path -Width ([int]$layout.CellWidth)
				[void]$lines.Add((Format-FolderSizeTableRow -Layout $layout -Label 'Path' -Cells $cell))
			}
		}
		return ,$lines.ToArray()
	}

	$backupItems = Get-FolderSizeStringList (Select-ShallowestPaths $BackupPaths)
	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 2
	$headers = @('Source', 'Backup')
	$header = Format-FolderSizeHeaderRow -Layout $layout -Headers $headers -Plain:$Plain
	if ($null -ne $header) { [void]$lines.Add($header) }
	$count = $sourceItems.Count
	if ($backupItems.Count -gt $count) { $count = $backupItems.Count }
	if ($count -eq 0) {
		foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label '' -Cells @('none', 'none') -Headers $headers)) {
			[void]$lines.Add($row)
		}
		return ,$lines.ToArray()
	}
	for ($i = 0; $i -lt $count; $i++) {
		$sourceCell = ''
		$backupCell = ''
		if ($i -lt $sourceItems.Count) {
			$sourceCell = Format-FolderSizePathCell -Path $sourceItems[$i] -Width ([int]$layout.CellWidth)
		}
		elseif ($i -eq 0) { $sourceCell = 'none' }
		if ($i -lt $backupItems.Count) {
			$backupCell = Format-FolderSizePathCell -Path $backupItems[$i] -Width ([int]$layout.CellWidth)
		}
		elseif ($i -eq 0) { $backupCell = 'none' }
		foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label '' -Cells @($sourceCell, $backupCell) -Headers $headers)) {
			[void]$lines.Add($row)
		}
	}
	return ,$lines.ToArray()
}

function Format-ReparseLogLines {
	param(
		$SourcePaths,
		$BackupPaths,
		[switch]$SingleTree
	)

	$lines = New-Object System.Collections.Generic.List[string]
	if ($SingleTree) {
		$items = @(Get-FolderSizeStringList $SourcePaths | Sort-Object)
		if ($items.Count -eq 0) { [void]$lines.Add('  none') }
		else {
			foreach ($path in $items) {
				[void]$lines.Add(('  {0}' -f (Format-FolderSizeRelativePath $path)))
			}
		}
	}
	else {
		foreach ($pair in @(
			@{ Label = 'Source'; Paths = $SourcePaths }
			@{ Label = 'Backup'; Paths = $BackupPaths }
		)) {
			$items = @(Get-FolderSizeStringList $pair.Paths | Sort-Object)
			if ($items.Count -eq 0) {
				[void]$lines.Add(('  {0}: none' -f $pair.Label))
			}
			else {
				foreach ($path in $items) {
					[void]$lines.Add(('  {0}: {1}' -f $pair.Label, (Format-FolderSizeRelativePath $path)))
				}
			}
		}
	}
	return ,$lines.ToArray()
}

function New-FolderSizeSectionBox {
	param(
		[int]$WindowWidth,
		[string]$Title,
		[string]$TitleStyle,
		$Rows,
		[switch]$WrapRows
	)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$titleText = Format-UiText -Text ('  ' + $Title) -Style $TitleStyle
	$body = New-Object System.Collections.Generic.List[string]
	[void]$body.Add('')
	foreach ($row in (Get-FolderSizeStringList $Rows)) { [void]$body.Add($row) }
	[void]$body.Add('')
	if ($WrapRows) {
		return Format-Box -Layout $layout -Title $titleText -Rows $body.ToArray() -WrapRows
	}
	return Format-Box -Layout $layout -Title $titleText -Rows $body.ToArray()
}

function New-FolderSizeDetailLines {
	param([int]$WindowWidth, $Detail)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$rows = Format-MetricRecordLines -Entries $Detail.Entries -InnerWidth ([int]$layout.InnerWidth)
	$capped = Get-CappedFolderSizeLines -Lines $rows -LogPath $Detail.LogPath
	return @('') + @(New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Logical vs stored' -TitleStyle Header -Rows $capped)
}

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
	foreach ($row in (Format-CrossRecordLines -Entries $Report.Cross -InnerWidth $inner)) { [void]$lines.Add($row) }
	[void]$lines.Add('')
	[void]$lines.Add('Source logical vs stored')
	foreach ($row in (Format-MetricRecordLines -Entries $Report.SourceMetrics -InnerWidth $inner)) { [void]$lines.Add($row) }
	[void]$lines.Add('')
	[void]$lines.Add('Backup logical vs stored')
	foreach ($row in (Format-MetricRecordLines -Entries $Report.BackupMetrics -InnerWidth $inner)) { [void]$lines.Add($row) }
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

function New-FolderCompareReportLines {
	param([int]$WindowWidth, $Report)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$inner = [int]$layout.InnerWidth
	$resultRows = New-Object System.Collections.Generic.List[string]
	[void]$resultRows.Add(('  ' + (Format-UiText -Text ([string]$Report.Status) -Style ([string]$Report.StatusStyle))))
	[void]$resultRows.Add('  Size check only. Equal logical size does not prove identical bytes.')
	if ($Report.StoredDiffers) { [void]$resultRows.Add('  Stored size differs from logical size.') }
	if ($Report.LogPath) { [void]$resultRows.Add(('  Log: {0}' -f [string]$Report.LogPath)) }
	else { [void]$resultRows.Add(('  Log: could not be written: {0}' -f [string]$Report.LogError)) }

	$lines = @('')
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Result' -TitleStyle ([string]$Report.StatusStyle) -Rows $resultRows.ToArray() -WrapRows
	$lines += ''
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Totals' -TitleStyle Header -Rows (Format-FolderCompareTotalLines -SourceResult $Report.SourceResult -BackupResult $Report.BackupResult -InnerWidth $inner)
	$lines += ''
	$cross = Format-CrossRecordLines -Entries $Report.Cross -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Cross-tree' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $cross -LogPath $Report.LogPath)
	$lines += ''
	$sourceMetric = Format-MetricRecordLines -Entries $Report.SourceMetrics -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Source logical vs stored' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $sourceMetric -LogPath $Report.LogPath)
	$lines += ''
	$backupMetric = Format-MetricRecordLines -Entries $Report.BackupMetrics -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Backup logical vs stored' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $backupMetric -LogPath $Report.LogPath)
	$lines += ''
	$unreadable = Format-UnreadableTableLines -SourcePaths $Report.SourceUnreadable -BackupPaths $Report.BackupUnreadable -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Unreadable' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $unreadable -LogPath $Report.LogPath)
	return $lines
}

function New-FolderCompareProgressBox {
	param(
		$Layout,
		$Source,
		$Backup,
		[string]$Status
	)

	$table = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 2
	$headers = @('Source', 'Backup')
	$rows = New-Object System.Collections.Generic.List[string]
	[void]$rows.Add('')
	if (-not [string]::IsNullOrWhiteSpace($Status)) {
		[void]$rows.Add((' ' + $Status))
		[void]$rows.Add('')
	}
	$header = Format-FolderSizeHeaderRow -Layout $table -Headers $headers
	if ($null -ne $header) { [void]$rows.Add($header) }
	$metrics = @(
		@{ Name = 'Logical'; Source = (Format-ByteSize $Source.Logical); Backup = (Format-ByteSize $Backup.Logical) }
		@{ Name = 'Stored'; Source = (Format-ByteSize $Source.Stored); Backup = (Format-ByteSize $Backup.Stored) }
		@{ Name = 'Files'; Source = ('{0:N0}' -f $Source.Files); Backup = ('{0:N0}' -f $Backup.Files) }
		@{ Name = 'Folders'; Source = ('{0:N0}' -f $Source.Folders); Backup = ('{0:N0}' -f $Backup.Folders) }
	)
	foreach ($metric in $metrics) {
		foreach ($row in (Format-FolderSizeCompareRows -Layout $table -Label ([string]$metric.Name) -Cells @($metric.Source, $metric.Backup) -Headers $headers)) {
			[void]$rows.Add($row)
		}
	}
	[void]$rows.Add('')
	$sourcePath = Format-UiPath -Path $Source.CurrentPath -Width ([int]$table.CellWidth)
	$backupPath = Format-UiPath -Path $Backup.CurrentPath -Width ([int]$table.CellWidth)
	foreach ($row in (Format-FolderSizeCompareRows -Layout $table -Label 'Path' -Cells @($sourcePath, $backupPath) -Headers $headers)) {
		[void]$rows.Add($row)
	}
	[void]$rows.Add('')
	$title = Format-UiText -Text ' Comparing' -Style Progress
	return Format-Box -Layout $Layout -Title $title -Rows $rows.ToArray()
}

function New-FolderCompareScreenLines {
	param([int]$WindowWidth, $Progress)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	return @('') + @(New-FolderCompareProgressBox -Layout $layout -Source $Progress.Source -Backup $Progress.Backup -Status $Progress.Status)
}
