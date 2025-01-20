# PowerShell script to push to development branch
$ErrorActionPreference = "Stop"

# Colors for output
$successColor = "Green"
$errorColor = "Red"
$infoColor = "Cyan"

try {
    # Get current directory
    $repoPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    Set-Location $repoPath

    Write-Host " Current directory: $repoPath" -ForegroundColor $infoColor

    # Check if there are changes to commit
    $status = git status --porcelain
    if ($status) {
        Write-Host " Changes detected, preparing to push to development..." -ForegroundColor $infoColor
        
        # Switch to development branch
        Write-Host " Switching to development branch..." -ForegroundColor $infoColor
        git checkout development

        # Pull latest changes
        Write-Host " Pulling latest changes..." -ForegroundColor $infoColor
        git pull origin development

        # Add all changes
        Write-Host " Adding changes..." -ForegroundColor $infoColor
        git add .

        # Get commit message from user
        $commitMessage = Read-Host "Enter commit message"
        if (-not $commitMessage) {
            $commitMessage = "Update: Development changes $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        }

        # Commit changes
        Write-Host " Committing changes..." -ForegroundColor $infoColor
        git commit -m "$commitMessage"

        # Push to development
        Write-Host " Pushing to development branch..." -ForegroundColor $infoColor
        git push origin development

        Write-Host " Successfully pushed to development!" -ForegroundColor $successColor
    } else {
        Write-Host " No changes to commit" -ForegroundColor $infoColor
    }
} catch {
    Write-Host " Error: $_" -ForegroundColor $errorColor
    exit 1
}

# Keep window open
Write-Host "`nPress any key to exit..." -ForegroundColor $infoColor
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
