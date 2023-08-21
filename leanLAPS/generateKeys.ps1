## Generate key pair
$RSA = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)

$private = $rsa.ExportCspBlob(1)
Write-Host "Your private key is:"
$private = $private -join ","
Set-Clipboard $private
$private
Write-Host "It has been saved to your clipboard for your convenience"
Read-Host "Press any key to continue"


$public = $rsa.ExportCspBlob(0)
Write-Host "Your public key is:"
$public = $public -join ","
Set-Clipboard $public
$public
Write-Host "It has been saved to your clipboard for your convenience"


