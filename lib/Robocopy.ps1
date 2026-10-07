# copy policy
$script:RobocopyCopyFlags = @(
	'/E',
	'/COPY:DAT',
	'/DCOPY:DAT',
	'/BYTES',
	'/XJ',
	'/R:3',
	'/W:5'
)

$script:RobocopyThreadSlow = 1
$script:RobocopyThreadStandard = 16
$script:RobocopyThreadFast = 64
$script:RobocopyLogRoot = 'C:\Temp\backup_logs'
$script:RobocopySuccessExitCodeMax = 7
$script:RobocopyProgressBarWidth = 40
$script:RobocopyProgressIntervalMs = 100
$script:RobocopyLogReadBufferBytes = 65536
$script:RobocopyLibRoot = $PSScriptRoot

# =============================================================================
#  Helpers
# =============================================================================

function Read-RobocopyThreadCount {
	$slow = $script:RobocopyThreadSlow
	$standard = $script:RobocopyThreadStandard
	$fast = $script:RobocopyThreadFast

	$choice = Read-MenuChoice -Title 'Copy Tool (Robocopy based)' -Options @(
		@{ Key = '1'; Label = "Slow ($slow Thread)"; Description = "$slow copy thread, or $slow file at a time" }
		@{ Key = '2'; Label = "Standard ($standard Threads)"; Description = "$standard copy threads, or up to $standard files at a time" }
		@{ Key = '3'; Label = "Fast ($fast Threads)"; Description = "$fast copy threads, or up to $fast files at a time" }
		@{ Key = '4'; Label = 'Back' }
	)

	switch ($choice) {
		'1' {
			return $script:RobocopyThreadSlow
		}
		'2' {
			return $script:RobocopyThreadStandard
		}
		'3' {
			return $script:RobocopyThreadFast
		}
		'4' {
			Write-UiLine -Text "Back." -Style Secondary
			return $null
		}
	}
}

function New-RobocopyLogPaths {
	param(
		[int]$ThreadCount
	)

	$padded = $ThreadCount.ToString("D2")
	$title = "Robocopy $padded Thread"
	$runId = Get-Date -Format "yyyyMMdd-HHmmss"
	# The log reader must never see an earlier or concurrent run's output.
	$runId += '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
	$logFolder = Join-Path $script:RobocopyLogRoot "robocopy_${padded}_thread"
	$log = Join-Path $logFolder "robocopy-$runId.log"
	$timeLog = Join-Path $logFolder "robocopy-time-$runId.txt"

	New-Item -ItemType Directory -Force -Path $logFolder | Out-Null

	return [pscustomobject]@{
		Title = $title
		Log = $log
		TimeLog = $timeLog
	}
}

function Read-CopyPaths {
	param(
		[string]$Title
	)

	Reset-UiScreen
	Show-PathHelp -Title $Title

	$source = Read-FolderPath -Prompt 'Source' -MustExist -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $Title
	}
	if ($null -eq $source) {
		return $null
	}

	Write-UiLine

	$dest = Read-FolderPath -Prompt 'Destination' -RetryDraw {
		Reset-UiScreen
		Show-PathHelp -Title $Title
		Write-UiLine -Text "Source: $source"
		Write-UiLine
	}
	if ($null -eq $dest) {
		return $null
	}

	return [pscustomobject]@{
		Source = $source
		Dest = $dest
	}
}

function Read-UpdatedFolderPath {
	param(
		[string]$Prompt,
		[string]$Current,
		[switch]$MustExist
	)

	$drawCurrent = {
		Reset-UiScreen
		Write-UiLine
		Write-UiLine -Text "Current $($Prompt.ToLower()): $Current" -Style Secondary
		Write-UiLine -Text "Press ENTER to keep the current path." -Style Secondary
		Write-UiLine
	}

	& $drawCurrent

	$next = Read-FolderPath -Prompt $Prompt -MustExist:$MustExist -AllowEmpty -RetryDraw $drawCurrent
	if ($null -eq $next) {
		return $Current
	}

	return $next
}

function Get-RobocopyEstimate {
	param(
		[string]$Source,
		[string]$Dest
	)

	# Keep the same list-only arguments, but drain output asynchronously so
	# the main thread can redraw during a long estimate or network wait.
	$arguments = @($Source, $Dest, '/L', '/NFL', '/NDL', '/NJH', '/NP') + $script:RobocopyCopyFlags
	$quoted = foreach ($argument in $arguments) { ConvertTo-RobocopyArgument -Value $argument }
	$process = [System.Diagnostics.Process]::new()
	$started = $false
	try {
		$process.StartInfo.FileName = (Get-Command robocopy.exe -CommandType Application -ErrorAction Stop).Source
		$process.StartInfo.Arguments = $quoted -join ' '
		$process.StartInfo.UseShellExecute = $false
		$process.StartInfo.CreateNoWindow = $true
		$process.StartInfo.RedirectStandardOutput = $true
		$process.StartInfo.RedirectStandardError = $true
		$process.StartInfo.StandardOutputEncoding = [Console]::OutputEncoding
		$process.StartInfo.StandardErrorEncoding = [Console]::OutputEncoding
		$started = $process.Start()
		$outputTask = $process.StandardOutput.ReadToEndAsync()
		$errorTask = $process.StandardError.ReadToEndAsync()
		while (-not $process.HasExited) {
			Update-UiScreen
			Start-Sleep -Milliseconds $script:RobocopyProgressIntervalMs
		}
		$dryRun = $outputTask.GetAwaiter().GetResult() -split '\r\n|\r|\n'
		$diagnostics = $errorTask.GetAwaiter().GetResult().Trim()
		if ($diagnostics) { Write-ErrorMessage $diagnostics }
	}
	finally {
		try {
			if ($started -and -not $process.HasExited) {
				try { $process.Kill() }
				catch { if (-not $process.HasExited) { throw } }
				$process.WaitForExit()
			}
		}
		finally { $process.Dispose() }
	}

	$totalBytes = [long]($dryRun -match 'Bytes :' -split '[\t ]+')[3]
	$totalFiles = [long]($dryRun -match 'Files :' -split '[\t ]+')[3]

	return [pscustomobject]@{
		TotalBytes = $totalBytes
		TotalFiles = $totalFiles
		TotalSize = Format-ByteSize $totalBytes
	}
}

function Get-RobocopyPresetLabel {
	param(
		[int]$ThreadCount
	)

	switch ($ThreadCount) {
		$script:RobocopyThreadSlow {
			return "Slow ($ThreadCount Thread)"
		}
		$script:RobocopyThreadStandard {
			return "Standard ($ThreadCount Threads)"
		}
		$script:RobocopyThreadFast {
			return "Fast ($ThreadCount Threads)"
		}
		default {
			return "$ThreadCount Threads"
		}
	}
}

function ConvertTo-RobocopyArgument {
	param(
		[string]$Value
	)

	# ProcessStartInfo.Arguments uses Windows command-line quoting, not shell
	# quoting. Escape quotes and double backslashes before the closing quote.
	$escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
	$escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
	return '"' + $escaped + '"'
}

function New-RobocopyProcess {
	param(
		[string]$Source,
		[string]$Dest,
		[int]$ThreadCount,
		[string]$Log
	)

	$arguments = @($Source, $Dest) + $script:RobocopyCopyFlags + @(
		"/MT:$ThreadCount",
		'/FP',
		"/UNILOG:$Log"
	)
	$quotedArguments = foreach ($argument in $arguments) {
		ConvertTo-RobocopyArgument -Value $argument
	}

	$executable = (Get-Command robocopy.exe -CommandType Application -ErrorAction Stop).Source
	$process = New-Object System.Diagnostics.Process
	$process.StartInfo.FileName = $executable
	$process.StartInfo.Arguments = $quotedArguments -join ' '
	$process.StartInfo.UseShellExecute = $false
	$process.StartInfo.CreateNoWindow = $true
	$process.StartInfo.RedirectStandardOutput = $true
	$process.StartInfo.RedirectStandardError = $true
	return $process
}

function New-RobocopyLogReader {
	param(
		[string]$Log
	)

	return @{
		Path = $Log
		Stream = $null
		Decoder = [System.Text.Encoding]::Unicode.GetDecoder()
		Buffer = New-Object byte[] $script:RobocopyLogReadBufferBytes
		Characters = New-Object char[] ($script:RobocopyLogReadBufferBytes + 2)
		PendingLine = ''
		SeenFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
		CurrentBytes = [long]0
		CurrentFiles = [long]0
		FileName = '(waiting for file activity)'
		ItemBytes = [long]0
		ItemPercent = [double]0
		ProgressChanged = $false
		CopiedBytes = $null
		CopiedFiles = $null
	}
}

function Read-RobocopyLog {
	param(
		[hashtable]$State,
		[switch]$Final
	)

	if ($null -eq $State.Stream) {
		if (-not [System.IO.File]::Exists($State.Path)) {
			return
		}
		$State.Stream = [System.IO.File]::Open(
			$State.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
			[System.IO.FileShare]::ReadWrite
		)
	}

	# Use fixed-size read buffers, but keep consuming chunks without waiting
	# when more data is available. Only screen drawing is rate-limited.
	# On exit, read the summary without replaying any remaining activity.
	$skipFirstLine = $false
	if ($Final -and ($State.Stream.Length - $State.Stream.Position) -gt $State.Buffer.Length) {
		$offset = $State.Stream.Length - $State.Buffer.Length
		$offset -= $offset % 2
		$null = $State.Stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
		$State.Decoder.Reset()
		$State.PendingLine = ''
		$skipFirstLine = $true
	}

	$count = $State.Stream.Read($State.Buffer, 0, $State.Buffer.Length)
	$characterCount = $State.Decoder.GetChars($State.Buffer, 0, $count, $State.Characters, 0, [bool]$Final)
	$text = $State.PendingLine + [string]::new($State.Characters, 0, $characterCount)
	# Percent updates can be separated by carriage returns without newlines.
	$lines = $text -split "`r`n|`r|`n"
	$State.PendingLine = ''
	$lineCount = $lines.Length
	if (-not $Final) {
		# A writer may stop in the middle of a line or a UTF-16 character.
		$State.PendingLine = $lines[$lineCount - 1]
		$lineCount--
	}

	$firstLine = if ($skipFirstLine) { 1 } else { 0 }
	for ($i = $firstLine; $i -lt $lineCount; $i++) {
		$line = $lines[$i].TrimStart([char]0xFEFF).TrimEnd("`r")
		$parsed = Parse-RobocopyProgressLine -Line $line
		if ($parsed.Kind -eq 'File') {
			$State.FileName = $parsed.FileName
			$State.ItemBytes = $parsed.ItemBytes
			$State.ItemPercent = 0
			$State.ProgressChanged = $true
			if ($State.SeenFiles.Add($parsed.FileName)) {
				$State.CurrentBytes += $parsed.ItemBytes
				$State.CurrentFiles++
			}
		}
		elseif ($parsed.Kind -eq 'Percent') {
			# Preserve the original display's most-recent-file association.
			# Robocopy does not identify the file on an /MT percentage row.
			if ($State.CurrentFiles -gt 0) {
				$State.ItemPercent = $parsed.ItemPercent
				$State.ProgressChanged = $true
			}
		}
		elseif ($line -match '^\s*(Files|Bytes)\s*:\s*\d+\s+(\d+)\s+\d+\s+\d+\s+(\d+)\s+\d+\s*$') {
			if ($matches[1] -eq 'Files') {
				$State.CopiedFiles = [long]$matches[2]
			} else {
				$State.CopiedBytes = [long]$matches[2]
			}
		}
	}
}

function Confirm-RobocopyStart {
	param(
		[string]$Source,
		[string]$Dest,
		[int]$ThreadCount
	)

	$choice = Read-MenuChoice -Title 'Confirm Copy' -Details @(
		"  Source:      $Source"
		"  Destination: $Dest"
		"  Preset:      $(Get-RobocopyPresetLabel -ThreadCount $ThreadCount)"
	) -Options @(
		@{ Key = '1'; Label = 'Start copy' }
		@{ Key = '2'; Label = 'Change source' }
		@{ Key = '3'; Label = 'Change destination' }
		@{ Key = '4'; Label = 'Change both paths' }
		@{ Key = '5'; Label = 'Back to main menu' }
	)

	switch ($choice) {
		'1' {
			return 'Start'
		}
		'2' {
			return 'ChangeSource'
		}
		'3' {
			return 'ChangeDest'
		}
		'4' {
			return 'ChangeBoth'
		}
		'5' {
			return 'Back'
		}
	}
}

function Get-RobocopyExitDescription {
	param(
		[int]$ExitCode
	)

	if ($ExitCode -lt 0) {
		return 'The copy process ended with an error before Robocopy reported a result.'
	}

	# Wording matches the README exit-code table for the documented values.
	switch ($ExitCode) {
		0 { return 'No files were copied. No failure. No mismatches. The trees already match.' }
		1 { return 'Files were copied successfully.' }
		2 { return 'Extra files or directories on the destination. No files were copied.' }
		3 { return 'Files were copied. Extra files were present. No failure.' }
		4 { return 'Mismatched files or directories. No files were copied.' }
		5 { return 'Files were copied. Some files were mismatched. No failure.' }
		6 { return 'Extra files and mismatched files. No files were copied. No failure.' }
		7 { return 'Files were copied. Mismatches and extra files were present. No failure.' }
		8 { return 'Some files or directories could not be copied (retry limit exceeded).' }
		9 { return 'Files were copied, but some copy failures occurred.' }
		10 { return 'Extra files present, and some copy failures.' }
		11 { return 'Files were copied, extra files were present, and some copy failures.' }
		12 { return 'Mismatches present, and some copy failures.' }
		13 { return 'Files were copied, mismatches were present, and some copy failures.' }
		14 { return 'Extra files, mismatches, and some copy failures.' }
		15 { return 'Files were copied; extra files, mismatches, and copy failures.' }
		16 { return 'Serious error. Robocopy did not copy any files (usage error or insufficient access).' }
	}

	# Values above 16 are the same flags combined with a serious error.
	$parts = @()
	if ($ExitCode -band 16) {
		$parts += 'Serious error (usage error or insufficient access).'
	}
	if ($ExitCode -band 8) {
		$parts += 'Some files or directories could not be copied (retry limit exceeded).'
	}
	if ($ExitCode -band 1) {
		$parts += 'Files were copied.'
	}
	if ($ExitCode -band 2) {
		$parts += 'Extra files or directories were present on the destination.'
	}
	if ($ExitCode -band 4) {
		$parts += 'Mismatched files or directories were present.'
	}

	$known = 1 -bor 2 -bor 4 -bor 8 -bor 16
	if (($ExitCode -band (-bnot $known)) -ne 0) {
		$parts += 'Unrecognized Robocopy flags were also set.'
	}
	if ($parts.Count -eq 0) {
		return "Unrecognized Robocopy exit code $ExitCode."
	}
	return ($parts -join ' ')
}

function Get-RobocopyConsoleDiagnostics {
	param(
		[AllowEmptyString()]
		[string]$StandardOutput,

		[AllowEmptyString()]
		[string]$StandardError
	)

	# /UNILOG still prints "Log File : ..." on the console. The summary already
	# shows that path, so drop the banner and keep any real error text.
	$chunks = @($StandardOutput, $StandardError) | Where-Object {
		-not [string]::IsNullOrWhiteSpace($_)
	}
	if (-not $chunks) {
		return ''
	}

	$lines = ($chunks -join [Environment]::NewLine) -split '\r\n|\r|\n' | Where-Object {
		$_ -notmatch '^\s*Log File\s*:'
	}
	return (($lines -join [Environment]::NewLine).Trim())
}

function Write-RobocopySummary {
	param(
		[string]$Source,
		[string]$Dest,
		[datetime]$Start,
		[datetime]$End,
		[int]$ExitCode,
		[string]$TimeLog,
		[string]$Log,
		$Estimate
	)

	$duration = $End - $Start
	$succeeded = $ExitCode -ge 0 -and $ExitCode -le $script:RobocopySuccessExitCodeMax
	$status = Get-RobocopyExitDescription -ExitCode $ExitCode
	$statusStyle = if ($succeeded) { 'Success' } else { 'Error' }

	$summary = @"
Source:      $Source
Destination: $Dest
Size:        $($Estimate.TotalSize)
Files:       $($Estimate.TotalFiles)
Start:       $Start
End:         $End
Duration:    $duration
Seconds:     $([math]::Round($duration.TotalSeconds, 2))
Minutes:     $([math]::Round($duration.TotalMinutes, 2))
ExitCode:    $ExitCode
Status:      $status
Log:         ${Log}
"@
	$summary | Tee-Object -FilePath $TimeLog | Out-Null

	$fields = @(
		@{ Label = 'Source:      '; Value = $Source }
		@{ Label = 'Destination: '; Value = $Dest }
		@{ Label = 'Size:        '; Value = $Estimate.TotalSize }
		@{ Label = 'Files:       '; Value = $Estimate.TotalFiles }
		@{ Label = 'Start:       '; Value = $Start }
		@{ Label = 'End:         '; Value = $End }
		@{ Label = 'Duration:    '; Value = $duration }
		@{ Label = 'Seconds:     '; Value = [math]::Round($duration.TotalSeconds, 2) }
		@{ Label = 'Minutes:     '; Value = [math]::Round($duration.TotalMinutes, 2) }
		@{ Label = 'ExitCode:    '; Value = $ExitCode }
		@{ Label = 'Status:      '; Value = $status; Style = $statusStyle }
		@{ Label = 'Log:         '; Value = $Log }
	)

	$rows = foreach ($field in $fields) {
		$value = if ($field.Style) {
			Format-UiText -Text "$($field.Value)" -Style $field.Style
		} else {
			"$($field.Value)"
		}
		"  $($field.Label)$value"
	}

	Show-InfoBox -Title "Copy Summary" -Rows $rows
}

function Get-ClampedPercent {
	param(
		[double]$Current,
		[double]$Total
	)

	if ($Total -le 0) {
		return 100
	}

	return [Math]::Min([Math]::Round(($Current / $Total) * 100, 2), 100)
}

function New-ProgressBar {
	param(
		[double]$Percent,
		[int]$BarWidth
	)

	$fillLen = [int][Math]::Round(($Percent / 100) * $BarWidth)
	if ($fillLen -lt 0) {
		$fillLen = 0
	}
	elseif ($fillLen -gt $BarWidth) {
		$fillLen = $BarWidth
	}

	$emptyLen = $BarWidth - $fillLen

	# Block fill + box horizontal empty, via code points so Windows PowerShell 5.1
	# can parse this file without a UTF-8 BOM.
	$fillChar = [char]0x2588
	$emptyChar = [char]0x2500
	$fillStr = [String]::new($fillChar, $fillLen)
	$emptyStr = [String]::new($emptyChar, $emptyLen)

	if ($fillLen -gt 0) {
		$fillStr = Format-UiText -Text $fillStr -Style Success
	}
	if ($emptyLen -gt 0) {
		$emptyStr = Format-UiText -Text $emptyStr -Style Secondary
	}

	return ' [' + $fillStr + $emptyStr + '] ' + $Percent + '%'
}

function New-ProgressLayout {
	param(
		[int]$WindowWidth = [Console]::WindowWidth
	)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	# ' [' + bar + '] ' + '100.00%'
	$availableWidth = [Math]::Max(1, $layout.InnerWidth - 11)
	$layout | Add-Member -NotePropertyMembers @{
		BarWidth = [Math]::Min($script:RobocopyProgressBarWidth, $availableWidth)
		OverallStr = (Format-UiText -Text " Overall Progress" -Style Progress)
		ItemStr = (Format-UiText -Text " Current File" -Style Progress)
		DataStr = " Data: "
		FilesStr = " Files: "
		PathStr = " Path: "
		SepStr = " / "
	} -PassThru
}

function New-CopyScreenLines {
	param([int]$WindowWidth, [hashtable]$Display)

	$estimate = $Display.Estimate
	$progress = $Display.Progress
	if ($Display.HeaderWidth -ne $WindowWidth -or $Display.HeaderEstimate -ne $estimate) {
		$layout = New-ProgressLayout -WindowWidth $WindowWidth
		$source = Format-UiPath -Path $Display.CopyPaths.Source -Width ($layout.InnerWidth - 15)
		$dest = Format-UiPath -Path $Display.CopyPaths.Dest -Width ($layout.InnerWidth - 15)
		$headers = @('')
		$headers += Format-Box -Layout $layout -Title (Format-UiText -Text '  Copying' -Style Header) -TrailingBlank -Rows @(
			"  Source:      $source"
			"  Destination: $dest"
			"  Preset:      $(Get-RobocopyPresetLabel -ThreadCount $Display.ThreadCount)"
		)
		$totalSize = if ($null -eq $estimate) { '...' } else { $estimate.TotalSize }
		$totalFiles = if ($null -eq $estimate) { '...' } else { $estimate.TotalFiles }
		$headers += Format-Box -Layout $layout -Title (Format-UiText -Text '  Estimating' -Style Progress) -Rows @(
			"  Size:  $totalSize"
			"  Files: $totalFiles"
		)
		if ($null -ne $estimate) { $headers += '' }
		$Display.Layout = $layout
		$Display.HeaderLines = $headers
		$Display.HeaderWidth = $WindowWidth
		$Display.HeaderEstimate = $estimate
	}
	$layout = $Display.Layout
	$lines = @($Display.HeaderLines)
	if ($Display.ShowProgress -and $null -ne $progress) {
		$lines += New-OverallProgressBox -Layout $layout -Estimate $estimate -CurrentBytes $progress.CurrentBytes -CurrentFiles $progress.CurrentFiles
		if (-not $Display.Completed) {
			$lines += New-ItemProgressBox -Layout $layout -FileName $progress.FileName -ItemBytes $progress.ItemBytes -ItemPercent $progress.ItemPercent
		}
	}
	return $lines
}

function Write-CopyProgress {
	param(
		[hashtable]$Display,
		$CopyPaths,
		[int]$ThreadCount,
		$Estimate,
		$Progress,
		[switch]$Force,
		[switch]$Completed
	)

	if (-not $Display.Registered) {
		Reset-UiScreen
		Add-UiBlock @{ Kind = 'Custom'; Builder = ${function:New-CopyScreenLines}; Data = $Display }
		$Display.Registered = $true
	}
	$Display.CopyPaths = $CopyPaths
	$Display.ThreadCount = $ThreadCount
	$Display.Estimate = $Estimate
	$Display.Progress = $Progress
	$Display.Completed = [bool]$Completed
	if ($null -ne $Progress -and $Progress.ProgressChanged) {
		$Display.ShowProgress = $true
		$script:UiScreen.Dirty = $true
	}
	Update-UiScreen -Force:($Force -or $Completed)
	if ($null -ne $Progress -and -not $script:UiScreen.Dirty) { $Progress.ProgressChanged = $false }
}

function Parse-RobocopyProgressLine {
	param(
		[string]$Line
	)

	# File rows: "New File|Newer|Older|Changed" + byte size + path
	#   e.g. "	    New File  		   12345	C:\folder\file.txt"
	if ($Line -match "^\s*(New File|Newer|Older|Changed)\s+(\d+)\s+(.+)$") {
		return [pscustomobject]@{
			Kind = 'File'
			ItemBytes = [long]$matches[2]
			FileName = $matches[3]
		}
	}

	# Robocopy versions emit either integer or decimal percentage rows.
	if ($Line -match '^\s*(\d{1,3}(?:\.\d+)?)%\s*$') {
		$percent = [double]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture)
		return [pscustomobject]@{
			Kind = 'Percent'
			ItemPercent = [Math]::Min($percent, 100)
		}
	}

	return [pscustomobject]@{
		Kind = 'Other'
	}
}

function New-OverallProgressBox {
	param(
		$Layout,
		$Estimate,
		[long]$CurrentBytes,
		[long]$CurrentFiles
	)

	$dataPercent = Get-ClampedPercent -Current $CurrentBytes -Total $Estimate.TotalBytes
	$filesPercent = Get-ClampedPercent -Current $CurrentFiles -Total $Estimate.TotalFiles

	$overallData = $Layout.DataStr + (Format-ByteSize $CurrentBytes) + $Layout.SepStr + $Estimate.TotalSize
	$dataProgressBar = New-ProgressBar -Percent $dataPercent -BarWidth $Layout.BarWidth

	$overallFiles = $Layout.FilesStr + $CurrentFiles + $Layout.SepStr + $Estimate.TotalFiles
	$filesProgressBar = New-ProgressBar -Percent $filesPercent -BarWidth $Layout.BarWidth

	return Format-Box -Layout $Layout -Title $Layout.OverallStr -TrailingBlank -Rows @(
		''
		$overallData
		$dataProgressBar
		''
		$overallFiles
		$filesProgressBar
		''
	)
}

function New-ItemProgressBox {
	param(
		$Layout,
		[string]$FileName,
		[long]$ItemBytes,
		[double]$ItemPercent
	)

	$availableSpace = $Layout.InnerWidth - (Get-VisibleTextLength $Layout.PathStr) - 1
	$FileName = Format-UiPath -Path $FileName -Width $availableSpace

	$itemPath = $Layout.PathStr + $FileName
	$currentItemBytes = ($ItemPercent / 100) * $ItemBytes
	$itemData = $Layout.DataStr + (Format-ByteSize $currentItemBytes) + $Layout.SepStr + (Format-ByteSize $ItemBytes)
	$itemProgressBar = New-ProgressBar -Percent $ItemPercent -BarWidth $Layout.BarWidth

	return Format-Box -Layout $Layout -Title $Layout.ItemStr -Rows @(
		''
		$itemPath
		''
		$itemData
		$itemProgressBar
		''
	)
}

function New-RobocopyCompletedResult {
	param(
		$CopyPaths,
		$LogPaths
	)

	return [pscustomobject]@{
		Status = 'Completed'
		Source = $CopyPaths.Source
		Dest = $CopyPaths.Dest
		LogFolder = [System.IO.Path]::GetDirectoryName($LogPaths.Log)
	}
}

# =============================================================================
#  Orchestrator
# =============================================================================

function Invoke-RobocopyTool {
	$threadCount = Read-RobocopyThreadCount
	if ($null -eq $threadCount) {
		return
	}

	$logPaths = New-RobocopyLogPaths -ThreadCount $threadCount

	$copyPaths = Read-CopyPaths -Title $logPaths.Title
	if ($null -eq $copyPaths) {
		return
	}

	$readyToCopy = $false
	while (-not $readyToCopy) {
		$action = Confirm-RobocopyStart `
			-Source $copyPaths.Source `
			-Dest $copyPaths.Dest `
			-ThreadCount $threadCount

		switch ($action) {
			'Start' {
				$readyToCopy = $true
			}
			'ChangeSource' {
				$copyPaths.Source = Read-UpdatedFolderPath `
					-Prompt 'Source' `
					-Current $copyPaths.Source `
					-MustExist
			}
			'ChangeDest' {
				$copyPaths.Dest = Read-UpdatedFolderPath `
					-Prompt 'Destination' `
					-Current $copyPaths.Dest
			}
			'ChangeBoth' {
				$updated = Read-CopyPaths -Title $logPaths.Title
				if ($null -ne $updated) {
					$copyPaths = $updated
				}
			}
			'Back' {
				return
			}
		}
	}

	$display = @{
		Registered = $false
		HeaderWidth = -1
		HeaderEstimate = $null
		Layout = $null
		HeaderLines = @()
		ShowProgress = $false
	}
	Write-CopyProgress -Display $display -CopyPaths $copyPaths -ThreadCount $threadCount -Force

	try {
		$estimate = Get-RobocopyEstimate -Source $copyPaths.Source -Dest $copyPaths.Dest
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		Write-ErrorMessage "Estimation failed: $($_.Exception.Message)"
		return New-RobocopyCompletedResult -CopyPaths $copyPaths -LogPaths $logPaths
	}

	Write-CopyProgress -Display $display -CopyPaths $copyPaths -ThreadCount $threadCount -Estimate $estimate -Force

	$state = New-RobocopyLogReader -Log $logPaths.Log
	$process = $null
	$started = $false
	$progressClock = [System.Diagnostics.Stopwatch]::StartNew()
	$lastProgressTick = -$script:RobocopyProgressIntervalMs

	try {
		Set-UiCursorVisible -Visible $false
		$process = New-RobocopyProcess `
			-Source $copyPaths.Source `
			-Dest $copyPaths.Dest `
			-ThreadCount $threadCount `
			-Log $logPaths.Log

		# Do not pipe Robocopy into PowerShell. Its log is the progress source;
		# slow screen updates cannot fill an output pipe and stall the copy.
		$started = $process.Start()
		$start = $process.StartTime
		# Drain console output asynchronously, including log-open errors.
		# There is no /TEE, so file activity goes only to the Unicode log.
		$outputTask = $process.StandardOutput.ReadToEndAsync()
		$errorTask = $process.StandardError.ReadToEndAsync()

		while ($true) {
			$exited = $process.HasExited
			Read-RobocopyLog -State $state -Final:$exited
			if ($exited) {
				$exitCode = $process.ExitCode
				$end = $process.ExitTime
				break
			}

			# Like Folder Size, update counters for every item but build and draw
			# the progress boxes only when the refresh interval has elapsed.
			$now = $progressClock.ElapsedMilliseconds
			if (($now - $lastProgressTick) -ge $script:RobocopyProgressIntervalMs) {
				$lastProgressTick = $now
				# Check dimensions even while Robocopy has no new log activity.
				Write-CopyProgress `
					-Display $display `
					-CopyPaths $copyPaths `
					-ThreadCount $threadCount `
					-Estimate $estimate `
					-Progress $state
			}

			# Never sleep with unread log data. Pause only after catching up,
			# so the read-buffer size does not cap progress processing speed.
			if ($null -eq $state.Stream -or $state.Stream.Position -ge $state.Stream.Length) {
				Start-Sleep -Milliseconds $script:RobocopyProgressIntervalMs
			}
		}

		# Finish asynchronous reads before disposing their process streams.
		$diagnostics = Get-RobocopyConsoleDiagnostics `
			-StandardOutput $outputTask.GetAwaiter().GetResult() `
			-StandardError $errorTask.GetAwaiter().GetResult()

		if ($null -ne $state.CopiedBytes -and $null -ne $state.CopiedFiles) {
			$state.CurrentBytes = $state.CopiedBytes
			$state.CurrentFiles = $state.CopiedFiles
		}
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		Write-UiLine
		Write-ErrorMessage "Copy interrupted: $($_.Exception.Message)"
		Write-UiLine -Text "Log: $($logPaths.Log)" -Style Secondary
		return New-RobocopyCompletedResult -CopyPaths $copyPaths -LogPaths $logPaths
	}
	finally {
		try {
			# Ctrl+C or a monitoring error must not leave a hidden copy running.
			if ($started -and -not $process.HasExited) {
				try {
					$process.Kill()
				}
				catch {
					# The process may exit between HasExited and Kill.
					if (-not $process.HasExited) {
						throw
					}
				}
				$process.WaitForExit()
			}
		}
		finally {
			if ($null -ne $state.Stream) {
				$state.Stream.Dispose()
			}
			if ($null -ne $process) {
				$process.Dispose()
			}
			Set-UiCursorVisible -Visible $true
		}
	}

	Write-CopyProgress `
		-Display $display `
		-CopyPaths $copyPaths `
		-ThreadCount $threadCount `
		-Estimate $estimate `
		-Progress $state `
		-Completed

	if ($exitCode -lt 0 -or $exitCode -gt $script:RobocopySuccessExitCodeMax) {
		if (-not [string]::IsNullOrWhiteSpace($diagnostics)) {
			Write-ErrorMessage $diagnostics
		}
	}

	Write-RobocopySummary `
		-Source $copyPaths.Source `
		-Dest $copyPaths.Dest `
		-Start $start `
		-End $end `
		-ExitCode $exitCode `
		-TimeLog $logPaths.TimeLog `
		-Log $logPaths.Log `
		-Estimate $estimate

	return New-RobocopyCompletedResult -CopyPaths $copyPaths -LogPaths $logPaths
}

function Read-AfterCopyChoice {
	param(
		[string]$Source,
		[string]$Dest,
		[string]$LogFolder
	)

	. (Join-Path $script:RobocopyLibRoot 'FolderSize.ps1')

	while ($true) {
		Add-UiBlock @{ Kind = 'Custom'; Static = $true; Builder = ${function:New-UiFinishedLines}; Data = $null }
		$choice = Read-MenuChoice -Title 'Next' -NoClear -TitleStyle Header -Options @(
			@{ Key = '1'; Label = 'Back to main menu' }
			@{ Key = '2'; Label = 'Exit' }
			@{ Key = '3'; Label = 'Compare source and backup' }
		)

		if ($choice -eq '2') {
			Write-UiLine -Text "Exiting."
			exit 0
		}
		if ($choice -eq '3') {
			Invoke-FolderSizeComparison -Source $Source -Dest $Dest -LogFolder $LogFolder
			continue
		}
		return
	}
}
