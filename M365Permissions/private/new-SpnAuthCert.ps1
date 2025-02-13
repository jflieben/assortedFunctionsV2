function new-SpnAuthCert{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>
    Param(
        [Parameter(Mandatory=$true)]$tenantId
    )
    
    $pfxPath = "$env:USERPROFILE\Desktop\$tenantId.pfx"
    $cerPath = "$env:USERPROFILE\Desktop\$tenantId.cer"
    $password = ConvertTo-SecureString -String $(-join ((33..126) | Get-Random -Count 46 | % { [char]$_ })) -Force -AsPlainText

    $cert = New-SelfSignedCertificate -Subject "CN=$tenantId" -KeyAlgorithm RSA -KeyLength 2048 `
        -CertStoreLocation "Cert:\CurrentUser\My" -NotAfter (Get-Date).AddDays(7)

    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $password
    Export-Certificate -Cert $cert -FilePath $cerPath

    Write-Host "Certificate generated successfully!"
    Write-Host "CER file: $cerPath (Import this into Entra ID)"
    Write-Host "PFX file: $pfxPath (Ensure this is imported on your automation machine)"
}