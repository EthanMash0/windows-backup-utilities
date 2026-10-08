function New-FolderSizeSnapshot {
	param([string]$CurrentPath)

	return @{
		Files = [long]0
		Folders = [long]0
		Logical = [uint64]0
		Stored = [uint64]0
		CurrentPath = $CurrentPath
	}
}

function Start-FolderSizeScan {
	param(
		[string]$Path,
		[hashtable]$Shared,
		[switch]$CollectFiles
	)

	Initialize-FolderSizeNative
	$worker = [PowerShell]::Create()
	try {
		# A new runspace cannot call the functions in this file. The walk,
		# relative paths, and directory stats stay inside this scriptblock.
		# Nothing in the worker writes to the console.
		[void]$worker.AddScript({
			param($ScanPath, $Shared, $Interval, $CollectFiles)

			function ConvertTo-WorkerLongPath {
				param([string]$Path)
				# \\?\E: is not a valid path. The drive root is short, so leave it as E:\.
				if ($Path -match '^(?:\\\\\?\\)?[A-Za-z]:\\?$') {
					return ($Path -replace '^\\\\\?\\', '').TrimEnd('\') + '\'
				}
				if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { return $Path }
				if ($Path.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)) {
					return '\\?\UNC\' + $Path.TrimStart('\')
				}
				return '\\?\' + $Path
			}

			function Get-WorkerComparablePath {
				param([string]$Path)
				if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
					return '\\' + $Path.Substring(8)
				}
				if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
					return $Path.Substring(4)
				}
				return $Path
			}

			function Get-WorkerRelativePath {
				param([string]$FullName)
				$display = (Get-WorkerComparablePath $FullName).TrimEnd('\')
				if ($display.Equals($script:WorkerRootDisplay, [StringComparison]::OrdinalIgnoreCase)) { return '' }
				$prefix = $script:WorkerRootDisplay + '\'
				if ($display.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
					return $display.Substring($prefix.Length)
				}
				return $display
			}

			function Publish-WorkerSnapshot {
				$script:ScanShared.Snapshot = @{
					Files = $script:ScanFiles
					Folders = $script:ScanFolders
					Logical = $script:ScanLogical
					Stored = $script:ScanStored
					CurrentPath = $script:ScanCurrentPath
				}
			}

			function Update-WorkerClock {
				if ($script:ScanClock.ElapsedMilliseconds -ge $script:ScanInterval) {
					Publish-WorkerSnapshot
					$script:ScanClock.Restart()
				}
			}

			function Add-WorkerMetric {
				param([string]$RelativeFile, [uint64]$Logical, [uint64]$Stored)
				$differs = $Logical -ne $Stored
				$dirs = New-Object System.Collections.Generic.List[string]
				[void]$dirs.Add('')
				$parent = ''
				$slash = $RelativeFile.LastIndexOf('\')
				if ($slash -ge 0) { $parent = $RelativeFile.Substring(0, $slash) }
				if ($parent.Length -gt 0) {
					$built = ''
					foreach ($part in $parent.Split('\')) {
						if ($built.Length -gt 0) { $built = $built + '\' + $part }
						else { $built = $part }
						[void]$dirs.Add($built)
					}
				}
				foreach ($dir in $dirs) {
					if (-not $script:Stats.ContainsKey($dir)) {
						$script:Stats[$dir] = @{
							FileCount = [long]0
							DifferCount = [long]0
							Logical = [uint64]0
							Stored = [uint64]0
						}
					}
					$node = $script:Stats[$dir]
					$node.FileCount = [long]$node.FileCount + 1
					$node.Logical = [uint64]([decimal]$node.Logical + [decimal]$Logical)
					$node.Stored = [uint64]([decimal]$node.Stored + [decimal]$Stored)
					if ($differs) { $node.DifferCount = [long]$node.DifferCount + 1 }
				}
				if ($differs) {
					[void]$script:Differences.Add(@{
						RelativePath = $RelativeFile
						Logical = $Logical
						Stored = $Stored
					})
				}
				if ($null -ne $script:FilesByPath) {
					$script:FilesByPath[$RelativeFile] = @{ Logical = $Logical; Stored = $Stored }
				}
			}

			function Measure-WorkerFile {
				param($Entry, [string]$FullName, [bool]$IsReparse)
				try {
					$native = ConvertTo-WorkerLongPath $FullName
					# Directory junctions are skipped before this runs. A file
					# reparse point is skipped only when it is a symlink, so a
					# cloud placeholder is still measured.
					if ($IsReparse -and [FolderSizeNative]::IsSymlinkOrJunction($native)) {
						[void]$script:ReparsePaths.Add((Get-WorkerRelativePath $FullName))
						return
					}
					$stored = [uint64]([FolderSizeNative]::StoredSize($native))
					$logical = [uint64]$Entry.Length
					$relative = Get-WorkerRelativePath $FullName
					$script:ScanFiles = [long]$script:ScanFiles + 1
					$script:ScanLogical = [uint64]([decimal]$script:ScanLogical + [decimal]$logical)
					$script:ScanStored = [uint64]([decimal]$script:ScanStored + [decimal]$stored)
					Add-WorkerMetric -RelativeFile $relative -Logical $logical -Stored $stored
				}
				catch {
					[void]$script:UnreadablePaths.Add((Get-WorkerRelativePath $FullName))
				}
			}

			$script:ScanFiles = [long]0
			$script:ScanFolders = [long]0
			$script:ScanLogical = [uint64]0
			$script:ScanStored = [uint64]0
			$script:ScanCurrentPath = $ScanPath
			$script:Stats = @{}
			$script:Differences = New-Object System.Collections.Generic.List[object]
			$script:ReparsePaths = New-Object System.Collections.Generic.List[string]
			$script:UnreadablePaths = New-Object System.Collections.Generic.List[string]
			$script:FilesByPath = $null
			if ($CollectFiles) { $script:FilesByPath = @{} }
			$script:WorkerRootDisplay = (Get-WorkerComparablePath $ScanPath).TrimEnd('\')
			$script:ScanShared = $Shared
			$script:ScanInterval = $Interval
			$script:ScanClock = [System.Diagnostics.Stopwatch]::StartNew()

			$walk = $true
			try {
				# DirectoryInfo rejects the \\?\ prefix on .NET Framework. Get-Item accepts it.
				$rootItem = Get-Item -LiteralPath $ScanPath -Force -ErrorAction Stop
				if (-not $rootItem.PSIsContainer) {
					[void]$script:UnreadablePaths.Add('')
					$walk = $false
				}
				elseif (([int]$rootItem.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
					[void]$script:ReparsePaths.Add('')
					$walk = $false
				}
			}
			catch {
				[void]$script:UnreadablePaths.Add('')
				$walk = $false
			}

			if ($walk) {
				$pending = New-Object 'System.Collections.Generic.Stack[string]'
				$pending.Push($ScanPath)
				while ($pending.Count -gt 0) {
					$dir = $pending.Pop()
					$script:ScanCurrentPath = $dir
					Update-WorkerClock
					try {
						# EnumerateFileSystemInfos treats \\?\ as an illegal path and
						# would leave every total at 0. Get-ChildItem -LiteralPath does not.
						foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
							$fullName = ConvertTo-WorkerLongPath $entry.FullName
							$script:ScanCurrentPath = $fullName
							$isReparse = $false
							try {
								$isReparse = (([int]$entry.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
							}
							catch {
								[void]$script:UnreadablePaths.Add((Get-WorkerRelativePath $fullName))
								Update-WorkerClock
								continue
							}
							if ($entry.PSIsContainer) {
								if ($isReparse) {
									[void]$script:ReparsePaths.Add((Get-WorkerRelativePath $fullName))
								}
								else {
									$script:ScanFolders = [long]$script:ScanFolders + 1
									$pending.Push($fullName)
								}
							}
							else {
								Measure-WorkerFile -Entry $entry -FullName $fullName -IsReparse $isReparse
							}
							Update-WorkerClock
						}
					}
					catch {
						[void]$script:UnreadablePaths.Add((Get-WorkerRelativePath $dir))
					}
				}
			}

			Publish-WorkerSnapshot
			$script:ScanShared.Result = @{
				Logical = $script:ScanLogical
				Stored = $script:ScanStored
				Files = $script:ScanFiles
				Folders = $script:ScanFolders
				Reparse = $script:ReparsePaths.ToArray()
				Unreadable = $script:UnreadablePaths.ToArray()
				DirectoryStats = $script:Stats
				Differences = $script:Differences.ToArray()
				FilesByPath = $script:FilesByPath
			}
		}).AddArgument($Path).AddArgument($Shared).AddArgument($script:FolderSizeProgressIntervalMs).AddArgument([bool]$CollectFiles)
		return @{ Worker = $worker; Pending = $worker.BeginInvoke() }
	}
	catch {
		$worker.Dispose()
		throw
	}
}

function Stop-FolderSizeScan {
	param($Scan)

	if ($null -eq $Scan) { return }
	try {
		if (-not $Scan.Pending.IsCompleted) { $Scan.Worker.Stop() }
	}
	finally { $Scan.Worker.Dispose() }
}

function Update-FolderSizeScanDisplay {
	param(
		$Scan,
		[hashtable]$Shared,
		$State,
		$Block
	)

	if ($null -eq $Scan) { return $State }
	$snapshot = $Shared.Snapshot
	if (-not [object]::ReferenceEquals($State, $snapshot)) {
		$State = $snapshot
		$Block.Data = $State
		$script:UiScreen.Dirty = $true
	}
	return $State
}
