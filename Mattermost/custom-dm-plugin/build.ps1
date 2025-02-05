# Set Go path
$GO = "C:\Program Files\Go\bin\go.exe"

# Set environment variables for Linux build
$env:GOOS = "linux"
$env:GOARCH = "amd64"

# Clean up
if (Test-Path dist) {
    Remove-Item -Recurse -Force dist
}

# Create directories
New-Item -ItemType Directory -Force -Path dist/server | Out-Null

# Initialize and download dependencies
& $GO mod tidy
& $GO mod download

# Build for Linux
& $GO build -o dist/server/plugin.exe ./server

# Copy plugin files
Copy-Item plugin.json dist/

# Create tar archive
Set-Location dist
tar -czf custom-dm-plugin.tar.gz plugin.json server/plugin.exe
Set-Location ..
