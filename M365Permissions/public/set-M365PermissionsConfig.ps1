Function set-M365PermissionsConfig{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -maxThreads: the maximum amount of threads to use for parallel processing, by default 5. Ensure you've read my blog before increasing this.
        -outputFolder: the path to the folder where you want to save permissions. By default it'll create the file in AppData\Roaming\LiebenConsultancy\M365Permissions
        -outputFormat: 
            XLSX
            CSV
    #>        
    Param(
        [Int]$maxThreads,
        [String]$outputFolder,
        [ValidateSet('XLSX','CSV')]
        [String]$outputFormat,
        [Boolean]$Verbose
    )

    $defaultConfig = @{
        "maxThreads" = [Int]5
        "outputFolder" = [String]"CURRENTFOLDER"
        "outputFormat" = [String]"XLSX"
        "Verbose" = [Boolean]$false
    }

    $configLocation = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\M365Permissions.conf"
    if(!(Test-Path $configLocation)){
        $preferredConfig = @{}
    }else{
        $preferredConfig = Get-Content -Path $configLocation | ConvertFrom-Json -AsHashtable
    }

    #ensure verbose preferences are set in all child processes
    if($Verbose -or $preferredConfig.Verbose){
        $global:VerbosePreference = "Continue"
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
        if($preferredConfig.$($configurable.Name)){
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
}