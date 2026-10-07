$Host.UI.RawUI.WindowTitle = 'STC Backup Station'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$minWidth = 80
try {
	$Host.UI.RawUI.BackgroundColor = 'Black'
	$Host.UI.RawUI.ForegroundColor = 'White'

	$maxWidth = $Host.UI.RawUI.MaxPhysicalWindowSize.Width
	if ($maxWidth -gt 0 -and $minWidth -gt $maxWidth) {
		$minWidth = $maxWidth
	}

	$buffer = $Host.UI.RawUI.BufferSize
	if ($buffer.Width -lt $minWidth) {
		$buffer.Width = $minWidth
		$Host.UI.RawUI.BufferSize = $buffer
	}

	$window = $Host.UI.RawUI.WindowSize
	if ($window.Width -lt $minWidth) {
		$window.Width = $minWidth
		$Host.UI.RawUI.WindowSize = $window
	}

	Clear-Host
}
catch {
	# Some hosts (ISE, remoting) do not allow console resize or color changes.
}

. "$PSScriptRoot\lib\Ui.ps1"
. "$PSScriptRoot\lib\Common.ps1"

while ($true) {
	$choice = Read-MenuChoice -Title 'STC Windows Backup Station' -Options @(
		@{ Key = '1'; Label = 'Copy Data'; Description = 'Robocopy with Slow / Standard / Fast' }
		@{ Key = '2'; Label = 'Folder Size' }
		@{ Key = '3'; Label = 'Folder Size Comparison' }
		@{ Key = '4'; Label = 'Exit' }
	)

	switch ($choice) {
		'1' {
			. "$PSScriptRoot\lib\Robocopy.ps1"
			$result = Invoke-RobocopyTool
			if ($result.Status -eq 'Completed') {
				Read-AfterCopyChoice -Source $result.Source -Dest $result.Dest -LogFolder $result.LogFolder
			}
		}
		'2' {
			. "$PSScriptRoot\lib\FolderSize.ps1"
			$result = Invoke-FolderSizeTool
			if ($result -eq 'Completed') {
				Read-AfterToolChoice
			}
		}
		'3' {
			. "$PSScriptRoot\lib\FolderSize.ps1"
			$result = Invoke-FolderSizeCompareTool
			if ($result -eq 'Completed') {
				Read-AfterToolChoice
			}
		}
		'4' {
			Write-UiLine -Text "Exiting."
			exit 0
		}
	}
}
