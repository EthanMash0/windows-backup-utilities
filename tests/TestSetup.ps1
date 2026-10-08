$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LibRoot = Join-Path $script:RepoRoot 'lib'

. (Join-Path $script:LibRoot 'Ui.ps1')
. (Join-Path $script:LibRoot 'Common.ps1')
. (Join-Path $script:LibRoot 'FolderSize.ps1')
