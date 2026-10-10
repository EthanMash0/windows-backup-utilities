$script:FolderSizeProgressIntervalMs = 100
$script:FolderSizeLogRoot = 'C:\Temp\backup_logs\folder_size'
$script:FolderSizeLibRoot = $PSScriptRoot

foreach ($part in @('Native.ps1', 'Model.ps1', 'Scan.ps1', 'Screen.ps1', 'Log.ps1')) {
	. (Join-Path $script:FolderSizeLibRoot $part)
}

function Resolve-FolderSizeInputPath {
	param([string]$Path)

	# A relative path would become an invalid \\?\ path, and the log must show
	# where the folder really is. Resolve against the PowerShell location, not
	# the process directory.
	return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
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

	$inputPath = Resolve-FolderSizeInputPath $inputPath
	$path = ConvertTo-FolderSizeLongPath $inputPath
	Reset-UiScreen
	Add-FolderSizePathsBlock -Title $title -Rows @("  Folder: $inputPath")
	$progress = @{ Source = (New-FolderSizeSnapshot -CurrentPath $path) }
	Add-UiBlock @{ Kind = 'Custom'; Builder = ${function:New-FolderSizeScreenLines}; Data = $progress }
	$scans = [ordered]@{}

	try {
		Set-UiCursorVisible -Visible $false
		Update-UiScreen
		$started = Get-Date
		$scans.Source = Start-FolderSizeScan -Path $path
		Wait-FolderSizeScans -Scans $scans -Progress $progress
		$result = (Complete-FolderSizeScans -Scans $scans).Source
		$finished = Get-Date
		Update-UiScreen -Force

		$metricEntries = Get-FolderSizeRollup -DirectoryStats $result.DirectoryStats -Differences $result.Differences
		$logLines = Format-FolderSizeLogLines -Path $inputPath -Result $result -MetricEntries $metricEntries -Started $started -Finished $finished
		$log = Write-FolderSizeReportFile -Directories (Get-FolderSizeLogDirectories) -Prefix 'folder-size' -Lines $logLines

		Set-UiCursorVisible -Visible $true
		Write-UiLine
		Show-InfoBox -Title 'Folder Size' -Rows (Get-FolderSizeSummaryRows -Path $inputPath -Result $result -MetricCount $metricEntries.Count -Log $log)
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		Write-UiLine
		Write-ErrorMessage 'Fatal error:'
		Write-ErrorMessage $_.Exception.Message
	}
	finally {
		try { Stop-FolderSizeScans $scans }
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
	$Source = Resolve-FolderSizeInputPath $Source
	$Dest = Resolve-FolderSizeInputPath $Dest
	$sourcePath = ConvertTo-FolderSizeLongPath $Source
	$destPath = ConvertTo-FolderSizeLongPath $Dest
	Add-FolderSizePathsBlock -Title 'Folder Size Comparison' -Rows @(
		"  Source:      $Source"
		"  Destination: $Dest"
	)
	$progress = @{
		Source = (New-FolderSizeSnapshot -CurrentPath $sourcePath)
		Backup = (New-FolderSizeSnapshot -CurrentPath $destPath)
		Status = ''
		Compared = $null
		Total = $null
	}
	Add-UiBlock @{ Kind = 'Custom'; Builder = ${function:New-FolderCompareScreenLines}; Data = $progress }
	$scans = [ordered]@{}

	try {
		Set-UiCursorVisible -Visible $false
		Update-UiScreen
		$started = Get-Date
		$scans.Source = Start-FolderSizeScan -Path $sourcePath -CollectFiles
		$scans.Backup = Start-FolderSizeScan -Path $destPath -CollectFiles
		Wait-FolderSizeScans -Scans $scans -Progress $progress
		$results = Complete-FolderSizeScans -Scans $scans
		$sourceResult = $results.Source
		$backupResult = $results.Backup

		$fileCount = [long]$sourceResult.FilesByPath.Count + [long]$backupResult.FilesByPath.Count
		Update-FolderCompareBuildStatus -Progress $progress -Done 0 -Total $fileCount
		$crossEntries = Get-CrossTreeRollup `
			-SourceFiles $sourceResult.FilesByPath `
			-DestFiles $backupResult.FilesByPath `
			-SourceDirectories $sourceResult.Directories `
			-DestDirectories $backupResult.Directories `
			-SourceUnreadable (Get-FolderSizeRecordPaths $sourceResult.Unreadable) `
			-DestUnreadable (Get-FolderSizeRecordPaths $backupResult.Unreadable) `
			-OnProgress {
				param($Done, $Total)
				Update-FolderCompareBuildStatus -Progress $progress -Done $Done -Total $Total
			}
		$verdict = Get-FolderCompareVerdict -CrossEntries $crossEntries -UnreadableCount ($sourceResult.Unreadable.Count + $backupResult.Unreadable.Count)
		$report = @{
			Status = $verdict.Status
			StatusStyle = $verdict.Style
			StoredDiffers = ($sourceResult.Logical -ne $sourceResult.Stored -or $backupResult.Logical -ne $backupResult.Stored)
			Source = $Source
			Dest = $Dest
			Started = $started
			Finished = (Get-Date)
			SourceResult = $sourceResult
			BackupResult = $backupResult
			Cross = $crossEntries
			SourceMetrics = (Get-FolderSizeRollup -DirectoryStats $sourceResult.DirectoryStats -Differences $sourceResult.Differences)
			BackupMetrics = (Get-FolderSizeRollup -DirectoryStats $backupResult.DirectoryStats -Differences $backupResult.Differences)
			Log = $null
		}

		Update-FolderCompareBuildStatus -Progress $progress -Status 'Writing the log'
		$report.Log = Write-FolderSizeReportFile -Directories (Get-FolderSizeLogDirectories -Preferred $LogFolder) -Prefix 'folder-compare' -Lines (Format-FolderCompareLogLines -Report $report)

		Update-FolderCompareBuildStatus -Progress $progress -Status ''
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
		try { Stop-FolderSizeScans $scans }
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
