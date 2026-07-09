param(
    [string[]]$ProtectedUsers = $null
)

# If no users are provided in the Command Line, protect nothing (or add a failsafe)
if ($null -eq $ProtectedUsers) {
    Write-Host "No protected users defined in Command Line. Proceeding with caution."
}

$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # Check if the user is in the list provided via Command Line
    if ($ProtectedUsers -contains $UserName) {
        Write-Host ("Skipping protected profile: " + $UserName)
        continue
    }
    
    if ($Profile.Loaded) {
        Write-Host ("Skipping " + $UserName + " - Loaded")
        continue
    }

    Write-Host ("Deleting: " + $UserName)
    $Profile | Remove-CimInstance
}
