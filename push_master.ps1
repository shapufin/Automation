# PowerShell script to merge development into master and push
$ErrorActionPreference = "Stop"

# Colors for output
$successColor = "Green"
$errorColor = "Red"
$infoColor = "Cyan"
$warningColor = "Yellow"

try {
    # Get current directory
    $repoPath = Split-Path -Parent $MyInvocation.MyCommand.Path
    Set-Location $repoPath

    Write-Host "📂 Current directory: $repoPath" -ForegroundColor $infoColor

    # Confirm with user
    Write-Host "⚠️ This will merge development into master and push to production!" -ForegroundColor $warningColor
    $confirm = Read-Host "Are you sure you want to continue? (y/n)"
    if ($confirm -ne "y") {
        Write-Host "❌ Operation cancelled by user" -ForegroundColor $errorColor
        exit 0
    }

    # Switch to development and pull latest changes
    Write-Host "🔄 Updating development branch..." -ForegroundColor $infoColor
    git checkout development
    git pull origin development

    # Switch to master
    Write-Host "🔄 Switching to master branch..." -ForegroundColor $infoColor
    git checkout master
    git pull origin master

    # Merge development into master
    Write-Host "🔄 Merging development into master..." -ForegroundColor $infoColor
    $mergeResult = git merge development 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Merge conflict detected! Please resolve conflicts manually" -ForegroundColor $errorColor
        Write-Host $mergeResult
        exit 1
    }

    # Get commit message from user
    $commitMessage = Read-Host "Enter production deployment message (optional)"
    if (-not $commitMessage) {
        $commitMessage = "Production deployment: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }

    # Add and commit any merge changes
    git add .
    git commit -m $commitMessage

    # Push to master
    Write-Host "⬆️ Pushing to master branch..." -ForegroundColor $infoColor
    git push origin master

    Write-Host "✅ Successfully merged development into master and pushed!" -ForegroundColor $successColor
    
    # Switch back to development
    Write-Host "🔄 Switching back to development branch..." -ForegroundColor $infoColor
    git checkout development

} catch {
    Write-Host "❌ Error: $_" -ForegroundColor $errorColor
    exit 1
}

# Keep window open
Write-Host "`nPress any key to exit..." -ForegroundColor $infoColor
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
