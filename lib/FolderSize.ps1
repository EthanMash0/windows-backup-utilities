$script:FolderSizeProgressIntervalMs = 100
$script:FolderSizeLogRoot = 'C:\Temp\backup_logs\folder_size'
$script:FolderSizeScreenLineCap = 40
$script:FolderSizeLibRoot = $PSScriptRoot

foreach ($part in @('FolderSizeNative.ps1', 'FolderSizeModel.ps1', 'FolderSizeScan.ps1', 'FolderSizeScreen.ps1', 'FolderSizeLog.ps1')) {
	. (Join-Path $script:FolderSizeLibRoot $part)
}

function Invoke-FolderSizeTool {
	Reset-UiScreen

	$title = 'Folder Size Counter'
	Show-PathHelp -Title $title

	$inputPath = Read-FolderPath -Prompt 'Path' -MustExist -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $title
	}
	if ($null -eq $inputPath) {
		return
	}

	$path = ConvertTo-FolderSizeLongPath $inputPath
	Reset-UiScreen
	$state = New-FolderSizeSnapshot -CurrentPath $path
	$shared = [hashtable]::Synchronized(@{ Snapshot = $state })
	$block = @{ Kind = 'Custom'; Builder = ${function:New-FolderSizeScreenLines}; Data = $state }
	Add-UiBlock $block
	$scan = $null

	try {
		Set-UiCursorVisible -Visible $false
		Update-UiScreen
		$scan = Start-FolderSizeScan -Path $path -Shared $shared
		while (-not $scan.Pending.IsCompleted) {
			$state = Update-FolderSizeScanDisplay -Scan $scan -Shared $shared -State $state -Block $block
			# Check for resizing even if a directory or network read is waiting.
			Update-UiScreen
			Start-Sleep -Milliseconds $script:FolderSizeProgressIntervalMs
		}
		[void]$scan.Worker.EndInvoke($scan.Pending)
		$state = $shared.Snapshot
		$block.Data = $state
		Update-UiScreen -Force
		$result = $shared.Result
		if ($null -eq $result) {
			throw 'The folder scan finished without a result.'
		}

		$metricEntries = Get-FolderSizeRollup -DirectoryStats $result.DirectoryStats -Differences $result.Differences
		$gap = [decimal]$result.Logical - [decimal]$result.Stored
		$summary = @(
			('  Path:          {0}' -f $inputPath)
			('  Logical size:  {0}' -f (Format-ByteCount $result.Logical))
			('  Stored size:   {0}' -f (Format-ByteCount $result.Stored))
			('  Gap:           {0}' -f (Format-SignedByteCount $gap))
			('  Files:         {0:N0}' -f $result.Files)
			('  Folders:       {0:N0}' -f $result.Folders)
			('  Unreadable:    {0:N0}' -f (Get-FolderSizeItemCount $result.Unreadable))
			('  Reparse:       {0:N0}' -f (Get-FolderSizeItemCount $result.Reparse))
		)
		$logLines = New-Object System.Collections.Generic.List[string]
		foreach ($row in $summary) { [void]$logLines.Add([string]$row) }
		[void]$logLines.Add('')
		[void]$logLines.Add('Logical vs stored')
		foreach ($row in (Format-MetricRecordLines -Entries $metricEntries -InnerWidth 96)) { [void]$logLines.Add([string]$row) }
		[void]$logLines.Add('')
		[void]$logLines.Add('Unreadable')
		foreach ($row in (Format-UnreadableTableLines -SourcePaths (Get-FolderSizeRecordPaths $result.Unreadable) -InnerWidth 96 -SingleTree -Plain)) { [void]$logLines.Add([string]$row) }
		[void]$logLines.Add('')
		[void]$logLines.Add('Reparse points skipped')
		foreach ($row in (Format-ReparseLogLines -SourcePaths (Get-FolderSizeRecordPaths $result.Reparse) -SingleTree)) { [void]$logLines.Add([string]$row) }
		$logPath = $null
		$logError = $null
		try {
			$logPath = Write-FolderSizeReportFile -Directory $script:FolderSizeLogRoot -Prefix 'folder-size' -Lines $logLines.ToArray()
		}
		catch {
			$logError = $_.Exception.Message
		}
		if ($logPath) { $summary += ('  Log:           {0}' -f $logPath) }
		else { $summary += ('  Log:           could not be written: {0}' -f $logError) }

		Set-UiCursorVisible -Visible $true
		Write-UiLine
		Show-InfoBox -Title 'Folder Size' -Rows $summary
		Add-UiBlock @{ Kind = 'Custom'; Builder = ${function:New-FolderSizeDetailLines}; Data = @{ Entries = $metricEntries; LogPath = $logPath } }
		Update-UiScreen -Force
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		Write-UiLine
		Write-ErrorMessage 'Fatal error:'
		Write-ErrorMessage $_.Exception.Message
	}
	finally {
		try { Stop-FolderSizeScan $scan }
		finally { Set-UiCursorVisible -Visible $true }
	}

	return 'Completed'
}

function Invoke-FolderSizeComparison {
	param(
		[string]$Source,
		[string]$Dest,
		[string]$LogFolder
	)

	Reset-UiScreen
	$sourcePath = ConvertTo-FolderSizeLongPath $Source
	$destPath = ConvertTo-FolderSizeLongPath $Dest
	$sourceState = New-FolderSizeSnapshot -CurrentPath $sourcePath
	$backupState = New-FolderSizeSnapshot -CurrentPath $destPath
	$sharedSource = [hashtable]::Synchronized(@{ Snapshot = $sourceState })
	$sharedBackup = [hashtable]::Synchronized(@{ Snapshot = $backupState })
	$progress = @{ Source = $sourceState; Backup = $backupState; Status = ''; Compared = $null; Total = $null }
	$block = @{ Kind = 'Custom'; Builder = ${function:New-FolderCompareScreenLines}; Data = $progress }
	Add-UiBlock $block
	$sourceScan = $null
	$backupScan = $null

	try {
		Set-UiCursorVisible -Visible $false
		Update-UiScreen
		$sourceScan = Start-FolderSizeScan -Path $sourcePath -Shared $sharedSource -CollectFiles
		$backupScan = Start-FolderSizeScan -Path $destPath -Shared $sharedBackup -CollectFiles
		while (-not $sourceScan.Pending.IsCompleted -or -not $backupScan.Pending.IsCompleted) {
			$sourceSnapshot = $sharedSource.Snapshot
			$backupSnapshot = $sharedBackup.Snapshot
			if (-not [object]::ReferenceEquals($progress.Source, $sourceSnapshot) -or -not [object]::ReferenceEquals($progress.Backup, $backupSnapshot)) {
				$progress.Source = $sourceSnapshot
				$progress.Backup = $backupSnapshot
				$script:UiScreen.Dirty = $true
			}
			Update-UiScreen
			Start-Sleep -Milliseconds $script:FolderSizeProgressIntervalMs
		}

		$sourceFailure = $null
		try { [void]$sourceScan.Worker.EndInvoke($sourceScan.Pending) }
		catch [System.Management.Automation.PipelineStoppedException] { throw }
		catch { $sourceFailure = $_ }
		try { [void]$backupScan.Worker.EndInvoke($backupScan.Pending) }
		catch [System.Management.Automation.PipelineStoppedException] { throw }
		catch { if ($null -eq $sourceFailure) { $sourceFailure = $_ } }
		if ($null -ne $sourceFailure) { throw $sourceFailure }

		$progress.Source = $sharedSource.Snapshot
		$progress.Backup = $sharedBackup.Snapshot
		$script:FolderCompareBuildProgress = $progress
		$sourceResult = $sharedSource.Result
		$backupResult = $sharedBackup.Result
		if ($null -eq $sourceResult -or $null -eq $backupResult) {
			throw 'A folder scan finished without a result.'
		}

		$sourceCount = 0
		$backupCount = 0
		if ($null -ne $sourceResult.FilesByPath) { $sourceCount = $sourceResult.FilesByPath.Count }
		if ($null -ne $backupResult.FilesByPath) { $backupCount = $backupResult.FilesByPath.Count }
		Update-FolderCompareBuildStatus -Done 0 -Total ([long]$sourceCount + [long]$backupCount)
		$crossEntries = Get-CrossTreeRollup -SourceFiles $sourceResult.FilesByPath -DestFiles $backupResult.FilesByPath -SourceDirectories $sourceResult.Directories -DestDirectories $backupResult.Directories -SourceUnreadable (Get-FolderSizeRecordPaths $sourceResult.Unreadable) -DestUnreadable (Get-FolderSizeRecordPaths $backupResult.Unreadable) -OnProgress {
			param($Done, $Total)
			Update-FolderCompareBuildStatus -Done $Done -Total $Total
		}
		$sourceMetrics = Get-FolderSizeRollup -DirectoryStats $sourceResult.DirectoryStats -Differences $sourceResult.Differences
		$backupMetrics = Get-FolderSizeRollup -DirectoryStats $backupResult.DirectoryStats -Differences $backupResult.Differences
		$sourceStoredGap = [decimal]$sourceResult.Logical - [decimal]$sourceResult.Stored
		$backupStoredGap = [decimal]$backupResult.Logical - [decimal]$backupResult.Stored
		$unreadableCount = (Get-FolderSizeItemCount $sourceResult.Unreadable) + (Get-FolderSizeItemCount $backupResult.Unreadable)
		$crossCount = 0
		foreach ($entry in (Get-FolderSizeObjectList $crossEntries)) {
			if (Test-FolderSizeCrossEntry $entry) { $crossCount++ }
		}
		if ($crossCount -gt 0) {
			$status = 'Source and backup differ.'
			$statusStyle = 'Error'
		}
		elseif ($unreadableCount -gt 0) {
			$status = 'Sizes match for items that could be read. Some items were skipped.'
			$statusStyle = 'Error'
		}
		else {
			$status = 'Logical sizes match.'
			$statusStyle = 'Success'
		}

		$logDirectory = if ([string]::IsNullOrWhiteSpace($LogFolder)) { $script:FolderSizeLogRoot } else { $LogFolder }
		$report = @{
			Status = $status
			StatusStyle = $statusStyle
			StoredDiffers = ($sourceStoredGap -ne 0 -or $backupStoredGap -ne 0)
			Source = $Source
			Dest = $Dest
			SourceResult = $sourceResult
			BackupResult = $backupResult
			Cross = $crossEntries
			SourceMetrics = $sourceMetrics
			BackupMetrics = $backupMetrics
			SourceUnreadable = (Get-FolderSizeRecordPaths $sourceResult.Unreadable)
			BackupUnreadable = (Get-FolderSizeRecordPaths $backupResult.Unreadable)
			SourceReparse = (Get-FolderSizeRecordPaths $sourceResult.Reparse)
			BackupReparse = (Get-FolderSizeRecordPaths $backupResult.Reparse)
			LogPath = $null
			LogError = $null
		}
		Update-FolderCompareBuildStatus -Status 'Writing the log'
		$logPath = $null
		$logError = $null
		try {
			$logPath = Write-FolderSizeReportFile -Directory $logDirectory -Prefix 'folder-compare' -Lines (Format-FolderCompareLogLines -Report $report)
		}
		catch {
			$logError = $_.Exception.Message
		}
		$report.LogPath = $logPath
		$report.LogError = $logError

		Update-FolderCompareBuildStatus -Status 'Drawing the report'
		$progress.Status = ''
		$script:FolderCompareBuildProgress = $null
		$script:UiScreen.Dirty = $true
		Set-UiCursorVisible -Visible $true
		Write-UiLine
		Add-UiBlock @{ Kind = 'Custom'; Builder = ${function:New-FolderCompareReportLines}; Data = $report }
		Update-UiScreen -Force
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		Write-UiLine
		Write-ErrorMessage 'Fatal error:'
		Write-ErrorMessage $_.Exception.Message
	}
	finally {
		try {
			Stop-FolderSizeScan $sourceScan
			Stop-FolderSizeScan $backupScan
		}
		finally { Set-UiCursorVisible -Visible $true }
	}
}

function Invoke-FolderSizeCompareTool {
	Reset-UiScreen

	$title = 'Folder Size Comparison'
	Show-PathHelp -Title $title

	$source = Read-FolderPath -Prompt 'Source' -MustExist -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $title
	}
	if ($null -eq $source) {
		return
	}

	Write-UiLine

	$dest = Read-FolderPath -Prompt 'Destination' -MustExist -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $title
		Write-UiLine -Text "Source: $source"
		Write-UiLine
	}
	if ($null -eq $dest) {
		return
	}

	Invoke-FolderSizeComparison -Source $source -Dest $dest
	return 'Completed'
}
