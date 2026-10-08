$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LibRoot = Join-Path $script:RepoRoot 'lib'

. (Join-Path $script:LibRoot 'Ui.ps1')
. (Join-Path $script:LibRoot 'Common.ps1')
. (Join-Path $script:LibRoot 'FolderSize.ps1')

# Builds a scan result shaped like the worker's. Each file is
# @(relativePath, logical, stored).
function New-TestScanResult {
	param(
		[object[]]$Files = @(),
		[object[]]$Unreadable = @(),
		[object[]]$Reparse = @(),
		[string[]]$EmptyDirectories = @()
	)

	$stats = New-FolderSizeKeyTable
	$differences = New-Object System.Collections.Generic.List[object]
	$filesByPath = New-FolderSizeKeyTable
	$directories = New-FolderSizeKeyTable
	$logical = [uint64]0
	$stored = [uint64]0
	foreach ($file in $Files) {
		Add-FolderSizeMetric -Stats $stats -Differences $differences -RelativeFile $file[0] -Logical $file[1] -Stored $file[2]
		$filesByPath[$file[0]] = [uint64]$file[1]
		$logical += [uint64]$file[1]
		$stored += [uint64]$file[2]
		foreach ($dir in (Get-FolderSizeAncestorDirectories $file[0])) {
			if (-not [string]::IsNullOrEmpty($dir)) { $directories[$dir] = $true }
		}
	}
	foreach ($dir in $EmptyDirectories) { $directories[$dir] = $true }
	return @{
		Logical = $logical
		Stored = $stored
		Files = [long]$Files.Count
		Folders = [long]$directories.Count
		Unreadable = $Unreadable
		Reparse = $Reparse
		DirectoryStats = $stats
		Differences = $differences.ToArray()
		FilesByPath = $filesByPath
		Directories = $directories
	}
}

function New-TestCompareReport {
	param(
		[string]$Source,
		[string]$Dest,
		[hashtable]$SourceResult,
		[hashtable]$BackupResult,
		$Log = @{ Path = 'C:\Temp\backup_logs\folder_size\folder-compare-test.txt'; Failures = @() }
	)

	$cross = Get-CrossTreeRollup `
		-SourceFiles $SourceResult.FilesByPath `
		-DestFiles $BackupResult.FilesByPath `
		-SourceDirectories $SourceResult.Directories `
		-DestDirectories $BackupResult.Directories `
		-SourceUnreadable (Get-FolderSizeRecordPaths $SourceResult.Unreadable) `
		-DestUnreadable (Get-FolderSizeRecordPaths $BackupResult.Unreadable)
	$verdict = Get-FolderCompareVerdict -CrossEntries $cross -UnreadableCount ($SourceResult.Unreadable.Count + $BackupResult.Unreadable.Count)
	return @{
		Status = $verdict.Status
		StatusStyle = $verdict.Style
		StoredDiffers = ($SourceResult.Logical -ne $SourceResult.Stored -or $BackupResult.Logical -ne $BackupResult.Stored)
		Source = $Source
		Dest = $Dest
		Started = [datetime]'2026-01-02 03:04:05'
		Finished = [datetime]'2026-01-02 03:09:10'
		SourceResult = $SourceResult
		BackupResult = $BackupResult
		Cross = $cross
		SourceMetrics = (Get-FolderSizeRollup -DirectoryStats $SourceResult.DirectoryStats -Differences $SourceResult.Differences)
		BackupMetrics = (Get-FolderSizeRollup -DirectoryStats $BackupResult.DirectoryStats -Differences $BackupResult.Differences)
		Log = $Log
	}
}
