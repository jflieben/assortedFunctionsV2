Function set-M365PermissionsConfig{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
        
        Parameters:
        -maxThreads: the maximum amount of threads to use for parallel processing, by default 5. Ensure you've read my blog before increasing this.
        -outputFolder: the path to the folder where you want to save permissions. By default it'll create the file in whatever folder you're running from
    #>        
    Param(
        [Int]$maxThreads = 5,
        [String]$outputFolder = "CURRENTFOLDER"
    )
    $global:octo.maxThreads = $maxThreads
    $global:octo.outputFolder = $outputFolder
}