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
	$modelSource = [System.IO.File]::ReadAllText((Join-Path $script:FolderSizeLibRoot 'FolderSizeModel.ps1'))
	$worker = [PowerShell]::Create()
	try {
		# A new runspace cannot call the functions in this file. It loads the
		# model helpers from their source text, and nothing in it writes to the
		# console.
		[void]$worker.AddScript({
			param($ScanPath, $Shared, $Interval, $CollectFiles, $ModelSource)

			. ([scriptblock]::Create($ModelSource))

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

			function Measure-WorkerFile {
				param($Entry, [string]$FullName, [bool]$IsReparse)
				try {
					$native = ConvertTo-FolderSizeLongPath $FullName
					# Directory junctions are skipped before this runs. A file
					# reparse point is skipped only when it is a symlink, so a
					# cloud placeholder is still measured.
					if ($IsReparse -and [FolderSizeNative]::IsSymlinkOrJunction($native)) {
						[void]$script:ReparsePaths.Add((Get-FolderSizeRelativePath -RootDisplay $script:WorkerRootDisplay -FullName $FullName))
						return
					}
					$stored = [uint64]([FolderSizeNative]::StoredSize($native))
					$logical = [uint64]$Entry.Length
					$relative = Get-FolderSizeRelativePath -RootDisplay $script:WorkerRootDisplay -FullName $FullName
					$script:ScanFiles = [long]$script:ScanFiles + 1
					$script:ScanLogical = [uint64]$script:ScanLogical + $logical
					$script:ScanStored = [uint64]$script:ScanStored + $stored
					Add-FolderSizeMetric -Stats $script:Stats -Differences $script:Differences -RelativeFile $relative -Logical $logical -Stored $stored
					if ($null -ne $script:FilesByPath) {
						$script:FilesByPath[$relative] = @{ Logical = $logical; Stored = $stored }
					}
				}
				catch {
					[void]$script:UnreadablePaths.Add((Get-FolderSizeRelativePath -RootDisplay $script:WorkerRootDisplay -FullName $FullName))
				}
			}

			$script:ScanFiles = [long]0
			$script:ScanFolders = [long]0
			$script:ScanLogical = [uint64]0
			$script:ScanStored = [uint64]0
			$script:ScanCurrentPath = $ScanPath
			$script:Stats = New-FolderSizeKeyTable
			$script:Differences = New-Object System.Collections.Generic.List[object]
			$script:ReparsePaths = New-Object System.Collections.Generic.List[string]
			$script:UnreadablePaths = New-Object System.Collections.Generic.List[string]
			$script:FilesByPath = $null
			if ($CollectFiles) { $script:FilesByPath = New-FolderSizeKeyTable }
			$script:WorkerRootDisplay = (Get-FolderSizeComparablePath $ScanPath).TrimEnd('\')
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
							$fullName = ConvertTo-FolderSizeLongPath $entry.FullName
							$script:ScanCurrentPath = $fullName
							$isReparse = $false
							try {
								$isReparse = (([int]$entry.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
							}
							catch {
								[void]$script:UnreadablePaths.Add((Get-FolderSizeRelativePath -RootDisplay $script:WorkerRootDisplay -FullName $fullName))
								Update-WorkerClock
								continue
							}
							if ($entry.PSIsContainer) {
								if ($isReparse) {
									[void]$script:ReparsePaths.Add((Get-FolderSizeRelativePath -RootDisplay $script:WorkerRootDisplay -FullName $fullName))
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
						[void]$script:UnreadablePaths.Add((Get-FolderSizeRelativePath -RootDisplay $script:WorkerRootDisplay -FullName $dir))
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
		}).AddArgument($Path).AddArgument($Shared).AddArgument($script:FolderSizeProgressIntervalMs).AddArgument([bool]$CollectFiles).AddArgument($modelSource)
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
