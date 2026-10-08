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
		[switch]$CollectFiles
	)

	Initialize-FolderSizeNative
	$shared = [hashtable]::Synchronized(@{ Snapshot = (New-FolderSizeSnapshot -CurrentPath $Path); Result = $null })
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

			function Get-WorkerRelativePath {
				param([string]$FullName)
				return Get-FolderSizeRelativePath -RootDisplay $script:WorkerRootDisplay -FullName $FullName
			}

			function Add-WorkerUnreadable {
				param([string]$FullName, $ErrorRecord, [string]$Message)
				if ($null -ne $ErrorRecord) { $Message = Get-FolderSizeErrorMessage $ErrorRecord }
				[void]$script:Unreadable.Add(@{ RelativePath = (Get-WorkerRelativePath $FullName); Error = $Message })
			}

			function Test-WorkerSkippedReparse {
				param([string]$FullName)
				$kind = [FolderSizeNative]::SkippedReparseKind([FolderSizeNative]::ReparseTag($FullName))
				if ($null -eq $kind) { return $false }
				[void]$script:Reparse.Add(@{ RelativePath = (Get-WorkerRelativePath $FullName); Kind = $kind })
				return $true
			}

			function Measure-WorkerFile {
				param($Entry, [string]$FullName, [bool]$IsReparse)
				try {
					if ($IsReparse -and (Test-WorkerSkippedReparse $FullName)) { return }
					$stored = [uint64]([FolderSizeNative]::StoredSize($FullName))
					$logical = [uint64]$Entry.Length
					$relative = Get-WorkerRelativePath $FullName
					$script:ScanFiles = [long]$script:ScanFiles + 1
					$script:ScanLogical = [uint64]$script:ScanLogical + $logical
					$script:ScanStored = [uint64]$script:ScanStored + $stored
					Add-FolderSizeMetric -Stats $script:Stats -Differences $script:Differences -RelativeFile $relative -Logical $logical -Stored $stored
					if ($null -ne $script:FilesByPath) { $script:FilesByPath[$relative] = $logical }
				}
				catch {
					Add-WorkerUnreadable -FullName $FullName -ErrorRecord $_
				}
			}

			function Add-WorkerDirectory {
				param([string]$FullName, [bool]$IsReparse, $Pending)
				try {
					if ($IsReparse -and (Test-WorkerSkippedReparse $FullName)) { return }
				}
				catch {
					Add-WorkerUnreadable -FullName $FullName -ErrorRecord $_
					return
				}
				$script:ScanFolders = [long]$script:ScanFolders + 1
				if ($null -ne $script:Directories) { $script:Directories[(Get-WorkerRelativePath $FullName)] = $true }
				$Pending.Push($FullName)
			}

			$script:ScanFiles = [long]0
			$script:ScanFolders = [long]0
			$script:ScanLogical = [uint64]0
			$script:ScanStored = [uint64]0
			$script:ScanCurrentPath = $ScanPath
			$script:Stats = New-FolderSizeKeyTable
			$script:Differences = New-Object System.Collections.Generic.List[object]
			$script:Reparse = New-Object System.Collections.Generic.List[object]
			$script:Unreadable = New-Object System.Collections.Generic.List[object]
			$script:FilesByPath = $null
			$script:Directories = $null
			if ($CollectFiles) {
				$script:FilesByPath = New-FolderSizeKeyTable
				$script:Directories = New-FolderSizeKeyTable
			}
			$script:WorkerRootDisplay = (Get-FolderSizeComparablePath $ScanPath).TrimEnd('\')
			$script:ScanShared = $Shared
			$script:ScanInterval = $Interval
			$script:ScanClock = [System.Diagnostics.Stopwatch]::StartNew()

			$walk = $false
			try {
				# DirectoryInfo rejects the \\?\ prefix on .NET Framework. Get-Item accepts it.
				$rootItem = Get-Item -LiteralPath $ScanPath -Force -ErrorAction Stop
				if (-not $rootItem.PSIsContainer) {
					Add-WorkerUnreadable -FullName $ScanPath -Message 'The path is not a folder.'
				}
				elseif (([int]$rootItem.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -eq 0) {
					$walk = $true
				}
				elseif (-not (Test-WorkerSkippedReparse $ScanPath)) {
					$walk = $true
				}
			}
			catch {
				Add-WorkerUnreadable -FullName $ScanPath -ErrorRecord $_
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
						$entries = Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop
					}
					catch {
						Add-WorkerUnreadable -FullName $dir -ErrorRecord $_
						continue
					}
					foreach ($entry in $entries) {
						$fullName = ConvertTo-FolderSizeLongPath $entry.FullName
						$script:ScanCurrentPath = $fullName
						Update-WorkerClock
						try {
							$isReparse = (([int]$entry.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
						}
						catch {
							Add-WorkerUnreadable -FullName $fullName -ErrorRecord $_
							continue
						}
						if ($entry.PSIsContainer) {
							Add-WorkerDirectory -FullName $fullName -IsReparse $isReparse -Pending $pending
						}
						else {
							Measure-WorkerFile -Entry $entry -FullName $fullName -IsReparse $isReparse
						}
					}
				}
			}

			Publish-WorkerSnapshot
			$script:ScanShared.Result = @{
				Logical = $script:ScanLogical
				Stored = $script:ScanStored
				Files = $script:ScanFiles
				Folders = $script:ScanFolders
				Reparse = $script:Reparse.ToArray()
				Unreadable = $script:Unreadable.ToArray()
				DirectoryStats = $script:Stats
				Differences = $script:Differences.ToArray()
				FilesByPath = $script:FilesByPath
				Directories = $script:Directories
			}
		}).AddArgument($Path).AddArgument($shared).AddArgument($script:FolderSizeProgressIntervalMs).AddArgument([bool]$CollectFiles).AddArgument($modelSource)
		return @{ Worker = $worker; Pending = $worker.BeginInvoke(); Shared = $shared }
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

function Stop-FolderSizeScans {
	param([System.Collections.IDictionary]$Scans)

	foreach ($scan in @($Scans.Values)) {
		try { Stop-FolderSizeScan $scan }
		catch [System.Management.Automation.PipelineStoppedException] { throw }
		catch { }
	}
}

function Wait-FolderSizeScans {
	param(
		[System.Collections.IDictionary]$Scans,
		[hashtable]$Progress
	)

	while ($true) {
		$running = $false
		foreach ($key in @($Scans.Keys)) {
			$scan = $Scans[$key]
			if (-not $scan.Pending.IsCompleted) { $running = $true }
			$snapshot = $scan.Shared.Snapshot
			if (-not [object]::ReferenceEquals($Progress[$key], $snapshot)) {
				$Progress[$key] = $snapshot
				$script:UiScreen.Dirty = $true
			}
		}
		if (-not $running) { return }
		# Check for resizing even if a directory or network read is waiting.
		Update-UiScreen
		Start-Sleep -Milliseconds $script:FolderSizeProgressIntervalMs
	}
}

function Complete-FolderSizeScans {
	param([System.Collections.IDictionary]$Scans)

	$failure = $null
	$results = @{}
	foreach ($key in @($Scans.Keys)) {
		$scan = $Scans[$key]
		try { [void]$scan.Worker.EndInvoke($scan.Pending) }
		catch [System.Management.Automation.PipelineStoppedException] { throw }
		catch { if ($null -eq $failure) { $failure = $_ } }
		$results[$key] = $scan.Shared.Result
	}
	if ($null -ne $failure) { throw $failure }
	foreach ($key in @($results.Keys)) {
		if ($null -eq $results[$key]) { throw 'A folder scan finished without a result.' }
	}
	return $results
}
