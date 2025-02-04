$ErrorActionPreference = "Stop"

# Script to rebuild and prepare the Mattermost plugin for deployment
Write-Host "Starting plugin rebuild process..." -ForegroundColor Cyan

# Set Go path
$GO = "C:\Program Files\Go\bin\go.exe"

# Clean up
Write-Host "Cleaning up old build files..." -ForegroundColor Yellow
if (Test-Path dist) {
    Remove-Item -Recurse -Force dist
}

# Create directories
Write-Host "Creating build directories..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path dist/server | Out-Null

# Set environment variables for Linux build
Write-Host "Setting up Linux build environment..." -ForegroundColor Yellow
$env:GOOS = "linux"
$env:GOARCH = "amd64"

# Initialize and download dependencies
Write-Host "Downloading dependencies..." -ForegroundColor Yellow
& $GO mod tidy
& $GO mod download

# Build for Linux
Write-Host "Building plugin..." -ForegroundColor Yellow
& $GO build -o dist/server/plugin.exe ./server
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!" -ForegroundColor Red
    exit 1
}

# Copy plugin files
Write-Host "Copying plugin files..." -ForegroundColor Yellow
Copy-Item plugin.json dist/

# Create tar archive
Write-Host "Creating plugin package..." -ForegroundColor Yellow
Push-Location dist
tar -czf custom-groups-plugin.tar.gz plugin.json server/plugin.exe
Pop-Location

Write-Host "Build completed successfully!" -ForegroundColor Green
Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "1. Upload 'dist/custom-groups-plugin.tar.gz' to your Mattermost server" -ForegroundColor White
Write-Host "2. Enable the plugin in System Console" -ForegroundColor White
