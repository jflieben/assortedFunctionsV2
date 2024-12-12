Function set-M365PermissionsConfig{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -maxThreads: the maximum amount of threads to use for parallel processing, by default 5. Ensure you've read my blog before increasing this.
        -outputFolder: the path to the folder where you want to save permissions. By default it'll create the file in AppData\Roaming\LiebenConsultancy\M365Permissions
    #>        
    Param(
        [Int]$maxThreads,
        [String]$outputFolder
    )

    $defaultConfig = @{
        "maxThreads" = [Int]5
        "outputFolder" = [String]"CURRENTFOLDER"
    }

    $configLocation = Join-Path -Path $env:appdata -ChildPath "LiebenConsultancy\M365Permissions.conf"
    if(!(Test-Path $configLocation)){
        $preferredConfig = @{}
    }else{
        $preferredConfig = Get-Content -Path $configLocation | ConvertFrom-Json
    }

    #override cached config with any passed in parameters (and only those we explicitly defined in the default config options)
    $updateConfigFile = $false
    foreach($passedParam in $PSBoundParameters.GetEnumerator()){
        if($defaultConfig.ContainsKey($passedParam.Key)){
            $preferredConfig.$($passedParam.Key) = $passedParam.Value
            $updateConfigFile = $true
        }
    }

    #set global vars based on customization and/or defaults
    foreach($configurable in $defaultConfig.GetEnumerator()){
        if($preferredConfig.$($configurable.Key)){
            $global:octo.$($configurable.Key) = $configurable.Value
        }else{
            $global:octo.$($configurable.Key) = $configurable.Value
        }
    }

    if($updateConfigFile){
        Set-Content -Path $configLocation -Value $($preferredConfig | ConvertTo-Json) -Force
    }
}