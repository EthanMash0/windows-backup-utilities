function Enable-VirtualTerminal {
	try {
		if (-not ([System.Management.Automation.PSTypeName]'Win32.VtConsole').Type) {
			$signature = @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
			Add-Type -MemberDefinition $signature -Name VtConsole -Namespace Win32 -ErrorAction Stop
		}

		$handle = [Win32.VtConsole]::GetStdHandle(-11)
		if ($handle -eq [IntPtr]::Zero -or $handle.ToInt64() -eq -1) {
			return $false
		}

		[uint32]$mode = 0
		if (-not [Win32.VtConsole]::GetConsoleMode($handle, [ref]$mode)) {
			return $false
		}

		$enableVt = [uint32]4
		if (($mode -band $enableVt) -ne $enableVt) {
			if (-not [Win32.VtConsole]::SetConsoleMode($handle, ($mode -bor $enableVt))) {
				return $false
			}
		}

		return $true
	}
	catch {
		return $false
	}
}

function Initialize-Ui {
	if ($global:UiState -and $global:UiState.Initialized -and $global:UiState.ContainsKey('InteractiveConsole')) {
		return
	}

	$interactiveConsole = $false
	try {
		$interactiveConsole = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and [Console]::WindowWidth -gt 0
		if ($interactiveConsole) { $null = [Console]::KeyAvailable }
	} catch { $interactiveConsole = $false }
	$global:UiState = @{
		Initialized = $true
		InteractiveConsole = $interactiveConsole
		UseVt = Enable-VirtualTerminal
		Esc = [char]27
		Theme = @{
			Header = @(255, 163, 227)
			Secondary = @(154, 154, 154)
			Success = @(110, 170, 88)
			Error = @(255, 107, 107)
			Progress = @(236, 212, 118)
			Prompt = @(126, 182, 255)
			Accent = @(232, 148, 80)
		}
		Fallback = @{
			Header = 'Magenta'
			Secondary = 'DarkGray'
			Success = 'Green'
			Error = 'Red'
			Progress = 'Yellow'
			Prompt = $null
			Accent = 'DarkYellow'
		}
	}
}

function Format-UiText {
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyString()]
		[string]$Text,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Header', 'Secondary', 'Success', 'Error', 'Progress', 'Prompt', 'Accent')]
		[string]$Style
	)

	Initialize-Ui

	if (-not $global:UiState.UseVt) {
		return $Text
	}

	$rgb = $global:UiState.Theme[$Style]
	$esc = $global:UiState.Esc
	# Keep black behind the text. SGR 0 resets to the console default, which
	# is dark blue in powershell.exe — not the Black we set on RawUI.
	return "$esc[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m$esc[48;2;0;0;0m$Text$esc[38;2;255;255;255m$esc[48;2;0;0;0m"
}

function Format-UiSurface {
	param(
		[AllowEmptyString()]
		[string]$Text
	)

	Initialize-Ui

	if (-not $global:UiState.UseVt -or [string]::IsNullOrEmpty($Text)) {
		return $Text
	}

	$esc = $global:UiState.Esc
	return "$esc[38;2;255;255;255m$esc[48;2;0;0;0m$Text$esc[38;2;255;255;255m$esc[48;2;0;0;0m"
}

function Write-UiSurface {
	param(
		[AllowEmptyString()]
		[string]$Text,

		[switch]$NoNewline
	)

	$line = Format-UiSurface $Text
	if ($NoNewline) {
		Write-Host $line -NoNewline
	} else {
		Write-Host $line
	}
}

function Get-VisibleTextLength {
	param(
		[AllowEmptyString()]
		[string]$Text
	)

	if ([string]::IsNullOrEmpty($Text)) {
		return 0
	}

	# Measure console cells rather than UTF-16 characters (e.g. wide filenames).
	$plain = [regex]::Replace($Text, '\x1b\[[0-9;]*m', '')
	if ($plain -match '^[\x20-\x7e]*$') { return $plain.Length }
	try {
		return $Host.UI.RawUI.LengthInBufferCells($plain)
	}
	catch {
		# Some non-console hosts do not implement cell measurement. Reserve
		# extra space for non-ASCII text rather than assuming it is all narrow.
		return $plain.Length + [regex]::Matches($plain, '[^\x00-\x7f]').Count
	}
}

function ConvertTo-UiDisplayText {
	param(
		[AllowEmptyString()]
		[string]$Text,
		[switch]$AllowStyle
	)

	# Normalize only the displayed copy. Tabs and other controls must not move
	# the cursor; retain our own SGR colors when fitting an already styled row.
	$parts = if ($AllowStyle) { [regex]::Split($Text, '(\x1b\[[0-9;]*m)') } else { @($Text) }
	$result = foreach ($part in $parts) {
		if ($AllowStyle -and $part -match '^\x1b\[[0-9;]*m$') {
			$part
		} else {
			[regex]::Replace($part, '[\x00-\x1f\x7f-\x9f]', ' ')
		}
	}
	return $result -join ''
}

function Format-UiFittedText {
	param(
		[AllowEmptyString()]
		[string]$Text,
		[int]$Width
	)

	if ($Width -le 0) { return '' }
	$Text = ConvertTo-UiDisplayText -Text $Text -AllowStyle
	if ((Get-VisibleTextLength $Text) -le $Width) { return $Text }

	$result = [System.Text.StringBuilder]::new()
	$remaining = $Width
	foreach ($part in [regex]::Split($Text, '(\x1b\[[0-9;]*m)')) {
		if ($part -match '^\x1b\[[0-9;]*m$') {
			[void]$result.Append($part)
			continue
		}

		# Do not split surrogate pairs or combining character sequences.
		$elements = [Globalization.StringInfo]::GetTextElementEnumerator($part)
		while ($elements.MoveNext()) {
			$element = $elements.GetTextElement()
			$cells = Get-VisibleTextLength $element
			if ($cells -gt $remaining) {
				return Format-UiSurface -Text $result.ToString()
			}
			[void]$result.Append($element)
			$remaining -= $cells
		}
	}
	return Format-UiSurface -Text $result.ToString()
}

function Format-UiPath {
	param(
		[AllowEmptyString()]
		[string]$Path,
		[int]$Width
	)

	if ($Width -le 0) { return '' }
	$display = ConvertTo-UiDisplayText -Text $Path
	if ((Get-VisibleTextLength $display) -le $Width) { return $display }

	$ellipsis = '.' * [Math]::Min(3, $Width)
	$remaining = $Width - $ellipsis.Length
	$offsets = [Globalization.StringInfo]::ParseCombiningCharacters($display)
	$start = $display.Length
	for ($i = $offsets.Length - 1; $i -ge 0; $i--) {
		$element = $display.Substring($offsets[$i], $start - $offsets[$i])
		$cells = Get-VisibleTextLength $element
		if ($cells -gt $remaining) { break }
		$start = $offsets[$i]
		$remaining -= $cells
	}
	return $ellipsis + $display.Substring($start)
}

function Get-UiConsoleSize {
	$width = [Console]::WindowWidth
	$height = [Console]::WindowHeight
	$bufferWidth = [Console]::BufferWidth
	$bufferHeight = [Console]::BufferHeight
	return [pscustomobject]@{
		Width = [Math]::Min($width, $bufferWidth)
		BufferHeight = $bufferHeight
		Key = "$width/$height/$bufferWidth/$bufferHeight"
	}
}

function Reset-UiScreen {
	$script:UiScreen = @{
		Blocks = [System.Collections.Generic.List[object]]::new()
		Frame = @{ SizeKey = ''; Lines = @(); NeedsRedraw = $true }
		Dirty = $true
		Input = $null
		PrintedBlocks = 0
	}
}

function Set-UiCursorVisible {
	param([bool]$Visible)

	try {
		if ($global:UiState.InteractiveConsole) { [Console]::CursorVisible = $Visible }
	} catch {
		# Cursor visibility is cosmetic and must not interrupt an operation.
	}
}

function Add-UiBlock {
	param($Block)

	if ($null -eq $script:UiScreen) { Reset-UiScreen }
	$script:UiScreen.Blocks.Add($Block)
	$script:UiScreen.Dirty = $true
}

function Write-UiLine {
	param(
		[AllowEmptyString()]
		[string]$Text = '',
		[string]$Style
	)

	if ($Style) { $Text = Format-UiText -Text $Text -Style $Style }
	Add-UiBlock @{ Kind = 'Text'; Text = $Text }
	Update-UiScreen
}

function Format-UiWrappedText {
	param([string]$Text, [int]$Width)

	if ($Width -le 0) { return '' }
	# Keep complete messages/confirmation paths. Progress paths use suffix
	# fitting instead. Retain the original text in screen state for resizing.
	foreach ($paragraph in [regex]::Split($Text, '\r\n|\r|\n')) {
		$plain = ConvertTo-UiDisplayText -Text $paragraph -AllowStyle
		if ((Get-VisibleTextLength $plain) -le $Width) {
			Format-UiSurface -Text $plain
			continue
		}
		$line = [System.Text.StringBuilder]::new()
		$cells = 0
		$style = ''
		foreach ($part in [regex]::Split($plain, '(\x1b\[[0-9;]*m)')) {
			if ($part -match '^\x1b\[[0-9;]*m$') {
				$style += $part
				[void]$line.Append($part)
				continue
			}
			$elements = [Globalization.StringInfo]::GetTextElementEnumerator($part)
			while ($elements.MoveNext()) {
				$element = $elements.GetTextElement()
				$length = Get-VisibleTextLength $element
				if ($length -gt $Width) { $element = '?'; $length = 1 }
				if ($cells + $length -gt $Width) {
					Format-UiSurface -Text $line.ToString()
					[void]$line.Clear()
					[void]$line.Append($style)
					$cells = 0
				}
				[void]$line.Append($element)
				$cells += $length
			}
		}
		Format-UiSurface -Text $line.ToString()
	}
}

function Update-UiScreen {
	param([switch]$Force)

	if ($null -eq $script:UiScreen) { return }
	try {
		$screen = $script:UiScreen
		$plainOutput = -not $global:UiState.InteractiveConsole
		$size = if ($plainOutput) { @{ Width = 80; Key = 'plain' } } else { Get-UiConsoleSize }
		if (-not ($Force -or $screen.Dirty -or $screen.Frame.NeedsRedraw -or $screen.Frame.SizeKey -ne $size.Key)) { return }
		$layout = New-BoxLayout -WindowWidth $size.Width
		$lines = @()
		$firstBlock = if ($plainOutput) { $screen.PrintedBlocks } else { 0 }
		for ($index = $firstBlock; $index -lt $screen.Blocks.Count; $index++) {
			$block = $screen.Blocks[$index]
			$cacheable = $block.Kind -ne 'Custom' -or $block.Static
			if (-not $cacheable -or $block.CachedWidth -ne $size.Width) {
				$block.CachedLines = @(switch ($block.Kind) {
					'Text' { Format-UiWrappedText -Text $block.Text -Width $layout.ConsoleWidth }
					'Box' { Format-Box -Layout $layout -Title $block.Title -Rows $block.Rows -WrapRows -TrailingBlank:$block.TrailingBlank }
					'Custom' { & $block.Builder $size.Width $block.Data }
				})
				$block.CachedWidth = $size.Width
			}
			$lines += $block.CachedLines
		}
		if ($plainOutput) {
			# Unsupported/redirected hosts get ordinary sequential output. Do
			# not repeatedly print progress frames or old prompts in this mode.
			foreach ($line in $lines) { Write-UiSurface -Text $line }
			$screen.PrintedBlocks = $screen.Blocks.Count
			$screen.Dirty = $false
			$screen.Frame.NeedsRedraw = $false
			$screen.Frame.SizeKey = $size.Key
			return
		}
		$inputColumn = 0
		if ($null -ne $screen.Input) {
			$inputLine = New-UiInputLine -InputState $screen.Input -Width $layout.ConsoleWidth
			$lines += $inputLine.Text
			$inputColumn = $inputLine.Column
		}
		Write-UiFrame -State $screen.Frame -Size $size -Lines $lines
		if ($null -ne $screen.Input) {
			$row = [Math]::Max(0, [Math]::Min($lines.Count, $size.BufferHeight - 1) - 1)
			[Console]::SetCursorPosition($inputColumn, $row)
		}
		$screen.Dirty = $false
	}
	catch [System.Management.Automation.PipelineStoppedException] { throw }
	catch {
		# A resize can race any console operation. The next UI tick retries;
		# rendering never reruns a command, validation, or summary-file write.
		$script:UiScreen.Frame.NeedsRedraw = $true
	}
}

function Write-UiFrame {
	param(
		[hashtable]$State,
		$Size,
		[string[]]$Lines
	)

	# A complete frame owns this tool's screen. Reflow can move old content
	# outside its former rectangle, so clear it once when dimensions change.
	if ($State.NeedsRedraw -or $State.SizeKey -ne $Size.Key) {
		Clear-Host
		$State.Lines = @()
	}

	$width = [Math]::Max(0, $Size.Width - 1)
	$capacity = [Math]::Max(0, $Size.BufferHeight - 1)
	# Normally the whole frame fits in scrollback. If even the buffer is too
	# short, retain the most recent progress rows until the window is restored.
	$first = [Math]::Max(0, $Lines.Count - $capacity)
	$visible = @($Lines | Select-Object -Skip $first)
	$count = [Math]::Min($capacity, [Math]::Max($visible.Count, $State.Lines.Count))
	for ($i = 0; $i -lt $count; $i++) {
		$line = if ($i -lt $visible.Count) { $visible[$i] } else { '' }
		if ($i -lt $State.Lines.Count -and $i -lt $visible.Count -and $line -ceq $State.Lines[$i]) {
			continue
		}
		if ((Get-UiConsoleSize).Key -ne $Size.Key) {
			throw [InvalidOperationException]::new('Console resized during redraw.')
		}
		$fitted = Format-UiFittedText -Text $line -Width $width
		$padding = [Math]::Max(0, $width - (Get-VisibleTextLength $fitted))
		[Console]::SetCursorPosition(0, $i)
		# No newline: do not wrap or scroll the buffer while replacing rows.
		Write-UiSurface -Text ($fitted + [String]::new(' ', $padding)) -NoNewline
	}
	if ((Get-UiConsoleSize).Key -ne $Size.Key) {
		throw [InvalidOperationException]::new('Console resized during redraw.')
	}
	[Console]::SetCursorPosition(0, [Math]::Min($visible.Count, $capacity))
	$State.Lines = $visible
	$State.SizeKey = $Size.Key
	$State.NeedsRedraw = $false
}

function Write-UiText {
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyString()]
		[string]$Text,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Header', 'Secondary', 'Success', 'Error', 'Progress', 'Prompt', 'Accent')]
		[string]$Style,

		[switch]$NoNewline
	)

	Initialize-Ui

	if ($global:UiState.UseVt) {
		$line = Format-UiText -Text $Text -Style $Style
		if ($NoNewline) {
			Write-Host $line -NoNewline
		} else {
			Write-Host $line
		}
		return
	}

	$color = $global:UiState.Fallback[$Style]
	if ($color) {
		if ($NoNewline) {
			Write-Host $Text -NoNewline -ForegroundColor $color
		} else {
			Write-Host $Text -ForegroundColor $color
		}
	}
	elseif ($NoNewline) {
		Write-Host $Text -NoNewline
	}
	else {
		Write-Host $Text
	}
}

function Write-Success {
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyString()]
		[string]$Message
	)

	Write-UiLine -Text $Message -Style Success
}

function Write-ErrorMessage {
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyString()]
		[string]$Message
	)

	Write-UiLine -Text $Message -Style Error
}

function Show-Header {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Title,

		[ValidateSet('Header', 'Secondary', 'Success', 'Error', 'Progress', 'Prompt', 'Accent')]
		[string]$Style = 'Header'
	)

	Write-UiLine
	Write-UiLine -Text $Title -Style $Style
	Write-UiLine -Text ("-" * $Title.Length) -Style $Style
}

function New-BoxLayout {
	param(
		[int]$WindowWidth = [Console]::WindowWidth
	)

	# Code points so Windows PowerShell 5.1 can parse this file without a UTF-8 BOM.
	$boxH = [char]0x2500
	$boxV = [char]0x2502
	$boxTL = [char]0x250C
	$boxTR = [char]0x2510
	$boxBL = [char]0x2514
	$boxBR = [char]0x2518
	$boxVL = [char]0x251C
	$boxVR = [char]0x2524

	$consoleWidth = [Math]::Max(0, $WindowWidth - 1)
	$innerWidth = [Math]::Max(0, $consoleWidth - 2)

	$borderFill = [String]::new($boxH, $innerWidth)
	$emptyFill = [String]::new(' ', $innerWidth)

	return [pscustomobject]@{
		ConsoleWidth = $consoleWidth
		InnerWidth = $innerWidth
		Bar = $boxV
		Top = $boxTL + $borderFill + $boxTR
		Bottom = $boxBL + $borderFill + $boxBR
		Cross = $boxVL + $borderFill + $boxVR
		Middle = $boxV + $emptyFill + $boxV
	}
}

function Format-Box {
	param(
		$Layout,
		[string]$Title,
		[string[]]$Rows,
		[switch]$WrapRows,
		[switch]$TrailingBlank
	)

	$Title = Format-UiFittedText -Text $Title -Width $Layout.InnerWidth
	$titlePad = [Math]::Max(0, $Layout.InnerWidth - (Get-VisibleTextLength $Title))
	$box = @(
		$Layout.Top
		$Layout.Bar + $Title + [String]::new(' ', $titlePad) + $Layout.Bar
		$Layout.Cross
	)

	$displayRows = if ($WrapRows) {
		foreach ($row in $Rows) { Format-UiWrappedText -Text $row -Width $Layout.InnerWidth }
	} else { $Rows }
	foreach ($row in $displayRows) {
		if ([string]::IsNullOrEmpty($row)) {
			$box += $Layout.Middle
		} else {
			$row = Format-UiFittedText -Text $row -Width $Layout.InnerWidth
			$pad = [Math]::Max(0, $Layout.InnerWidth - (Get-VisibleTextLength $row))
			$box += $Layout.Bar + $row + [String]::new(' ', $pad) + $Layout.Bar
		}
	}

	$box += $Layout.Bottom

	if ($TrailingBlank) {
		$box += ""
	}

	return $box
}

function Write-BoxLine {
	param(
		$Layout,
		[string]$Text,
		[string]$Style
	)

	$Text = Format-UiFittedText -Text $Text -Width $Layout.InnerWidth
	Write-UiSurface -Text $Layout.Bar -NoNewline

	$visibleLength = Get-VisibleTextLength $Text
	$pad = [Math]::Max(0, $Layout.InnerWidth - $visibleLength)
	$padded = $Text + [String]::new(' ', $pad)
	if (-not [string]::IsNullOrWhiteSpace($Style)) {
		Write-UiText -Text $padded -Style $Style -NoNewline
	} else {
		Write-UiSurface -Text $padded -NoNewline
	}

	Write-UiSurface -Text $Layout.Bar
}

function Show-InfoBox {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Title,

		[string[]]$Rows,

		[switch]$TrailingBlank,

		[ValidateSet('Header', 'Secondary', 'Success', 'Error', 'Progress', 'Prompt', 'Accent')]
		[string]$TitleStyle = 'Header'
	)

	$titleText = Format-UiText -Text "  $Title" -Style $TitleStyle
	Add-UiBlock @{ Kind = 'Box'; Title = $titleText; Rows = $Rows; TrailingBlank = [bool]$TrailingBlank }
	Update-UiScreen
}

function Get-UiInputBoundary {
	param([string]$Text, [int]$Position, [switch]$Forward)

	$offsets = [Globalization.StringInfo]::ParseCombiningCharacters($Text)
	if ($Forward) {
		foreach ($offset in $offsets) { if ($offset -gt $Position) { return $offset } }
		return $Text.Length
	}
	$previous = 0
	foreach ($offset in $offsets) {
		if ($offset -ge $Position) { break }
		$previous = $offset
	}
	return $previous
}

function New-UiInputLine {
	param([hashtable]$InputState, [int]$Width)

	$prefix = Format-UiFittedText -Text ($InputState.Prompt + ': ') -Width ([Math]::Max(0, $Width - 2))
	$prefixWidth = Get-VisibleTextLength $prefix
	$available = [Math]::Max(0, $Width - $prefixWidth - 1)
	$displayValue = ConvertTo-UiDisplayText -Text $InputState.Value
	$start = [Math]::Min($InputState.Start, $InputState.Position)
	# Widening the window should reveal text again, including the beginning.
	if ($InputState.Width -ne $Width) { $start = 0; $InputState.Width = $Width }
	# Scroll the displayed portion of long input while retaining the full value.
	while ($start -lt $InputState.Position -and (Get-VisibleTextLength $displayValue.Substring($start, $InputState.Position - $start)) -gt $available) {
		$start = Get-UiInputBoundary -Text $InputState.Value -Position $start -Forward
	}
	$InputState.Start = $start
	$text = Format-UiFittedText -Text $displayValue.Substring($start) -Width ($available + 1)
	$column = $prefixWidth + (Get-VisibleTextLength $displayValue.Substring($start, $InputState.Position - $start))
	return @{ Text = (Format-UiText -Text $prefix -Style Prompt) + $text; Column = [Math]::Min($column, [Math]::Max(0, $Width - 1)) }
}

function Read-UiInput {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Prompt
	)

	if ($null -eq $script:UiScreen) { Reset-UiScreen }
	if ($null -eq $script:UiInputHistory) { $script:UiInputHistory = [System.Collections.Generic.List[string]]::new() }
	$inputState = @{ Prompt = $Prompt; Value = ''; Position = 0; Start = 0 }
	$historyIndex = $script:UiInputHistory.Count
	$draft = ''
	$overwrite = $false
	$screen = $script:UiScreen
	try {
		# Hosts without console key events retain their normal line input.
		if (-not $global:UiState.InteractiveConsole) {
			Update-UiScreen
			Write-UiText -Text "${Prompt}: " -Style Prompt -NoNewline
			$value = if ([Console]::IsInputRedirected) { [Console]::ReadLine() } else { $Host.UI.ReadLine() }
			return [string]$value
		}
		$screen.Input = $inputState
		$screen.Dirty = $true
		Set-UiCursorVisible -Visible $true
		while ($true) {
			# Bound each batch so a large paste cannot starve resize handling.
			for ($batch = 0; $batch -lt 64 -and [Console]::KeyAvailable; $batch++) {
				$key = [Console]::ReadKey($true)
				$control = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
				$shift = ($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
				$value = $inputState.Value
				$position = $inputState.Position
				$insert = ''
				if ($control -and $key.Key -eq [ConsoleKey]::C) {
					throw [System.Management.Automation.PipelineStoppedException]::new()
				}
				if (($control -and $key.Key -eq [ConsoleKey]::V) -or ($shift -and $key.Key -eq [ConsoleKey]::Insert)) {
					try {
						# Windows PowerShell's normal console runs in STA. This is a
						# built-in Windows assembly, not an external dependency.
						Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
						# A prompt accepts one line. Do not turn pasted line breaks
						# into spaces inside a path, or submit another prompt.
						$insert = ([System.Windows.Forms.Clipboard]::GetText() -split '\r\n|\r|\n')[0]
					} catch { Write-UiLine -Text 'Clipboard unavailable. Try pasting again or type the value.' -Style Error }
				}
				else {
					switch ($key.Key) {
						'Enter' {
							$screen.Input = $null
							Write-UiLine -Text ((Format-UiText -Text "${Prompt}: " -Style Prompt) + (ConvertTo-UiDisplayText $value))
							if ($value.Length -gt 0) {
								$script:UiInputHistory.Add($value)
								if ($script:UiInputHistory.Count -gt 100) { $script:UiInputHistory.RemoveAt(0) }
							}
							return $value
						}
						'LeftArrow' {
							if ($control) { $position = [regex]::Match($value.Substring(0, $position), '\S+\s*$').Index }
							else { $position = Get-UiInputBoundary -Text $value -Position $position }
						}
						'RightArrow' {
							if ($control) { $position += [regex]::Match($value.Substring($position), '^\s*\S+\s*').Length }
							else { $position = Get-UiInputBoundary -Text $value -Position $position -Forward }
						}
						'Home' { if ($control) { $value = $value.Substring($position) }; $position = 0 }
						'End' { if ($control) { $value = $value.Substring(0, $position) }; $position = $value.Length }
						'Backspace' {
							$previous = if ($control) { [regex]::Match($value.Substring(0, $position), '\S+\s*$').Index }
							else { Get-UiInputBoundary -Text $value -Position $position }
							$value = $value.Remove($previous, $position - $previous)
							$position = $previous
						}
						'Delete' {
							$next = if ($control) { $position + [regex]::Match($value.Substring($position), '^\s*\S+\s*').Length }
							else { Get-UiInputBoundary -Text $value -Position $position -Forward }
							$value = $value.Remove($position, $next - $position)
						}
						'Escape' { $value = ''; $position = 0 }
						'Insert' { $overwrite = -not $overwrite }
						{ $_ -eq 'UpArrow' -or $_ -eq 'DownArrow' } {
							if ($historyIndex -eq $script:UiInputHistory.Count) { $draft = $value }
							if ($key.Key -eq [ConsoleKey]::UpArrow) { $historyIndex = [Math]::Max(0, $historyIndex - 1) }
							else { $historyIndex = [Math]::Min($script:UiInputHistory.Count, $historyIndex + 1) }
							$value = if ($historyIndex -eq $script:UiInputHistory.Count) { $draft } else { $script:UiInputHistory[$historyIndex] }
							$position = $value.Length
						}
						default { if (-not [char]::IsControl($key.KeyChar)) { $insert = [string]$key.KeyChar } }
					}
				}
				if ($insert.Length -gt 0) {
					if ($overwrite -and $position -lt $value.Length) {
						$next = $position
						foreach ($offset in [Globalization.StringInfo]::ParseCombiningCharacters($insert)) {
							$next = Get-UiInputBoundary -Text $value -Position $next -Forward
						}
						$value = $value.Remove($position, $next - $position)
					}
					$value = $value.Insert($position, $insert)
					$position += $insert.Length
				}
				if ($inputState.Value -cne $value) { $inputState.Start = 0 }
				$inputState.Value = $value
				$inputState.Position = $position
				$screen.Dirty = $true
			}
			Update-UiScreen
			Start-Sleep -Milliseconds 50
		}
	}
	finally {
		$screen.Input = $null
		$screen.Dirty = $true
		Set-UiCursorVisible -Visible $true
	}
}

function New-UiMenuLines {
	param([int]$WindowWidth, $Menu)

	$layout = New-BoxLayout -WindowWidth $WindowWidth
	$title = Format-UiText -Text "  $($Menu.Title)" -Style $Menu.TitleStyle
	$rows = @()
	foreach ($option in $Menu.Options) {
		$keyText = Format-UiText -Text "[$($option.Key)]" -Style Prompt
		$rows += "  $keyText  $($option.Label)"
		if ([string]::IsNullOrWhiteSpace($option.Description)) { $rows += '' }
		else { $rows += Format-UiText -Text "       $($option.Description)" -Style Secondary }
	}
	$box = @(Format-Box -Layout $layout -Title $title -Rows $rows -WrapRows)
	if ($Menu.Details.Count -gt 0) {
		$details = @(foreach ($detail in $Menu.Details) { Format-UiText -Text $detail -Style Secondary })
		$detailBox = @(Format-Box -Layout $layout -Title $title -Rows $details -WrapRows)
		$box = @($detailBox[0..($detailBox.Count - 2)]) + @($layout.Cross) + @($box[3..($box.Count - 1)])
	}
	return @('') + $box + @('')
}

function Read-MenuChoice {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Title,

		[Parameter(Mandatory = $true)]
		[hashtable[]]$Options,

		[string[]]$Details,

		[string]$Prompt,

		[switch]$NoClear,

		[ValidateSet('Header', 'Secondary', 'Success', 'Error', 'Progress', 'Prompt', 'Accent')]
		[string]$TitleStyle = 'Header'
	)

	$keys = foreach ($option in $Options) {
		[string]$option.Key
	}

	if ([string]::IsNullOrWhiteSpace($Prompt)) {
		$Prompt = "Enter choice ($($keys[0])-$($keys[-1]))"
	}

	if (-not $NoClear) { Reset-UiScreen }
	Add-UiBlock @{
		Kind = 'Custom'
		Static = $true
		Builder = ${function:New-UiMenuLines}
		Data = @{ Title = $Title; TitleStyle = $TitleStyle; Options = $Options; Details = $Details }
	}
	Update-UiScreen

	do {
		$choice = Read-UiInput -Prompt $Prompt
		$choice = $choice.Trim().Trim('"')

		if ($choice -notin $keys) {
			Write-ErrorMessage "Invalid choice. Enter a number in the range $($keys[0])-$($keys[-1])."
		}
	} while ($choice -notin $keys)

	return $choice
}

function New-UiFinishedLines {
	param([int]$WindowWidth, $Data)

	$label = ' FINISHED '
	$boxWidth = [Math]::Max(0, $WindowWidth - 1)
	$width = [Math]::Max($label.Length, $boxWidth - 4)
	$pad = $width - $label.Length
	$left = [int][Math]::Floor($pad / 2)
	$right = $pad - $left
	$inset = [Math]::Max(0, [int][Math]::Floor(($boxWidth - $width) / 2))
	$rule = [char]0x2500
	return @('', ([String]::new(' ', $inset) +
		(Format-UiText -Text ([String]::new($rule, $left)) -Style Secondary) +
		(Format-UiText -Text $label -Style Success) +
		(Format-UiText -Text ([String]::new($rule, $right)) -Style Secondary)))
}

function Read-AfterToolChoice {
	Add-UiBlock @{ Kind = 'Custom'; Static = $true; Builder = ${function:New-UiFinishedLines}; Data = $null }
	$choice = Read-MenuChoice -Title 'Next' -NoClear -TitleStyle Header -Options @(
		@{ Key = '1'; Label = 'Back to main menu' }
		@{ Key = '2'; Label = 'Exit' }
	)

	if ($choice -eq '2') {
		Write-UiLine -Text "Exiting."
		exit 0
	}
}

Initialize-Ui
