function Format-FolderSizeRelativePath {
	param([string]$RelativePath)

	if ([string]::IsNullOrEmpty($RelativePath)) { return 'entire folder' }
	return $RelativePath
}

function Update-FolderCompareBuildStatus {
	param(
		[string]$Status,
		$Done,
		$Total
	)

	if ($null -eq $script:FolderCompareBuildProgress) { return }
	$script:FolderCompareBuildProgress.Status = $Status
	if ($null -eq $Done -or $null -eq $Total) {
		$script:FolderCompareBuildProgress.Compared = $null
		$script:FolderCompareBuildProgress.Total = $null
	}
	else {
		$script:FolderCompareBuildProgress.Compared = [long]$Done
		$script:FolderCompareBuildProgress.Total = [long]$Total
	}
	if ($null -ne $script:UiScreen) { $script:UiScreen.Dirty = $true }
	Update-UiScreen -Force
}

function Format-FolderCompareBar {
	param(
		$Layout,
		[long]$Done,
		[long]$Total
	)

	$percent = 0.0
	if ($Total -gt 0) {
		$percent = [Math]::Min(100, ($Done / $Total) * 100)
	}
	$percentText = '{0:N2}%' -f $percent
	$label = ' Comparing: '
	$barWidth = $Layout.InnerWidth - (Get-VisibleTextLength $label) - (Get-VisibleTextLength $percentText) - 3
	if ($barWidth -gt 40) { $barWidth = 40 }
	if ($barWidth -lt 1) { $barWidth = 1 }

	$fillLen = [int][Math]::Round(($percent / 100) * $barWidth)
	if ($fillLen -lt 0) { $fillLen = 0 }
	elseif ($fillLen -gt $barWidth) { $fillLen = $barWidth }
	$emptyLen = $barWidth - $fillLen

	# Block fill and a horizontal empty track, via code points so Windows
	# PowerShell 5.1 can parse this file without a UTF-8 BOM.
	$fillStr = ''
	$emptyStr = ''
	if ($fillLen -gt 0) { $fillStr = Format-UiText -Text ([String]::new([char]0x2588, $fillLen)) -Style Success }
	if ($emptyLen -gt 0) { $emptyStr = Format-UiText -Text ([String]::new([char]0x2500, $emptyLen)) -Style Secondary }
	return $label + '[' + $fillStr + $emptyStr + '] ' + $percentText
}

function Format-ByteCount {
	param([decimal]$Bytes)

	return ('{0} ({1:N0} bytes)' -f (Format-ByteSize ([double]$Bytes)), $Bytes)
}

function Format-SignedByteCount {
	param([decimal]$Bytes)

	$sign = ''
	$absolute = $Bytes
	if ($Bytes -lt 0) {
		$sign = '-'
		$absolute = -$Bytes
	}
	return ('{0}{1} ({2:N0} bytes)' -f $sign, (Format-ByteSize ([double]$absolute)), $Bytes)
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

function Get-FolderSizeFitWidth {
	param($Layout)

	if ($Layout.SideBySide) { return [int]$Layout.CellWidth }
	$single = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 1
	return [int]$single.CellWidth
}

function Format-PairedColumnLines {
	param(
		$Layout,
		$LeftBlocks,
		$RightBlocks,
		[string[]]$Headers,
		[switch]$Plain,
		[switch]$NoHeader
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$leftCount = 0
	$rightCount = 0
	if ($null -ne $LeftBlocks) { $leftCount = $LeftBlocks.Count }
	if ($null -ne $RightBlocks) { $rightCount = $RightBlocks.Count }
	$count = $leftCount
	if ($rightCount -gt $count) { $count = $rightCount }
	if ($count -eq 0) { return ,$lines.ToArray() }
	if (-not $NoHeader) {
		$header = Format-FolderSizeHeaderRow -Layout $Layout -Headers $Headers -Plain:$Plain
		if ($null -ne $header) { [void]$lines.Add($header) }
	}
	for ($i = 0; $i -lt $count; $i++) {
		if ($i -gt 0) { [void]$lines.Add('') }
		$leftLines = @()
		$rightLines = @()
		if ($i -lt $leftCount) { $leftLines = Get-FolderSizeStringList $LeftBlocks[$i] }
		if ($i -lt $rightCount) { $rightLines = Get-FolderSizeStringList $RightBlocks[$i] }
		$rowCount = $leftLines.Count
		if ($rightLines.Count -gt $rowCount) { $rowCount = $rightLines.Count }
		for ($row = 0; $row -lt $rowCount; $row++) {
			$leftCell = ''
			$rightCell = ''
			if ($row -lt $leftLines.Count) { $leftCell = [string]$leftLines[$row] }
			if ($row -lt $rightLines.Count) { $rightCell = [string]$rightLines[$row] }
			foreach ($line in (Format-FolderSizeCompareRows -Layout $Layout -Label '' -Cells @($leftCell, $rightCell) -Headers $Headers)) {
				[void]$lines.Add($line)
			}
		}
	}
	return ,$lines.ToArray()
}

function Get-MetricCompareCellLines {
	param($Entry, [int]$Width)

	$lines = New-Object System.Collections.Generic.List[string]
	if (-not (Test-FolderSizeMetricEntry $Entry)) { return ,$lines.ToArray() }
	$gap = [decimal]$Entry.Logical - [decimal]$Entry.Stored
	[void]$lines.Add((Format-FolderSizePathCell -Path ([string]$Entry.RelativePath) -Width $Width))
	[void]$lines.Add(('{0:N0} files' -f [long]$Entry.FileCount))
	[void]$lines.Add(('Logical {0}' -f (Format-ByteSize ([double]$Entry.Logical))))
	[void]$lines.Add(('Stored {0}' -f (Format-ByteSize ([double]$Entry.Stored))))
	[void]$lines.Add(('Gap {0}' -f (Format-FolderSizePlainCount $gap)))
	return ,$lines.ToArray()
}

function Format-MetricCompareTableLines {
	param(
		$SourceEntries,
		$BackupEntries,
		[int]$InnerWidth,
		[switch]$Plain
	)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 2
	$fit = Get-FolderSizeFitWidth $layout
	$left = New-Object System.Collections.Generic.List[object]
	$right = New-Object System.Collections.Generic.List[object]
	foreach ($entry in (Get-FolderSizeObjectList $SourceEntries)) {
		if (Test-FolderSizeMetricEntry $entry) { [void]$left.Add((Get-MetricCompareCellLines -Entry $entry -Width $fit)) }
	}
	foreach ($entry in (Get-FolderSizeObjectList $BackupEntries)) {
		if (Test-FolderSizeMetricEntry $entry) { [void]$right.Add((Get-MetricCompareCellLines -Entry $entry -Width $fit)) }
	}
	if ($left.Count -eq 0 -and $right.Count -eq 0) { return ,@('  No differences.') }
	return Format-PairedColumnLines -Layout $layout -LeftBlocks $left -RightBlocks $right -Headers @('Source', 'Backup') -Plain:$Plain
}

function Get-CrossSideCellLines {
	param($Entry, [int]$Width, [string]$Side)

	$size = $Entry.DestLogical
	if ($Side -eq 'Source') { $size = $Entry.SourceLogical }
	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add((Format-FolderSizePathCell -Path ([string]$Entry.RelativePath) -Width $Width))
	[void]$lines.Add(('{0:N0} files, {1}' -f [long]$Entry.FileCount, (Format-ByteSize ([double]$size))))
	return ,$lines.ToArray()
}

function Format-CrossTreeTableLines {
	param(
		$Entries,
		[int]$InnerWidth,
		[switch]$Plain
	)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 2
	$fit = Get-FolderSizeFitWidth $layout
	$onlySource = New-Object System.Collections.Generic.List[object]
	$onlyBackup = New-Object System.Collections.Generic.List[object]
	$mismatches = New-Object System.Collections.Generic.List[object]
	foreach ($entry in (Get-FolderSizeObjectList $Entries)) {
		if (-not (Test-FolderSizeCrossEntry $entry)) { continue }
		if ([string]$entry.State -eq 'OnlyInSource') {
			[void]$onlySource.Add((Get-CrossSideCellLines -Entry $entry -Width $fit -Side Source))
		}
		elseif ([string]$entry.State -eq 'OnlyInBackup') {
			[void]$onlyBackup.Add((Get-CrossSideCellLines -Entry $entry -Width $fit -Side Backup))
		}
		else {
			[void]$mismatches.Add($entry)
		}
	}
	if ($onlySource.Count -eq 0 -and $onlyBackup.Count -eq 0 -and $mismatches.Count -eq 0) {
		return ,@('  No differences.')
	}

	$lines = New-Object System.Collections.Generic.List[string]
	$headers = @('Source', 'Backup')
	$header = Format-FolderSizeHeaderRow -Layout $layout -Headers $headers -Plain:$Plain
	if ($null -ne $header) { [void]$lines.Add($header) }
	if ($onlySource.Count -gt 0 -or $onlyBackup.Count -gt 0) {
		foreach ($row in (Format-PairedColumnLines -Layout $layout -LeftBlocks $onlySource -RightBlocks $onlyBackup -Headers $headers -Plain:$Plain -NoHeader)) {
			[void]$lines.Add($row)
		}
	}
	$started = $false
	if ($null -ne $header) { $started = $lines.Count -gt 1 }
	else { $started = $lines.Count -gt 0 }
	foreach ($entry in $mismatches) {
		if ($started) { [void]$lines.Add('') }
		$started = $true
		$path = Format-FolderSizePathCell -Path ([string]$entry.RelativePath) -Width $fit
		$count = '{0:N0}' -f [long]$entry.FileCount
		$pairs = @(
			@{ Label = 'Path'; Left = $path; Right = $path }
			@{ Label = 'Files'; Left = $count; Right = $count }
			@{ Label = 'Logical'; Left = (Format-ByteSize ([double]$entry.SourceLogical)); Right = (Format-ByteSize ([double]$entry.DestLogical)) }
		)
		foreach ($pair in $pairs) {
			foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label $pair.Label -Cells @($pair.Left, $pair.Right) -Headers $headers)) {
				[void]$lines.Add($row)
			}
		}
	}
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
			foreach ($row in (Format-FolderSizeCompareRows -Layout $layout -Label 'bytes' -Cells @($sourceBytes, $backupBytes, $gapBytes) -Headers $headers)) {
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
		$paths = Get-FolderSizeStringList $SourcePaths
		$items = @($paths | Sort-Object)
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
			$paths = Get-FolderSizeStringList $pair.Paths
			$items = @($paths | Sort-Object)
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

	$lines = @(New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Totals' -TitleStyle Header -Rows (Format-FolderCompareTotalLines -SourceResult $Report.SourceResult -BackupResult $Report.BackupResult -InnerWidth $inner))
	$lines += ''
	$cross = Format-CrossTreeTableLines -Entries $Report.Cross -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Cross-tree' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $cross -LogPath $Report.LogPath)
	$lines += ''
	$stored = Format-MetricCompareTableLines -SourceEntries $Report.SourceMetrics -BackupEntries $Report.BackupMetrics -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Logical vs stored' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $stored -LogPath $Report.LogPath)
	$lines += ''
	$unreadable = Format-UnreadableTableLines -SourcePaths $Report.SourceUnreadable -BackupPaths $Report.BackupUnreadable -InnerWidth $inner
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Unreadable' -TitleStyle Header -Rows (Get-CappedFolderSizeLines -Lines $unreadable -LogPath $Report.LogPath)
	$lines += ''
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Result' -TitleStyle ([string]$Report.StatusStyle) -Rows $resultRows.ToArray() -WrapRows
	return $lines
}

function New-FolderCompareProgressBox {
	param(
		$Layout,
		$Source,
		$Backup,
		[string]$Status,
		$Compared,
		$Total
	)

	$table = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 2
	$headers = @('Source', 'Backup')
	$rows = New-Object System.Collections.Generic.List[string]
	[void]$rows.Add('')
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
	if ($null -ne $Total -and $null -ne $Compared) {
		[void]$rows.Add('')
		[void]$rows.Add((Format-FolderCompareBar -Layout $Layout -Done ([long]$Compared) -Total ([long]$Total)))
	}
	elseif (-not [string]::IsNullOrWhiteSpace($Status)) {
		[void]$rows.Add('')
		[void]$rows.Add((' ' + $Status))
	}
	[void]$rows.Add('')
	$title = Format-UiText -Text ' Comparing' -Style Progress
	return Format-Box -Layout $Layout -Title $title -Rows $rows.ToArray()
}

function New-FolderCompareScreenLines {
	param([int]$WindowWidth, $Progress)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	return @('') + @(New-FolderCompareProgressBox -Layout $layout -Source $Progress.Source -Backup $Progress.Backup -Status $Progress.Status -Compared $Progress.Compared -Total $Progress.Total)
}

function Get-CappedFolderSizeLines {
	param(
		[string[]]$Lines,
		[string]$LogPath
	)

	$rows = @($Lines | Where-Object { $null -ne $_ })
	if ($rows.Count -le $script:FolderSizeScreenLineCap) { return $rows }
	$shown = @($rows | Select-Object -First $script:FolderSizeScreenLineCap)
	$remaining = $rows.Count - $script:FolderSizeScreenLineCap
	$location = if ([string]::IsNullOrWhiteSpace($LogPath)) { 'the log could not be written' } else { $LogPath }
	$shown += ('  {0:N0} more lines in {1}' -f $remaining, $location)
	return $shown
}

function New-FolderSizeProgressLayout {
	param([int]$WindowWidth)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$layout | Add-Member -NotePropertyMembers @{
		SizeStr = ' Size:    '
		StoredStr = ' Stored:  '
		FilesStr = ' Files:   '
		FoldersStr = ' Folders: '
		PathStr = ' Path:    '
	} -PassThru
}

function New-FolderSizeProgressBox {
	param(
		$Layout,
		[string]$ItemPath,
		[long]$Files,
		[long]$Folders,
		[uint64]$Logical,
		[uint64]$Stored
	)

	$availableSpace = $Layout.InnerWidth - (Get-VisibleTextLength $Layout.PathStr) - 1
	$ItemPath = Format-UiPath -Path $ItemPath -Width $availableSpace
	$title = Format-UiText -Text ' Scanning' -Style Progress

	return Format-Box -Layout $Layout -Title $title -Rows @(
		''
		($Layout.SizeStr + (Format-ByteSize $Logical))
		($Layout.StoredStr + (Format-ByteSize $Stored))
		($Layout.FilesStr + ('{0:N0}' -f $Files))
		($Layout.FoldersStr + ('{0:N0}' -f $Folders))
		''
		($Layout.PathStr + $ItemPath)
		''
	)
}

function New-FolderSizeScreenLines {
	param([int]$WindowWidth, $Progress)

	$layout = New-FolderSizeProgressLayout -WindowWidth $WindowWidth
	return @('') + @(New-FolderSizeProgressBox -Layout $layout -ItemPath $Progress.CurrentPath -Files $Progress.Files -Folders $Progress.Folders -Logical $Progress.Logical -Stored $Progress.Stored)
}
