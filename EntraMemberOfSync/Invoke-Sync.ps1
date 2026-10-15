<#
    .SYNOPSIS
    Replaces the deprecated Entra ID dynamic group "memberOf" feature. Keeps target groups in sync with the union of one or more source groups, based on a marker in the target group's description. Designed to run standalone in an Azure Automation account using a Managed Identity.

    .DESCRIPTION
    Microsoft is deprecating dynamic membership rules of the form user.memberOf -any (group.objectId -in ['guid','guid']),
    also known as groups-of-groups. This runbook takes over that job without needing a database, a state file or any module.

    It authenticates to Microsoft Graph using the Managed Identity of the host (Azure Automation / VM / App Service) through
    direct HTTPS calls, then:
    1. finds every group that carries a EntraMemberOfSync marker in its description
    2. reads the members of the source groups listed in that marker (direct or transitive, as specified per group)
    3. makes the target group's membership match the union of those source groups, adding and removing where needed

    Marker syntax, placed anywhere in the description of the TARGET group (case insensitive, whitespace tolerated):

        EntraMemberOfSync:<guid>[,<guid>...]                 direct members of the sources (default)
        EntraMemberOfSync:direct:<guid>[,<guid>...]          same, written out explicitly
        EntraMemberOfSync:transitive:<guid>[,<guid>...]      transitive members, so nested source groups are included too

    A description may contain more than one marker, each with its own mode, in which case the results are combined:

        EntraMemberOfSync:direct:2f1a...
        EntraMemberOfSync:transitive:9c40...

    Only user and device objects are synced. Nested groups and service principals found in a source group are ignored,
    which also means this runbook never removes a group or service principal that was assigned to the target directly.

    Safety guards, applied per target group:
    - groups with a dynamic membership rule are skipped (convert them to assigned membership first)
    - groups synced from on premises Active Directory are skipped
    - a target that lists itself as a source has that entry stripped
    - removals are skipped when any source group could not be read this run, or when a marker could not be fully parsed,
      so a transient Graph failure or a typo can never empty a production group. Additions still take place.
    - a Graph response without a member collection counts as a failed read, never as an empty group
    - when all sources are empty while the target still has members, the sources are read a second time. The target
      is only emptied when that second read confirms it

    Any group with an issue (one of the above, or a failed add or remove) is listed at the end and makes the runbook
    throw after all other groups have been processed, so the job ends in Failed status.

    .PARAMETER readOnly
    Dry run. Reports every addition and removal that would be made, without writing anything. Use this on the first run.

    .PARAMETER markerKeyword
    The keyword to look for in group descriptions. Defaults to EntraMemberOfSync. Change it to run two independent populations
    from the same tenant, or to use your own naming.

    .EXAMPLE
    .\Invoke-Sync.ps1 -readOnly

    .EXAMPLE
    .\Invoke-Sync.ps1

    .NOTES
    Author: Jos Lieben / JSolve B.V.
    Website: https://www.jsolve.nl
    Free to use and modify, but please keep this header intact. No warranty, use at your own risk.

    Required Graph application permissions for the Managed Identity:
    - GroupMember.ReadWrite.All

    Use https://lieben.nu/tools/SPNRoleMgr to easily assign above permission to the managed identity of your automation account
#>

[CmdletBinding()]
Param(
    [switch]$readOnly,
    [string]$markerKeyword = "EntraMemberOfSync"
)

$ErrorActionPreference = 'Stop'

#object types this runbook manages. Anything else in a source group (nested groups, service principals) is ignored
$supportedMemberTypes = @('#microsoft.graph.user', '#microsoft.graph.device')

#maximum number of members Graph accepts in a single members@odata.bind PATCH
$addBatchSize = 20

function Get-GraphToken {
    #acquires a Graph token using the Managed Identity, without any module dependencies
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        #Azure Automation / App Service style managed identity endpoint
        $uri = "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com/&api-version=2019-08-01"
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER; "Metadata" = "True" }
    } else {
        #Azure VM / VMSS IMDS endpoint
        $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://graph.microsoft.com/"
        $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ "Metadata" = "true" }
    }
    if (-not $response.access_token) {
        Throw "Failed to acquire a Graph token using the Managed Identity"
    }
    return $response.access_token
}

function Get-GraphStatusCode {
    #safely extracts the HTTP status code from an error record, returns $Null if there wasn't one
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $statusCode = $Null
    try { $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
    return $statusCode
}

function Invoke-GraphRequest {
    #thin wrapper around Invoke-RestMethod with auth header and basic throttling retry
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = "GET",
        [object]$Body = $Null,
        [hashtable]$AdditionalHeaders = @{}
    )

    $attempts = 0
    while ($true) {
        $attempts++
        try {
            $headers = @{ "Authorization" = "Bearer $($script:graphToken)" }
            foreach ($key in $AdditionalHeaders.Keys) {
                $headers[$key] = $AdditionalHeaders[$key]
            }
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $headers
                ContentType = "application/json; charset=utf-8"
            }
            if ($Body) {
                $params["Body"] = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 15))
            }
            return Invoke-RestMethod @params
        } catch {
            $statusCode = Get-GraphStatusCode -ErrorRecord $_
            if ($statusCode -in @(429, 503, 504) -and $attempts -lt 5) {
                $retryAfter = 10
                try { $retryAfter = [int]($_.Exception.Response.Headers.GetValues("Retry-After") | Select-Object -First 1) } catch {}
                #Write-Warning, not Write-Output: this function's return value travels the output stream, anything written to it here would end up in the caller's result
                Write-Warning "Graph returned $statusCode, retrying in $retryAfter seconds (attempt $attempts)..."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            Throw $_
        }
    }
}

function Get-GraphCollection {
    #retrieves all pages of a Graph collection
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$AdditionalHeaders = @{}
    )

    $items = @()
    $nextLink = $Uri
    while ($nextLink) {
        #headers have to travel along to every page, the nextLink does not carry them
        $response = Invoke-GraphRequest -Uri $nextLink -AdditionalHeaders $AdditionalHeaders
        #a page without a value collection is a failed read, never "no members"
        if ($Null -eq $response -or $response.PSObject.Properties.Name -notcontains 'value') {
            Throw "Unexpected Graph response for $nextLink, no value collection returned"
        }
        if ($response.value) {
            $items += $response.value
        }
        $nextLink = $response.'@odata.nextLink'
    }
    return $items
}

function Get-SyncMemberIds {
    #returns the object id's of all user and device members of a group, either direct or transitive
    param(
        [Parameter(Mandatory = $true)][string]$groupId,
        [switch]$transitive
    )

    $segment = if ($transitive) { "transitiveMembers" } else { "members" }
    $members = Get-GraphCollection -Uri ("https://graph.microsoft.com/v1.0/groups/$groupId/$segment" + '?$select=id&$top=999')
    return @($members | Where-Object { $_.'@odata.type' -in $supportedMemberTypes } | Select-Object -ExpandProperty id)
}

function Get-MarkedGroups {
    #retrieves all groups whose description contains the marker keyword. Falls back to a full enumeration if $search is unavailable
    #this function returns groups over the output stream, so it must stay silent on that stream. Progress is logged by the caller
    param([Parameter(Mandatory = $true)][string]$keyword)

    $properties = 'id,displayName,description,groupTypes,onPremisesSyncEnabled'
    try {
        $searchValue = [uri]::EscapeDataString("`"description:$keyword`"")
        $searchUri = "https://graph.microsoft.com/v1.0/groups?`$search=$searchValue&`$select=$properties&`$count=true&`$top=100"
        return @(Get-GraphCollection -Uri $searchUri -AdditionalHeaders @{ "ConsistencyLevel" = "eventual" })
    } catch {
        Write-Warning "Could not search on description ($($_.Exception.Message)), falling back to enumerating all groups in the tenant"
        return @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/groups?`$select=$properties&`$top=100")
    }
}

function Get-MarkerSources {
    #parses all markers in a description and returns the source groups they point at, each with its own lookup mode
    param(
        [string]$description,
        [Parameter(Mandatory = $true)][string]$pattern
    )

    $sources = @()
    if ([string]::IsNullOrWhiteSpace($description)) {
        return $sources
    }
    foreach ($match in [regex]::Matches($description, $pattern)) {
        $transitive = ($match.Groups[1].Value -eq 'transitive')
        foreach ($guid in ($match.Groups[2].Value -split ',')) {
            $guid = $guid.Trim()
            $parsed = [guid]::Empty
            if (-not [guid]::TryParse($guid, [ref]$parsed)) {
                continue
            }
            #the same source listed twice in the same mode is pointless, in two modes it is not (transitive wins by union anyway)
            if ($sources | Where-Object { $_.id -eq $parsed.Guid -and $_.transitive -eq $transitive }) {
                continue
            }
            $sources += [PSCustomObject]@{
                id         = $parsed.Guid
                transitive = $transitive
            }
        }
    }
    return $sources
}

function Add-GroupMembers {
    #adds members in batches of 20 through members@odata.bind, falling back to individual calls if a batch is rejected
    #returns succeeded and failed counts, so all logging in here goes to the warning stream to keep the output stream clean
    param(
        [Parameter(Mandatory = $true)][string]$groupId,
        [Parameter(Mandatory = $true)][string[]]$memberIds
    )

    $added = 0
    $failed = 0
    for ($i = 0; $i -lt $memberIds.Count; $i += $addBatchSize) {
        $chunk = @($memberIds[$i..([Math]::Min($i + $addBatchSize - 1, $memberIds.Count - 1))])
        $body = @{
            'members@odata.bind' = @($chunk | ForEach-Object { "https://graph.microsoft.com/v1.0/directoryObjects/$_" })
        }
        try {
            $Null = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/groups/$groupId" -Method PATCH -Body $body
            $added += $chunk.Count
        } catch {
            #a single bad or already existing member fails the entire batch, so retry this chunk one by one
            Write-Warning "Batch add of $($chunk.Count) member(s) failed ($($_.Exception.Message)), retrying individually"
            foreach ($memberId in $chunk) {
                try {
                    $refBody = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$memberId" }
                    $Null = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" -Method POST -Body $refBody
                    $added++
                } catch {
                    #a 400 is only harmless when Graph says the reference already exists, other 400's (e.g. mail enabled groups) are real failures
                    if ((Get-GraphStatusCode -ErrorRecord $_) -eq 400 -and "$($_.ErrorDetails.Message)" -match 'already exist') {
                        Write-Warning "  $memberId was already a member, skipping"
                    } else {
                        Write-Warning "  failed to add $memberId : $($_.Exception.Message)"
                        $failed++
                    }
                }
            }
        }
    }
    return [PSCustomObject]@{ succeeded = $added; failed = $failed }
}

function Remove-GroupMembers {
    #removes members one by one, a 404 means someone else already removed them
    #returns succeeded and failed counts, so all logging in here goes to the warning stream to keep the output stream clean
    param(
        [Parameter(Mandatory = $true)][string]$groupId,
        [Parameter(Mandatory = $true)][string[]]$memberIds
    )

    $removed = 0
    $failed = 0
    foreach ($memberId in $memberIds) {
        try {
            $Null = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/$memberId/`$ref" -Method DELETE
            $removed++
        } catch {
            if ((Get-GraphStatusCode -ErrorRecord $_) -eq 404) {
                Write-Warning "  $memberId was no longer a member, skipping"
            } else {
                Write-Warning "  failed to remove $memberId : $($_.Exception.Message)"
                $failed++
            }
        }
    }
    return [PSCustomObject]@{ succeeded = $removed; failed = $failed }
}

function Add-GroupIssue {
    #records a problem with a target group, the runbook throws at the end when any were recorded
    param(
        [Parameter(Mandatory = $true)]$group,
        [Parameter(Mandatory = $true)][string]$message
    )

    Write-Warning "'$($group.displayName)' ($($group.id)): $message"
    $key = "'$($group.displayName)' ($($group.id))"
    if (-not $script:groupIssues.Contains($key)) {
        $script:groupIssues[$key] = [System.Collections.Generic.List[string]]::new()
    }
    $script:groupIssues[$key].Add($message)
}

########## main ##########

$script:graphToken = Get-GraphToken

$guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F])'
#the lookahead rejects a list that continues with something unparseable, so "guidA,typo,guidC" is not read as just guidA
$markerRegex = "(?i)$([regex]::Escape($markerKeyword))\s*:\s*(?:(direct|transitive)\s*:\s*)?($guidPattern(?:\s*,\s*$guidPattern)*)(?!\s*(?:,|$guidPattern))"
#every keyword followed by a colon is meant as a marker, any of them the marker regex cannot read is broken
$keywordRegex = "(?i)$([regex]::Escape($markerKeyword))\s*:"

Write-Output "Starting EntraMemberOfSync, looking for groups with '$markerKeyword' in their description ($(if($readOnly){"read only mode, nothing will be modified"}else{"live mode"}))"

$candidates = @(Get-MarkedGroups -keyword $markerKeyword)
Write-Output "Retrieved $($candidates.Count) candidate group(s) to examine"

$stats = @{
    processed        = 0
    skippedNoMarker  = 0
    skippedDynamic   = 0
    skippedOnPremise = 0
    membersAdded     = 0
    membersRemoved   = 0
}
$groupIssues = [ordered]@{}

foreach ($group in $candidates) {
    try {
        #the search index only gives us candidates, the regex decides
        $sources = @(Get-MarkerSources -description $group.description -pattern $markerRegex)
        $brokenMarkers = [regex]::Matches("$($group.description)", $keywordRegex).Count - [regex]::Matches("$($group.description)", $markerRegex).Count
        if ($sources.Count -eq 0 -and $brokenMarkers -eq 0) {
            $stats.skippedNoMarker++
            continue
        }

        if ($group.groupTypes -contains 'DynamicMembership') {
            Add-GroupIssue -group $group -message "skipped, this group still has a dynamic membership rule, convert it to assigned membership first"
            $stats.skippedDynamic++
            continue
        }

        if ($group.onPremisesSyncEnabled -eq $true) {
            Add-GroupIssue -group $group -message "skipped, membership of this group is managed by on premises Active Directory"
            $stats.skippedOnPremise++
            continue
        }

        #the source groups behind a broken marker are unknown, so removals are blocked further down
        if ($brokenMarkers -gt 0) {
            Add-GroupIssue -group $group -message "$brokenMarkers marker(s) in the description could not be parsed, check the syntax and source group id's"
        }

        #a group cannot be its own source
        if ($sources | Where-Object { $_.id -eq $group.id }) {
            Add-GroupIssue -group $group -message "lists itself as a source group, ignoring that entry"
            $sources = @($sources | Where-Object { $_.id -ne $group.id })
        }
        if ($sources.Count -eq 0) {
            $stats.skippedNoMarker++
            continue
        }

        $stats.processed++

        #build the desired membership as the union of all source groups
        $desired = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $sourcesOk = 0
        $sourcesFailed = 0
        foreach ($source in $sources) {
            try {
                foreach ($memberId in (Get-SyncMemberIds -groupId $source.id -transitive:$source.transitive)) {
                    $Null = $desired.Add($memberId)
                }
                $sourcesOk++
            } catch {
                #do not let one unreachable source group cause a mass removal further down
                Add-GroupIssue -group $group -message "could not read source group $($source.id): $($_.Exception.Message)"
                $sourcesFailed++
            }
        }

        $current = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($memberId in (Get-SyncMemberIds -groupId $group.id)) {
            $Null = $current.Add($memberId)
        }

        $toAdd = @($desired | Where-Object { -not $current.Contains($_) })
        $toRemove = @($current | Where-Object { -not $desired.Contains($_) })

        #removing is only safe when every source group is known and was read
        if ($toRemove.Count -gt 0 -and ($sourcesFailed -gt 0 -or $brokenMarkers -gt 0)) {
            Write-Warning "Not removing $($toRemove.Count) member(s) from '$($group.displayName)' this run, not every source group could be read"
            $toRemove = @()
        }

        #emptying a populated group needs a second read confirming every source really is empty
        if ($toRemove.Count -gt 0 -and $desired.Count -eq 0) {
            $confirmedEmpty = $true
            foreach ($source in $sources) {
                try {
                    if (@(Get-SyncMemberIds -groupId $source.id -transitive:$source.transitive).Count -gt 0) {
                        $confirmedEmpty = $false
                    }
                } catch {
                    $confirmedEmpty = $false
                }
            }
            if ($confirmedEmpty) {
                Write-Warning "All source groups of '$($group.displayName)' are confirmed empty by a second read, all $($toRemove.Count) synced member(s) will be removed"
            } else {
                Add-GroupIssue -group $group -message "source groups read as empty but a second read could not confirm that, not removing $($toRemove.Count) member(s) this run"
                $toRemove = @()
            }
        }

        $mode = if ($sources | Where-Object { $_.transitive }) { if ($sources | Where-Object { -not $_.transitive }) { "mixed" } else { "transitive" } } else { "direct" }

        if ($readOnly) {
            Write-Output "[readOnly] '$($group.displayName)' ($($group.id)) [$mode]: would add $($toAdd.Count) and remove $($toRemove.Count) member(s), sources: $sourcesOk ok / $sourcesFailed failed"
            foreach ($memberId in $toAdd) { Write-Output "  + $memberId" }
            foreach ($memberId in $toRemove) { Write-Output "  - $memberId" }
            continue
        }

        $added = 0
        $removed = 0
        if ($toAdd.Count -gt 0) {
            $result = Add-GroupMembers -groupId $group.id -memberIds $toAdd
            $added = $result.succeeded
            $stats.membersAdded += $added
            if ($result.failed -gt 0) {
                Add-GroupIssue -group $group -message "$($result.failed) of $($toAdd.Count) member(s) could not be added"
            }
        }
        if ($toRemove.Count -gt 0) {
            $result = Remove-GroupMembers -groupId $group.id -memberIds $toRemove
            $removed = $result.succeeded
            $stats.membersRemoved += $removed
            if ($result.failed -gt 0) {
                Add-GroupIssue -group $group -message "$($result.failed) of $($toRemove.Count) member(s) could not be removed"
            }
        }

        Write-Output "Synced '$($group.displayName)' ($($group.id)) [$mode]: +$added added, -$removed removed, sources: $sourcesOk ok / $sourcesFailed failed"
    } catch {
        Add-GroupIssue -group $group -message "failed to process: $($_.Exception.Message)"
    }
}

Write-Output ""
Write-Output "Summary: processed $($stats.processed) target group(s), added $($stats.membersAdded) and removed $($stats.membersRemoved) member(s)"
Write-Output "Skipped: $($stats.skippedNoMarker) without a valid marker, $($stats.skippedDynamic) with a dynamic membership rule, $($stats.skippedOnPremise) synced from on premises AD"

if ($groupIssues.Count -gt 0) {
    Write-Output ""
    Write-Output "$($groupIssues.Count) group(s) need attention:"
    foreach ($key in $groupIssues.Keys) {
        foreach ($message in $groupIssues[$key]) {
            Write-Output "  $($key): $message"
        }
    }
    Throw "EntraMemberOfSync completed with issues in $($groupIssues.Count) group(s): $(@($groupIssues.Keys) -join ', ')"
}

Write-Output "Job completed"
