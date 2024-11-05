Function Get-PnPGroupMembers{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory=$true)]$group,
        $parentId,
        [Parameter(Mandatory=$true)]$siteConn
    )

    Write-Verbose "Getting members for group $($group.Title)"

    if($Null -eq $global:PnPGroupCache){
        $global:PnPGroupCache = @{}
    }
    if($global:PnPGroupCache.Keys -contains $($group.Title)){
        return $global:PnPGroupCache.$($group.Title)
    }else{
        $global:PnPGroupCache.$($group.Title) = @()
    }

    $groupGuid = $Null; try{$groupGuid = $group.LoginName.Split("|")[2].Split("_")[0]}catch{$groupGuid = $Null}
    if($group.LoginName.Split("|")[0] -eq "c:0(.s"){
        Write-Verbose "Found $($group.Title) special group"
        $global:PnPGroupCache.$($group.Title) += [PSCustomObject]@{
            "Title" = $group.Title
            "LoginName" = $group.LoginName
            "PrincipalType" = "SecurityGroup"
            "Email" = "N/A"
        }
    }elseif($group.LoginName.Split("|")[0] -eq "c:0-.f"){
        Write-Verbose "Found $($group.Title) special group"
        $global:PnPGroupCache.$($group.Title) += [PSCustomObject]@{
            "Title" = $group.Title
            "LoginName" = $group.LoginName
            "PrincipalType" = "SecurityGroup"
            "Email" = "N/A"
        }
    }elseif($group.LoginName.Split("|")[0] -eq "c:0t.c"){
        Write-Verbose "Found $($group.Title) special group (global administrators)"
        $global:PnPGroupCache.$($group.Title) += [PSCustomObject]@{
            "Title" = $group.Title
            "LoginName" = $group.LoginName
            "PrincipalType" = "Role"
            "Email" = "N/A"
        }
    }elseif($groupGuid -and [guid]::TryParse($groupGuid, $([ref][guid]::Empty))){
        try{
            $graphMembers = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/groups/$groupGuid/transitiveMembers" -Method GET | Where-Object { $_."@odata.type" -eq "#microsoft.graph.user" }
        }catch{
            $graphMembers = @(
                [PSCustomObject]@{
                    "displayName" = $group.Title
                    "userPrincipalName" = $groupGuid
                    "mail" = "FAILED TO ENUMERATE (DELETED?) GROUP MEMBERS!"
                }
            )
        }
        foreach($graphMember in $graphMembers){
            if(!($global:PnPGroupCache.$($group.Title).LoginName | Where-Object {$_ -and $_.EndsWith($graphMember.userPrincipalName)})){
                Write-Verbose "Found $($graphMember.displayName) in graph group"
                $global:PnPGroupCache.$($group.Title) += [PSCustomObject]@{
                    "Title" = $graphMember.displayName
                    "LoginName" = "i:0#.f|membership|$($graphMember.userPrincipalName)"
                    "PrincipalType" = "User"
                    "Email" = $graphMember.mail
                }
            }
        }
    }else{
        $members = Get-PnPGroupMember -Group $group.Id -Connection (Get-SpOConnection -Type User -Url $site.Url)
        foreach($member in $members){   
            $groupGuid = $Null; try{$groupGuid = $member.LoginName.Split("|")[2].Split("_")[0]}catch{$groupGuid = $Null}
            if($member.LoginName -like "*spo-grid-all-users*" -or $member.LoginName -eq "c:0(.s|true"){
                Write-Verbose "Found $($member.Title) special group"
                $global:PnPGroupCache.$($group.Title) += $member
                continue
            }
            if($groupGuid -and [guid]::TryParse($groupGuid, $([ref][guid]::Empty))){
                try{
                    $graphMembers = New-GraphQuery -Uri "https://graph.microsoft.com/v1.0/groups/$groupGuid/transitiveMembers" -Method GET | Where-Object { $_."@odata.type" -eq "#microsoft.graph.user" }
                }catch{
                    $graphMembers = @(
                        [PSCustomObject]@{
                            "displayName" = $group.Title
                            "userPrincipalName" = $groupGuid
                            "mail" = "FAILED TO ENUMERATE (DELETED?) GROUP MEMBERS!"
                        }
                    )
                }
                foreach($graphMember in $graphMembers){
                    if(!($global:PnPGroupCache.$($group.Title).LoginName | Where-Object {$_ -and $_.EndsWith($graphMember.userPrincipalName)})){
                        Write-Verbose "Found $($graphMember.displayName) in graph group"
                        $global:PnPGroupCache.$($group.Title) += [PSCustomObject]@{
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
                if($member.PrincipalType -eq "User" -and $global:PnPGroupCache.$($group.Title) -notcontains $member){
                    Write-Verbose "Found $($member.Title) in sec group"
                    $global:PnPGroupCache.$($group.Title) += $member
                    continue
                }
                if($member.PrincipalType -eq "SecurityGroup" -or $member.PrincipalType -eq "SharePointGroup"){
                    $subMembers = Get-PnPGroupMembers -name $member.Title -parentId $member.Id -siteConn $siteConn
                    foreach($subMember in $subMembers){
                        if($global:PnPGroupCache.$($group.Title) -notcontains $subMember){
                            Write-Verbose "Found $($subMember.Title) in sub sec group"
                            $global:PnPGroupCache.$($group.Title) += $subMember
                        }
                    }
                }
            }
        }
    }   

    return $global:PnPGroupCache.$($group.Title)
}