Function set-M365PermissionsConfig{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -maxThreads: the maximum amount of threads to use for parallel processing, by default 5. Ensure you've read my blog before increasing this.
        -outputFolder: the path to the folder where you want to save permissions. By default it'll create the file in AppData\Roaming\LiebenConsultancy\M365Permissions
        -outputFormat: XLSX or CSV
        -Verbose: if set, verbose output will be shown everywhere (=very chatty)
        -includeCurrentUser: add entries for the user performing the audit (as this user will have all access, it'll clutter the report)
        -defaultTimeoutMinutes: the default timeout in minutes for all parallelized jobs, by default 120 minutes
        -maxJobRetries: the amount of times a job will be retried if it fails, by default 3
    #>        
    Param(
        [Int]$maxThreads,
        [String]$outputFolder,
        [ValidateSet('XLSX','CSV')]
        [String]$outputFormat,
        [Boolean]$Verbose,
        [Boolean]$includeCurrentUser,
        [Int]$defaultTimeoutMinutes,
        [Int]$maxJobRetries,
        [Boolean]$autoConnect,
        [String]$LCClientId,
        [String]$LCTenantId,
        [ValidateSet('Delegated','ServicePrincipal')]
        [String]$authMode
    )

    $defaultConfig = @{
        "maxThreads" = [Int]5
        "outputFolder" = [String]"CURRENTFOLDER"
        "outputFormat" = [String]"XLSX"
        "Verbose" = [Boolean]$false
        "includeCurrentUser" = [Boolean]$false
        "defaultTimeoutMinutes" = [Int]120
        "maxJobRetries" = [Int]3
        "autoConnect" = [Boolean]$false
        "LCClientId" = [String]$Null
        "LCTenantId" = [String]$Null
        "authMode" = [String]"Delegated"
    }

    $configLocation = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\M365Permissions.conf"
    if(!(Test-Path $configLocation)){
        $preferredConfig = @{}
    }else{
        $preferredConfig = Get-Content -Path $configLocation | ConvertFrom-Json -AsHashtable
    }

    #ensure verbose preferences are set in all child processes
    if($True -eq $Verbose -or $True -eq $preferredConfig.Verbose){
        $global:VerbosePreference = "Continue"
    }else{
        $global:VerbosePreference = "SilentlyContinue"
    }

    #override cached config with any passed in parameters (and only those we explicitly defined in the default config options)
    $updateConfigFile = $false
    foreach($passedParam in $PSBoundParameters.GetEnumerator()){
        if($defaultConfig.ContainsKey($passedParam.Key)){
            $preferredConfig.$($passedParam.Key) = $passedParam.Value
            Write-Verbose "Persisted $($passedParam.Key) to $($passedParam.Value) for your account"
            $updateConfigFile = $true
        }
    }

    #set global vars based on customization and/or defaults
    foreach($configurable in $defaultConfig.GetEnumerator()){
        if($Null -ne $preferredConfig.$($configurable.Name)){
            Write-Verbose "Loaded $($configurable.Key) ($($preferredConfig.$($configurable.Name))) from persisted settings in $configLocation"
            $global:octo.$($configurable.Name) = $preferredConfig.$($configurable.Name)
        }else{
            $global:octo.$($configurable.Name) = $configurable.Value
        }
    }

    #update config file if needed
    if($updateConfigFile){
        Set-Content -Path $configLocation -Value $($preferredConfig | ConvertTo-Json) -Force
    }

    #override output folder with actual path
    if($global:octo.outputFolder -eq "CURRENTFOLDER"){
        $global:octo.outputFolder = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy"
    }

    #configure a temp folder specific for this run
    $global:octo.outputTempFolder = Join-Path -Path $global:octo.outputFolder -ChildPath "Temp$((Get-Date).ToString("yyyyMMddHHmm"))"

    #run verbose log to file if verbose is on
    if($global:VerbosePreference -eq "Continue"){
        try{Start-Transcript -Path $(Join-Path -Path $global:octo.outputTempFolder -ChildPath "M365PermissionsVerbose.log") -Force -Confirm:$False}catch{
            Write-Verbose "Transcript already running"
        }
    }
}