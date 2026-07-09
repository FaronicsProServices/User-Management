$ArgIndex = $args.IndexOf("-ProtectedUsers")
if ($ArgIndex -ge 0 -and ($ArgIndex + 1) -lt $args.Count) {
    # CRITICAL: We force the split and then explicitly show what was parsed
    $RawList = $args[$ArgIndex + 1]
    $ProtectedProfiles = $RawList.Split(',').ForEach({$_.Trim().Replace('"', '').Replace("'", "")})
    
    # DEBUG: This will show in your RMM log exactly what users are protected
    Write-Host ("DEBUG: Protected list identified: " + ($ProtectedProfiles -join ", "))
} else {
    $ProtectedProfiles = @("Administrator", "Public", "Default")
}

$Profiles = Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.Special -eq $false }

foreach ($Profile in $Profiles) {
    $UserName = Split-Path $Profile.LocalPath -Leaf
    
    $IsProtected = $false
    foreach ($PUser in $ProtectedProfiles) {
        # Check if the name matches exactly OR if it's contained within
        if ($UserName -eq $PUser -or $UserName -like "*$PUser*") {
            $IsProtected = $true
            break
        }
    }

    if ($IsProtected) {
        Write-Host ("Skipping protected profile: " + $UserName)
        continue
    }
    
    if ($Profile.Loaded) {
        Write-Host ("Skipping " + $UserName + " - Profile is loaded/in use")
        continue
    }

    Write-Host ("Deleting: " + $UserName)
    $Profile | Remove-CimInstance -Verbose
}
