# Bypassing param() to avoid RMM injection errors
# The RMM Command Line should be: -ProtectedUsers "Administrator, Public, Default, User77"

$ArgIndex = $args.IndexOf("-ProtectedUsers")
if ($ArgIndex -ge 0 -and ($ArgIndex + 1) -lt $args.Count) {
    # Extract the string, remove quotes, and split into an array
    $ProtectedUsers = $args[$ArgIndex + 1].Replace('"', '').Replace("'", "").Split(',').Trim()
} else {
    Write-Host "No protected users found in arguments. Proceeding with defaults."
    $ProtectedUsers = @("Administrator", "Public", "Default")
}

$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    # Check for match (using -like for wildcard protection against domain prefixes)
    $IsProtected = $false
    foreach ($PUser in $ProtectedUsers) {
        if (-not [string]::IsNullOrWhiteSpace($PUser) -and $UserName -like "*$PUser*") {
            $IsProtected = $true
            break
        }
    }

    if ($IsProtected) {
        Write-Host ("Skipping protected profile: " + $UserName)
        continue
    }
    
    if ($Profile.Loaded) {
        Write-Host ("Skipping " + $UserName + " - Loaded")
        continue
    }

    Write-Host ("Deleting: " + $UserName)
    $Profile | Remove-CimInstance -Verbose
}
