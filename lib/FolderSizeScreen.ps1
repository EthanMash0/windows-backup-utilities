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
	foreach ($cell in $Cells) {
		$text += $gapText + (Format-FolderSizePad -Text ([string]$cell) -Width ([int]$Layout.CellWidth))
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
		[string[]]$Cells,
		[string[]]$Headers
	)

	$lines = New-Object System.Collections.Generic.List[string]
	if ($Layout.SideBySide) {
		[void]$lines.Add((Format-FolderSizeTableRow -Layout $Layout -Label $Label -Cells $Cells))
	}
	else {
		if (-not [string]::IsNullOrEmpty($Label)) { [void]$lines.Add((' ' + $Label)) }
		$single = New-FolderSizeTextLayout -InnerWidth ([int]$Layout.InnerWidth) -ValueColumns 1
		for ($i = 0; $i -lt $Cells.Count; $i++) {
			$header = ''
			if ($null -ne $Headers -and $i -lt $Headers.Count) { $header = $Headers[$i] }
			[void]$lines.Add((Format-FolderSizeTableRow -Layout $single -Label $header -Cells $Cells[$i]))
		}
	}
	return ,$lines.ToArray()
}

function Format-FolderSizeHeaderRow {
	param(
		$Layout,
		[string[]]$Headers
	)

	if (-not $Layout.SideBySide) { return $null }
	$cells = New-Object System.Collections.Generic.List[string]
	foreach ($header in $Headers) { [void]$cells.Add((Format-UiText -Text $header -Style Secondary)) }
	return (Format-FolderSizeTableRow -Layout $Layout -Label '' -Cells $cells.ToArray())
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
	foreach ($row in $Rows) { [void]$body.Add([string]$row) }
	[void]$body.Add('')
	return Format-Box -Layout $layout -Title $titleText -Rows $body.ToArray() -WrapRows:$WrapRows
}

function Get-FolderSizeLogNotes {
	param($Log)

	$notes = New-Object System.Collections.Generic.List[string]
	if ($Log.Path) { [void]$notes.Add(('Log: {0}' -f $Log.Path)) }
	else { [void]$notes.Add('The log could not be written.') }
	foreach ($failure in $Log.Failures) { [void]$notes.Add(('Could not write the log to {0}' -f $failure)) }
	return ,$notes.ToArray()
}

function New-FolderSizePathsLines {
	param([int]$WindowWidth, $Data)

	# Laid out like the Confirm Copy details: full paths, wrapped, never shortened.
	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$title = Format-UiText -Text ('  ' + $Data.Title) -Style Header
	return @('') + @(Format-Box -Layout $layout -Title $title -Rows $Data.Rows -WrapRows)
}

function Add-FolderSizePathsBlock {
	param(
		[string]$Title,
		[string[]]$Rows
	)

	Add-UiBlock @{ Kind = 'Custom'; Static = $true; Builder = ${function:New-FolderSizePathsLines}; Data = @{ Title = $Title; Rows = $Rows } }
}

# =============================================================================
#  Single-folder screens
# =============================================================================

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
	$scan = $Progress.Source
	return @('') + @(New-FolderSizeProgressBox -Layout $layout -ItemPath $scan.CurrentPath -Files $scan.Files -Folders $scan.Folders -Logical $scan.Logical -Stored $scan.Stored)
}

function Get-FolderSizeSummaryRows {
	param(
		[string]$Path,
		[hashtable]$Result,
		[long]$MetricCount,
		$Log
	)

	$gap = [decimal]$Result.Logical - [decimal]$Result.Stored
	$rows = New-Object System.Collections.Generic.List[string]
	[void]$rows.Add(('  Path:          {0}' -f $Path))
	[void]$rows.Add(('  Logical size:  {0}' -f (Format-ByteSizeDetail $Result.Logical -Exact)))
	[void]$rows.Add(('  Stored size:   {0}' -f (Format-ByteSizeDetail $Result.Stored -Exact)))
	[void]$rows.Add(('  Gap:           {0}' -f (Format-ByteSizeDetail $gap -Exact)))
	[void]$rows.Add(('  Files:         {0:N0}' -f $Result.Files))
	[void]$rows.Add(('  Folders:       {0:N0}' -f $Result.Folders))
	[void]$rows.Add(('  Unreadable:    {0:N0}' -f $Result.Unreadable.Count))
	[void]$rows.Add(('  Reparse:       {0:N0}' -f $Result.Reparse.Count))
	[void]$rows.Add('')
	if ($Log.Path) {
		[void]$rows.Add(('  Details in log: {0:N0} logical vs stored, {1:N0} unreadable, {2:N0} reparse points.' -f $MetricCount, $Result.Unreadable.Count, $Result.Reparse.Count))
	}
	foreach ($note in (Get-FolderSizeLogNotes $Log)) { [void]$rows.Add(('  ' + $note)) }
	return ,$rows.ToArray()
}

# =============================================================================
#  Comparison screens
# =============================================================================

function Update-FolderCompareBuildStatus {
	param(
		[hashtable]$Progress,
		[string]$Status,
		$Done,
		$Total
	)

	$Progress.Status = $Status
	if ($null -eq $Done -or $null -eq $Total) {
		$Progress.Compared = $null
		$Progress.Total = $null
	}
	else {
		$Progress.Compared = [long]$Done
		$Progress.Total = [long]$Total
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
	return $label + (Format-UiProgressBar -Percent $percent -BarWidth $barWidth) + ' ' + $percentText
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

function Format-FolderCompareTotalLines {
	param(
		$Rows,
		[int]$InnerWidth
	)

	$layout = New-FolderSizeTextLayout -InnerWidth $InnerWidth -ValueColumns 3
	$headers = @('Source', 'Backup', 'Gap')
	$lines = New-Object System.Collections.Generic.List[string]
	$header = Format-FolderSizeHeaderRow -Layout $layout -Headers $headers
	if ($null -ne $header) { [void]$lines.Add($header) }
	foreach ($row in $Rows) {
		if ($row.Kind -eq 'Bytes') {
			$cells = @((Format-ByteSizeDetail $row.Source), (Format-ByteSizeDetail $row.Backup), (Format-ByteSizeDetail $row.Gap))
		}
		else {
			$cells = @(('{0:N0}' -f $row.Source), ('{0:N0}' -f $row.Backup), ('{0:N0}' -f $row.Gap))
		}
		foreach ($line in (Format-FolderSizeCompareRows -Layout $layout -Label $row.Name -Cells $cells -Headers $headers)) {
			[void]$lines.Add($line)
		}
	}
	return ,$lines.ToArray()
}

function Get-FolderCompareResultRows {
	param([hashtable]$Report)

	$rows = New-Object System.Collections.Generic.List[string]
	[void]$rows.Add(('  ' + (Format-UiText -Text ([string]$Report.Status) -Style ([string]$Report.StatusStyle))))
	foreach ($note in (Get-FolderCompareResultNotes -Report $Report)) { [void]$rows.Add(('  ' + $note)) }
	if ($Report.Log.Path) {
		$metricCount = $Report.SourceMetrics.Count + $Report.BackupMetrics.Count
		$unreadableCount = $Report.SourceResult.Unreadable.Count + $Report.BackupResult.Unreadable.Count
		[void]$rows.Add(('  Details in log: {0:N0} cross-tree, {1:N0} logical vs stored, {2:N0} unreadable.' -f $Report.Cross.Count, $metricCount, $unreadableCount))
	}
	foreach ($note in (Get-FolderSizeLogNotes $Report.Log)) { [void]$rows.Add(('  ' + $note)) }
	return ,$rows.ToArray()
}

function New-FolderCompareReportLines {
	param([int]$WindowWidth, $Report)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$totals = Get-FolderCompareTotalRows -SourceResult $Report.SourceResult -BackupResult $Report.BackupResult
	$lines = @(New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Totals' -TitleStyle Header -Rows (Format-FolderCompareTotalLines -Rows $totals -InnerWidth ([int]$layout.InnerWidth)))
	$lines += ''
	$lines += New-FolderSizeSectionBox -WindowWidth $WindowWidth -Title 'Result' -TitleStyle ([string]$Report.StatusStyle) -Rows (Get-FolderCompareResultRows -Report $Report) -WrapRows
	return $lines
}
