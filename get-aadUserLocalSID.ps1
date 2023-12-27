Function get-aadUserLocalSID{
    Param(
        [Parameter(Mandatory=$true)]
        [string]$username
    )
    $profiles = Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    foreach($profile in $profiles){
        if($username -eq $profile.GetValue("ProfileImagePath").Split("\")[-1]){
            return $profile.PSChildName
        }
    }
}