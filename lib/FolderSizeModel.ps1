function ConvertTo-FolderSizeLongPath {
	param([string]$Path)

	# \\?\E: is not a valid path. The drive root is short, so leave it as E:\.
	if ($Path -match '^(?:\\\\\?\\)?[A-Za-z]:\\?$') {
		return ($Path -replace '^\\\\\?\\', '').TrimEnd('\') + '\'
	}
	if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path }
	if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $Path.TrimStart('\') }
	return '\\?\' + $Path
}

function Get-FolderSizeComparablePath {
	param([string]$Path)

	if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
		return '\\' + $Path.Substring(8)
	}
	if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) {
		return $Path.Substring(4)
	}
	return $Path
}

function Get-FolderSizeRelativePath {
	param(
		[string]$RootDisplay,
		[string]$FullName
	)

	$display = (Get-FolderSizeComparablePath $FullName).TrimEnd('\')
	if ($display.Equals($RootDisplay, [StringComparison]::OrdinalIgnoreCase)) { return '' }
	$prefix = $RootDisplay + '\'
	if ($display.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
		return $display.Substring($prefix.Length)
	}
	return $display
}

function Join-FolderSizeDisplayPath {
	param(
		[string]$Root,
		[AllowEmptyString()]
		[string]$Relative
	)

	if ([string]::IsNullOrEmpty($Relative)) { return $Root }
	return $Root.TrimEnd('\') + '\' + $Relative
}

function New-FolderSizeKeyTable {
	# NTFS compares names without regard to case.
	return [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
}

function Get-FolderSizeErrorMessage {
	param($ErrorRecord)

	$exception = $ErrorRecord.Exception
	if ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) {
		$exception = $exception.InnerException
	}
	return $exception.Message
}

function Get-ParentRelativePath {
	param([string]$RelativePath)

	if ([string]::IsNullOrEmpty($RelativePath)) { return $null }
	$index = $RelativePath.LastIndexOf('\')
	if ($index -lt 0) { return '' }
	return $RelativePath.Substring(0, $index)
}

function Get-FolderSizeAncestorDirectories {
	param([string]$RelativeFile)

	$ancestors = New-Object System.Collections.Generic.List[string]
	[void]$ancestors.Add('')
	$parent = Get-ParentRelativePath $RelativeFile
	if (-not [string]::IsNullOrEmpty($parent)) {
		$built = ''
		foreach ($part in $parent.Split('\')) {
			if ($built.Length -gt 0) { $built = $built + '\' + $part }
			else { $built = $part }
			[void]$ancestors.Add($built)
		}
	}
	# Keep a one-item list intact. An unwrapped return would drop the root entry.
	return ,$ancestors.ToArray()
}

function Add-FolderSizeMetric {
	param(
		[hashtable]$Stats,
		[System.Collections.Generic.List[object]]$Differences,
		[string]$RelativeFile,
		[uint64]$Logical,
		[uint64]$Stored
	)

	$differs = $Logical -ne $Stored
	foreach ($dir in (Get-FolderSizeAncestorDirectories $RelativeFile)) {
		$node = $Stats[$dir]
		if ($null -eq $node) {
			$node = @{ FileCount = [long]0; DifferCount = [long]0; Logical = [uint64]0; Stored = [uint64]0 }
			$Stats[$dir] = $node
		}
		$node.FileCount = [long]$node.FileCount + 1
		$node.Logical = [uint64]$node.Logical + $Logical
		$node.Stored = [uint64]$node.Stored + $Stored
		if ($differs) { $node.DifferCount = [long]$node.DifferCount + 1 }
	}
	if ($differs) {
		[void]$Differences.Add(@{ RelativePath = $RelativeFile; Logical = $Logical; Stored = $Stored })
	}
}

function Get-FolderSizeObjectList {
	param($Value)

	# @() enumerates a hashtable into dictionary entries, and a one-item array
	# stored on the worker result comes back as that one item. Neither should
	# be treated as a list of difference records.
	$list = New-Object System.Collections.Generic.List[object]
	if ($null -eq $Value) { return ,$list.ToArray() }
	if ($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
		[void]$list.Add($Value)
		return ,$list.ToArray()
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		foreach ($item in $Value) {
			if ($null -eq $item -or $item -is [System.Collections.DictionaryEntry]) { continue }
			[void]$list.Add($item)
		}
		return ,$list.ToArray()
	}
	[void]$list.Add($Value)
	return ,$list.ToArray()
}

function Get-FolderSizeStringList {
	param($Value)

	# A [string[]] parameter turns $null into one empty string, which then
	# displays as a path and also covers every child in the unreadable test.
	$list = New-Object System.Collections.Generic.List[string]
	if ($null -eq $Value) { return ,$list.ToArray() }
	if ($Value -is [string]) {
		[void]$list.Add($Value)
		return ,$list.ToArray()
	}
	if ($Value -is [System.Collections.IEnumerable]) {
		foreach ($item in $Value) {
			if ($null -ne $item) { [void]$list.Add([string]$item) }
		}
	}
	return ,$list.ToArray()
}

function Test-FolderSizePathCovered {
	param(
		[string]$RelativePath,
		$Ancestors
	)

	foreach ($ancestor in (Get-FolderSizeStringList $Ancestors)) {
		if ([string]::IsNullOrEmpty($ancestor)) { return $true }
		if ($RelativePath -eq $ancestor) { return $true }
		if (-not [string]::IsNullOrEmpty($RelativePath) -and $RelativePath.StartsWith($ancestor + '\', [StringComparison]::OrdinalIgnoreCase)) {
			return $true
		}
	}
	return $false
}

function Get-FolderSizeRecordPaths {
	param($Records)

	$paths = New-Object System.Collections.Generic.List[string]
	foreach ($record in $Records) { [void]$paths.Add([string]$record.RelativePath) }
	return ,$paths.ToArray()
}

function Select-FolderSizeUniformRollup {
	param(
		[hashtable]$Stats,
		$Leaves,
		[scriptblock]$GetUniformState
	)

	# A uniform folder stands in for everything under it, so list it only
	# when its parent is not uniform too. A file is listed only when its
	# folder was not.
	$entries = New-Object System.Collections.Generic.List[object]
	$states = New-FolderSizeKeyTable
	if ($null -ne $Stats) {
		foreach ($dir in @($Stats.Keys)) {
			$state = & $GetUniformState $Stats[$dir]
			if ($null -ne $state) { $states[$dir] = [string]$state }
		}
	}
	foreach ($dir in @($states.Keys)) {
		$parent = Get-ParentRelativePath $dir
		if ($null -ne $parent -and $states.ContainsKey($parent)) { continue }
		$entry = [ordered]@{ RelativePath = [string]$dir; State = $states[$dir] }
		$node = $Stats[$dir]
		foreach ($key in $node.Keys) { $entry[$key] = $node[$key] }
		[void]$entries.Add([pscustomobject]$entry)
	}
	foreach ($leaf in $Leaves) {
		$parent = Get-ParentRelativePath ([string]$leaf.RelativePath)
		if ($null -ne $parent -and $states.ContainsKey($parent)) { continue }
		[void]$entries.Add($leaf)
	}
	return ,@($entries | Sort-Object RelativePath, State)
}

function Get-FolderSizeMetricState {
	param($Node)

	if ($Node.FileCount -gt 0 -and $Node.DifferCount -eq $Node.FileCount) { return 'Differs' }
	return $null
}

function Get-FolderSizeRollup {
	param(
		[hashtable]$DirectoryStats,
		$Differences
	)

	$leaves = New-Object System.Collections.Generic.List[object]
	foreach ($difference in $Differences) {
		[void]$leaves.Add([pscustomobject]@{
			RelativePath = [string]$difference.RelativePath
			State = 'Differs'
			FileCount = [long]1
			Logical = [uint64]$difference.Logical
			Stored = [uint64]$difference.Stored
		})
	}
	return Select-FolderSizeUniformRollup -Stats $DirectoryStats -Leaves $leaves -GetUniformState ${function:Get-FolderSizeMetricState}
}

function Get-CrossTreeState {
	param($Node)

	if ($Node.FileCount -le 0) { return $null }
	if ($Node.OnlySource -eq $Node.FileCount) { return 'OnlyInSource' }
	if ($Node.OnlyBackup -eq $Node.FileCount) { return 'OnlyInBackup' }
	if ($Node.Mismatch -eq $Node.FileCount) { return 'LogicalMismatch' }
	return $null
}

function New-CrossTreeEntry {
	param(
		[string]$RelativePath,
		[string]$State,
		[long]$FileCount,
		[uint64]$SourceLogical,
		[uint64]$DestLogical
	)

	return [pscustomobject]@{
		RelativePath = $RelativePath
		State = $State
		FileCount = $FileCount
		SourceLogical = $SourceLogical
		DestLogical = $DestLogical
	}
}

function Add-CrossTreeCount {
	param(
		[hashtable]$Stats,
		[string]$RelativeFile,
		[string]$State,
		[uint64]$SourceLogical,
		[uint64]$DestLogical
	)

	foreach ($dir in (Get-FolderSizeAncestorDirectories $RelativeFile)) {
		$node = $Stats[$dir]
		if ($null -eq $node) {
			$node = @{
				FileCount = [long]0
				OnlySource = [long]0
				OnlyBackup = [long]0
				Mismatch = [long]0
				SourceLogical = [uint64]0
				DestLogical = [uint64]0
			}
			$Stats[$dir] = $node
		}
		$node.FileCount = [long]$node.FileCount + 1
		if ($State -eq 'Match') { continue }
		if ($State -eq 'OnlyInSource') { $node.OnlySource = [long]$node.OnlySource + 1 }
		elseif ($State -eq 'OnlyInBackup') { $node.OnlyBackup = [long]$node.OnlyBackup + 1 }
		elseif ($State -eq 'LogicalMismatch') { $node.Mismatch = [long]$node.Mismatch + 1 }
		$node.SourceLogical = [uint64]$node.SourceLogical + $SourceLogical
		$node.DestLogical = [uint64]$node.DestLogical + $DestLogical
	}
}

function Get-CrossTreeFolderEntries {
	param(
		[hashtable]$Directories,
		[hashtable]$OtherDirectories,
		$OtherUnreadable,
		[hashtable]$Stats,
		$Reported,
		[string]$State
	)

	# A folder with files under it is already covered by the file rollup, so
	# this only adds folders that hold no files at all on the side that has them.
	$entries = New-Object System.Collections.Generic.List[object]
	foreach ($dir in @($Directories.Keys)) {
		if ($OtherDirectories.ContainsKey($dir)) { continue }
		if ($Stats.ContainsKey($dir)) { continue }
		$parent = Get-ParentRelativePath $dir
		if (-not [string]::IsNullOrEmpty($parent) -and -not $OtherDirectories.ContainsKey($parent)) { continue }
		if (Test-FolderSizePathCovered -RelativePath $dir -Ancestors $OtherUnreadable) { continue }
		if (Test-FolderSizePathCovered -RelativePath $dir -Ancestors $Reported) { continue }
		[void]$entries.Add((New-CrossTreeEntry -RelativePath $dir -State $State -FileCount 0 -SourceLogical 0 -DestLogical 0))
	}
	return ,$entries.ToArray()
}

function Get-CrossTreeRollup {
	param(
		[hashtable]$SourceFiles,
		[hashtable]$DestFiles,
		[hashtable]$SourceDirectories,
		[hashtable]$DestDirectories,
		$SourceUnreadable,
		$DestUnreadable,
		[scriptblock]$OnProgress
	)

	if ($null -eq $SourceFiles) { $SourceFiles = New-FolderSizeKeyTable }
	if ($null -eq $DestFiles) { $DestFiles = New-FolderSizeKeyTable }
	if ($null -eq $SourceDirectories) { $SourceDirectories = New-FolderSizeKeyTable }
	if ($null -eq $DestDirectories) { $DestDirectories = New-FolderSizeKeyTable }
	$stats = New-FolderSizeKeyTable
	$leaves = New-Object System.Collections.Generic.List[object]
	$compared = [long]0
	$total = [long]$SourceFiles.Count + [long]$DestFiles.Count
	$progressStep = 5000

	foreach ($rel in @($SourceFiles.Keys)) {
		$compared++
		if ($null -ne $OnProgress -and (($compared % $progressStep) -eq 0 -or $compared -eq $total)) {
			& $OnProgress $compared $total
		}
		$sourceLogical = [uint64]$SourceFiles[$rel]
		$destLogical = [uint64]0
		if ($DestFiles.ContainsKey($rel)) {
			$destLogical = [uint64]$DestFiles[$rel]
			if ($sourceLogical -eq $destLogical) {
				Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'Match' -SourceLogical 0 -DestLogical 0
				continue
			}
			$state = 'LogicalMismatch'
		}
		elseif (Test-FolderSizePathCovered -RelativePath $rel -Ancestors $DestUnreadable) { continue }
		else { $state = 'OnlyInSource' }
		Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State $state -SourceLogical $sourceLogical -DestLogical $destLogical
		[void]$leaves.Add((New-CrossTreeEntry -RelativePath $rel -State $state -FileCount 1 -SourceLogical $sourceLogical -DestLogical $destLogical))
	}

	foreach ($rel in @($DestFiles.Keys)) {
		$compared++
		if ($null -ne $OnProgress -and (($compared % $progressStep) -eq 0 -or $compared -eq $total)) {
			& $OnProgress $compared $total
		}
		if ($SourceFiles.ContainsKey($rel)) { continue }
		if (Test-FolderSizePathCovered -RelativePath $rel -Ancestors $SourceUnreadable) { continue }
		$destLogical = [uint64]$DestFiles[$rel]
		Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'OnlyInBackup' -SourceLogical 0 -DestLogical $destLogical
		[void]$leaves.Add((New-CrossTreeEntry -RelativePath $rel -State 'OnlyInBackup' -FileCount 1 -SourceLogical 0 -DestLogical $destLogical))
	}

	$entries = New-Object System.Collections.Generic.List[object]
	foreach ($entry in (Select-FolderSizeUniformRollup -Stats $stats -Leaves $leaves -GetUniformState ${function:Get-CrossTreeState})) {
		[void]$entries.Add($entry)
	}
	$reported = @(foreach ($entry in $entries) { [string]$entry.RelativePath })
	foreach ($entry in (Get-CrossTreeFolderEntries -Directories $SourceDirectories -OtherDirectories $DestDirectories -OtherUnreadable $DestUnreadable -Stats $stats -Reported $reported -State 'OnlyInSource')) {
		[void]$entries.Add($entry)
	}
	foreach ($entry in (Get-CrossTreeFolderEntries -Directories $DestDirectories -OtherDirectories $SourceDirectories -OtherUnreadable $SourceUnreadable -Stats $stats -Reported $reported -State 'OnlyInBackup')) {
		[void]$entries.Add($entry)
	}
	return ,@($entries | Sort-Object RelativePath, State)
}

function Get-FolderCompareVerdict {
	param(
		$CrossEntries,
		[long]$UnreadableCount
	)

	if ($null -ne $CrossEntries -and $CrossEntries.Count -gt 0) {
		return @{ Status = 'Source and backup differ.'; Style = 'Error' }
	}
	if ($UnreadableCount -gt 0) {
		return @{ Status = 'Sizes match for items that could be read. Some items were skipped.'; Style = 'Error' }
	}
	return @{ Status = 'Logical sizes match.'; Style = 'Success' }
}

function Get-FolderCompareTotalRows {
	param(
		[hashtable]$SourceResult,
		[hashtable]$BackupResult
	)

	$rows = New-Object System.Collections.Generic.List[object]
	foreach ($metric in @(
		@{ Name = 'Logical'; Kind = 'Bytes'; Source = $SourceResult.Logical; Backup = $BackupResult.Logical }
		@{ Name = 'Stored'; Kind = 'Bytes'; Source = $SourceResult.Stored; Backup = $BackupResult.Stored }
		@{ Name = 'Files'; Kind = 'Count'; Source = $SourceResult.Files; Backup = $BackupResult.Files }
		@{ Name = 'Folders'; Kind = 'Count'; Source = $SourceResult.Folders; Backup = $BackupResult.Folders }
		@{ Name = 'Unreadable'; Kind = 'Count'; Source = $SourceResult.Unreadable.Count; Backup = $BackupResult.Unreadable.Count }
		@{ Name = 'Reparse'; Kind = 'Count'; Source = $SourceResult.Reparse.Count; Backup = $BackupResult.Reparse.Count }
	)) {
		$source = [decimal]$metric.Source
		$backup = [decimal]$metric.Backup
		[void]$rows.Add([pscustomobject]@{
			Name = $metric.Name
			Kind = $metric.Kind
			Source = $source
			Backup = $backup
			Gap = $source - $backup
		})
	}
	return ,$rows.ToArray()
}

function Select-ShallowestPaths {
	param($Paths)

	$items = Get-FolderSizeStringList $Paths
	if ($null -eq $items) { return ,@() }
	$ordered = @($items | Sort-Object { if ([string]::IsNullOrEmpty($_)) { -1 } else { $_.Length } }, { $_ })
	$kept = New-Object System.Collections.Generic.List[string]
	foreach ($path in $ordered) {
		if ($null -eq $path) { continue }
		$covered = $false
		foreach ($parent in $kept) {
			if ([string]::IsNullOrEmpty($parent) -or $path -eq $parent) {
				$covered = $true
				break
			}
			if (-not [string]::IsNullOrEmpty($path) -and $path.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
				$covered = $true
				break
			}
		}
		if (-not $covered) { [void]$kept.Add([string]$path) }
	}
	return ,$kept.ToArray()
}

function Get-FolderSizeItemCount {
	param($Value)

	# A one-item or empty array stored on the worker result is unwrapped when
	# the main thread reads it back: one item arrives as that item, and an
	# empty array arrives as $null.
	if ($null -eq $Value) { return 0 }
	if ($Value -is [System.Array]) { return $Value.Length }
	return 1
}

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
