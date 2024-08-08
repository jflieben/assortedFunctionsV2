Function Get-PnPGroupMembers{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$name,
        $parentId,
        [Parameter(Mandatory=$true)]$siteConn
    )

    Write-Verbose "Getting members for group $name"

    if($Null -eq $global:groupCache){
        $global:groupCache = @{}
    }
    if($global:groupCache.Keys -contains $name){
        return $global:groupCache.$name
    }else{
        $global:groupCache.$name = @()
    }

    $members = Get-PnPGroupMember -Group $name -Connection $siteConn
    foreach($member in $members){   
        $groupGuid = $Null; try{$groupGuid = $member.LoginName.Split("|")[2].Split("_")[0]}catch{$groupGuid = $Null}
        if($member.LoginName -like "*spo-grid-all-users*" -or $member.LoginName -eq "c:0(.s|true"){
            Write-Verbose "Found $($member.Title) special group"
            $global:groupCache.$name += $member
            continue
        }
        if($groupGuid -and [guid]::TryParse($groupGuid, $([ref][guid]::Empty))){
            $graphMembers = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/groups/$groupGuid/transitiveMembers" -Method GET | Where-Object { $_."@odata.type" -eq "#microsoft.graph.user" }
            foreach($graphMember in $graphMembers){
                if(!($global:groupCache.$name.LoginName | Where-Object {$_ -and $_.EndsWith($graphMember.userPrincipalName)})){
                    Write-Verbose "Found $($graphMember.displayName) in graph group"
                    $global:groupCache.$name += [PSCustomObject]@{
                        "Title" = $graphMember.displayName
                        "LoginName" = "i:0#.f|membership|$($graphMember.userPrincipalName)"
                        "PrincipalType" = "User"
                        "Email" = $graphMember.mail
                    }
                }
            }
            continue
        }        
        if($member.Id -ne $parentId){
            if($member.PrincipalType -eq "User" -and $global:groupCache.$name -notcontains $member){
                Write-Verbose "Found $($member.Title) in sec group"
                $global:groupCache.$name += $member
                continue
            }
            if($member.PrincipalType -eq "SecurityGroup" -or $member.PrincipalType -eq "SharePointGroup"){
                $subMembers = Get-PnPGroupMembers -name $member.Title -parentId $member.Id -siteConn $siteConn
                foreach($subMember in $subMembers){
                    if($global:groupCache.$name -notcontains $subMember){
                        Write-Verbose "Found $($subMember.Title) in sub sec group"
                        $global:groupCache.$name += $subMember
                    }
                }
            }
        }
    }
    return $global:groupCache.$name
}