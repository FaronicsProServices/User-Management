# --- CONFIGURATION ---
$ProtectedProfiles = @("Administrator", "DeployAgentUser", "Public", "Default")

# Use a safe path for logs
$LogPath = "C:\Windows\Temp\ProfileCleanup.log"
Start-Transcript -Path $LogPath -Append -Force

# Get all user profiles
$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    # Extract the username
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # 1. Check if the profile is in the protected list
    if ($ProtectedProfiles -contains $UserName) {
        Write-Host "Skipping protected profile: $UserName" -ForegroundColor Yellow
        continue
    }
    
    # 2. Check if the user is currently logged on
    if ($Profile.Loaded) {
        Write-Host "Skipping $UserName: User is currently logged on." -ForegroundColor Yellow
        continue
    }

    # 3. Execute the deletion
    Write-Host "Attempting to delete profile: $UserName" -ForegroundColor Red
    try {
        $Profile | Remove-CimInstance -ErrorAction Stop
        Write-Host "Successfully deleted $UserName" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to remove profile $UserName via WMI. Error: $($_.Exception.Message)"
    }
}

Stop-Transcript
