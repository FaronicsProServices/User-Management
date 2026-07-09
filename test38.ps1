param(
    [Parameter(Mandatory=$false)]
    [string]$ProtectedUsers # Changed from [string[]] to [string]
)

# If input is provided, split the long string into an array by comma
if ($ProtectedUsers) {
    $ProtectedList = $ProtectedUsers.Split(',').Trim().Replace('"', '').Replace("'", "")
} else {
    $ProtectedList = @()
}

$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # Check if the user is in our new array
    if ($ProtectedList -contains $UserName) {
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
