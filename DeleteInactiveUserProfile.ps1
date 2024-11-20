# Define the number of days to keep user profiles (set this variable as per your requirement)
$daysToKeep = Days 

# Get the current date and time
$currentDate = Get-Date 

# Retrieve all user profiles on the system, excluding special system profiles
$profiles = Get-WmiObject Win32_UserProfile | Where-Object { $_.Special -eq $false } 

# Loop through each user profile
foreach ($profile in $profiles) { 

    # Convert the last use time of the profile to a DateTime object
    $lastUseDate = $profile.ConvertToDateTime($profile.LastUseTime) 

    # Calculate the number of days since the profile was last used
    $daysSinceLastUse = ($currentDate - $lastUseDate).Days 

    # Check if the profile has been inactive for the specified number of days
    if ($daysSinceLastUse -ge $daysToKeep) { 

        # Delete the user profile
        Remove-WmiObject -InputObject $profile 

        # Output a message indicating the deleted profile
        Write-Host "Deleted profile $($profile.LocalPath)" 
    } 
} 

# Output a message indicating that the cleanup process is complete
Write-Host "Profile cleanup complete."
