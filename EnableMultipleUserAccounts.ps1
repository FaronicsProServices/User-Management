# Define a list of usernames that need to be enabled
# Add the usernames you want to enable in the array below
$usersToEnable = @("User1", "User2")

# Loop through each user in the list and enable their account
foreach ($user in $usersToEnable) { 
    # Enable the specified user account, allowing them to log in again
    Enable-LocalUser -Name $user
}

# The script will enable the accounts for "User1" and "User2".
# If you want to enable different users, just update the list.
