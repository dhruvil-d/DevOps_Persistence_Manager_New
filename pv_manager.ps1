# PowerShell wrapper for testing pv_manager.sh locally on Windows
param (
    [Parameter(Position=0)]
    [string]$Command = "help",
    
    [Parameter(Position=1)]
    [string]$Archive
)

# Pass the Windows kubeconfig explicitly to bash
$env:KUBECONFIG = "$env:USERPROFILE\.kube\config"

$GIT_BASH = "C:\Program Files\Git\bin\bash.exe"

if (-not (Test-Path $GIT_BASH)) {
    Write-Error "Git Bash not found at $GIT_BASH. Please install Git for Windows to run this script locally."
    exit 1
}

# Prevent Git Bash from rewriting "pod:/data" into "pod;C:\data"
$env:MSYS_NO_PATHCONV = "1"

if ($Archive) {
    & $GIT_BASH scripts/pv_manager.sh $Command $Archive
} else {
    & $GIT_BASH scripts/pv_manager.sh $Command
}
