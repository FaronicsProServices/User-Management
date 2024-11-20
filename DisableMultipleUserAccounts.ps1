# Define a list of user accounts that need to be disabled
$usersToDisable = @("User1", "User2")

# Loop through each user in the list and disable their account
foreach ($user in $usersToDisable) { 
    # Disable the user account by specifying the username
    Disable-LocalUser -Name $user 
}

# The script will iterate through the list of users and disable each account
# Make sure to replace "User1", "User2" with the actual usernames you want to disable
