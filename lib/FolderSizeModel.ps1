function ConvertTo-FolderSizeLongPath {
	param([string]$Path)

	# \\?\E: is not a valid path. The drive root is short, so leave it as E:\.
	if ($Path -match '^(?:\\\\\?\\)?[A-Za-z]:\\?$') {
		return ($Path -replace '^\\\\\?\\', '').TrimEnd('\') + '\'
	}
	if ($Path -like '\\?\*') { return $Path }
	if ($Path -like '\\*') { return '\\?\UNC\' + $Path.TrimStart('\') }
	return '\\?\' + $Path
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

function Test-FolderSizeMetricUniform {
	param($Node)

	return ($null -ne $Node -and $Node.FileCount -gt 0 -and $Node.DifferCount -eq $Node.FileCount)
}

function Get-FolderSizeRollup {
	param(
		$DirectoryStats,
		$Differences
	)

	$entries = New-Object System.Collections.Generic.List[object]
	if ($null -eq $DirectoryStats) { return ,@() }

	foreach ($dir in @($DirectoryStats.Keys)) {
		$node = $DirectoryStats[$dir]
		if (-not (Test-FolderSizeMetricUniform $node)) { continue }
		$parent = Get-ParentRelativePath $dir
		$parentUniform = $false
		if ($null -ne $parent) {
			$parentUniform = Test-FolderSizeMetricUniform $DirectoryStats[$parent]
		}
		if ($parentUniform) { continue }
		if ($null -eq $node.FileCount -or $null -eq $node.Logical -or $null -eq $node.Stored) { continue }
		[void]$entries.Add([pscustomobject]@{
			RelativePath = [string]$dir
			FileCount = [long]$node.FileCount
			Logical = $node.Logical
			Stored = $node.Stored
		})
	}

	foreach ($diff in (Get-FolderSizeObjectList $Differences)) {
		if ($diff -is [System.Collections.DictionaryEntry]) { continue }
		if ($null -eq $diff.Logical -or $null -eq $diff.Stored) { continue }
		$parent = Get-ParentRelativePath ([string]$diff.RelativePath)
		$parentNode = $null
		if ($null -ne $parent) { $parentNode = $DirectoryStats[$parent] }
		if (Test-FolderSizeMetricUniform $parentNode) { continue }
		[void]$entries.Add([pscustomobject]@{
			RelativePath = [string]$diff.RelativePath
			FileCount = [long]1
			Logical = $diff.Logical
			Stored = $diff.Stored
		})
	}

	return ,@($entries | Sort-Object RelativePath)
}

function Test-CrossTreeUniform {
	param($Node)

	if ($null -eq $Node -or $Node.FileCount -le 0) { return $false }
	if ($Node.OnlySource -eq $Node.FileCount) { return $true }
	if ($Node.OnlyBackup -eq $Node.FileCount) { return $true }
	if ($Node.Mismatch -eq $Node.FileCount) { return $true }
	return $false
}

function Get-CrossTreeState {
	param($Node)

	if ($Node.OnlySource -eq $Node.FileCount) { return 'OnlyInSource' }
	if ($Node.OnlyBackup -eq $Node.FileCount) { return 'OnlyInBackup' }
	if ($Node.Mismatch -eq $Node.FileCount) { return 'LogicalMismatch' }
	return $null
}

function Add-CrossTreeCount {
	param(
		$Stats,
		[string]$RelativeFile,
		[string]$State,
		$SourceLogical,
		$DestLogical
	)

	foreach ($dir in (Get-FolderSizeAncestorDirectories $RelativeFile)) {
		if (-not $Stats.ContainsKey($dir)) {
			$Stats[$dir] = @{
				FileCount = 0
				OnlySource = 0
				OnlyBackup = 0
				Mismatch = 0
				SourceLogical = [uint64]0
				DestLogical = [uint64]0
			}
		}
		$node = $Stats[$dir]
		$node.FileCount = [long]$node.FileCount + 1
		if ($State -eq 'Match') { continue }
		if ($State -eq 'OnlyInSource') { $node.OnlySource = [long]$node.OnlySource + 1 }
		elseif ($State -eq 'OnlyInBackup') { $node.OnlyBackup = [long]$node.OnlyBackup + 1 }
		elseif ($State -eq 'LogicalMismatch') { $node.Mismatch = [long]$node.Mismatch + 1 }
		$node.SourceLogical = [uint64]([decimal]$node.SourceLogical + [decimal]$SourceLogical)
		$node.DestLogical = [uint64]([decimal]$node.DestLogical + [decimal]$DestLogical)
	}
}

function Get-CrossTreeRollup {
	param(
		$SourceFiles,
		$DestFiles,
		$SourceUnreadable,
		$DestUnreadable,
		[scriptblock]$OnProgress
	)

	if ($null -eq $SourceFiles) { $SourceFiles = @{} }
	if ($null -eq $DestFiles) { $DestFiles = @{} }
	$stats = @{}
	$leaves = New-Object System.Collections.Generic.List[object]
	$seen = @{}
	$compared = [long]0
	$total = [long]$SourceFiles.Count + [long]$DestFiles.Count
	$progressStep = 5000

	foreach ($rel in @($SourceFiles.Keys)) {
		$compared++
		if ($null -ne $OnProgress -and (($compared % $progressStep) -eq 0 -or $compared -eq $total)) {
			& $OnProgress $compared $total
		}
		$seen[$rel] = $true
		$sourceFile = $SourceFiles[$rel]
		if ($null -eq $sourceFile -or $null -eq $sourceFile.Logical) { continue }
		if ($DestFiles.ContainsKey($rel)) {
			$destFile = $DestFiles[$rel]
			if ($null -eq $destFile -or $null -eq $destFile.Logical) { continue }
			if ([uint64]$sourceFile.Logical -ne [uint64]$destFile.Logical) {
				Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'LogicalMismatch' -SourceLogical $sourceFile.Logical -DestLogical $destFile.Logical
				[void]$leaves.Add([pscustomobject]@{
					RelativePath = [string]$rel
					State = 'LogicalMismatch'
					FileCount = 1
					SourceLogical = $sourceFile.Logical
					DestLogical = $destFile.Logical
				})
			}
			else {
				Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'Match' -SourceLogical 0 -DestLogical 0
			}
		}
		elseif (-not (Test-FolderSizePathCovered -RelativePath $rel -Ancestors $DestUnreadable)) {
			Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'OnlyInSource' -SourceLogical $sourceFile.Logical -DestLogical 0
			[void]$leaves.Add([pscustomobject]@{
				RelativePath = [string]$rel
				State = 'OnlyInSource'
				FileCount = 1
				SourceLogical = $sourceFile.Logical
				DestLogical = [uint64]0
			})
		}
	}

	foreach ($rel in @($DestFiles.Keys)) {
		$compared++
		if ($null -ne $OnProgress -and (($compared % $progressStep) -eq 0 -or $compared -eq $total)) {
			& $OnProgress $compared $total
		}
		if ($seen.ContainsKey($rel)) { continue }
		if (Test-FolderSizePathCovered -RelativePath $rel -Ancestors $SourceUnreadable) { continue }
		$destFile = $DestFiles[$rel]
		if ($null -eq $destFile -or $null -eq $destFile.Logical) { continue }
		Add-CrossTreeCount -Stats $stats -RelativeFile $rel -State 'OnlyInBackup' -SourceLogical 0 -DestLogical $destFile.Logical
		[void]$leaves.Add([pscustomobject]@{
			RelativePath = [string]$rel
			State = 'OnlyInBackup'
			FileCount = 1
			SourceLogical = [uint64]0
			DestLogical = $destFile.Logical
		})
	}

	$entries = New-Object System.Collections.Generic.List[object]
	foreach ($dir in @($stats.Keys)) {
		$node = $stats[$dir]
		if (-not (Test-CrossTreeUniform $node)) { continue }
		$parent = Get-ParentRelativePath $dir
		$parentUniform = $false
		if ($null -ne $parent) { $parentUniform = Test-CrossTreeUniform $stats[$parent] }
		if ($parentUniform) { continue }
		$state = Get-CrossTreeState $node
		if ([string]::IsNullOrEmpty($state)) { continue }
		if ($null -eq $node.FileCount -or [long]$node.FileCount -le 0) { continue }
		[void]$entries.Add([pscustomobject]@{
			RelativePath = [string]$dir
			State = [string]$state
			FileCount = [long]$node.FileCount
			SourceLogical = $node.SourceLogical
			DestLogical = $node.DestLogical
		})
	}

	foreach ($leaf in $leaves) {
		$parent = Get-ParentRelativePath $leaf.RelativePath
		$parentNode = $null
		if ($null -ne $parent) { $parentNode = $stats[$parent] }
		if (Test-CrossTreeUniform $parentNode) { continue }
		[void]$entries.Add($leaf)
	}

	return ,@($entries | Sort-Object RelativePath, State)
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
