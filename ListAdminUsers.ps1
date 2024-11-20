# Get a list of local groups that have administrators 
$adminGroup = Get-LocalGroupMember -Group "Administrators" 

# Output the members of the administrators group 
Write-Host "Users with administrator privileges:" 
foreach ($user in $adminGroup) { 
    Write-Host $user.Name 
}
