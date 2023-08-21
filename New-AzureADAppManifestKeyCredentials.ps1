Param(
    $subject
)

$cert=New-SelfSignedCertificate -Subject "CN=$subject" -CertStoreLocation "Cert:\CurrentUser\My"  -KeyExportPolicy Exportable -KeySpec Signature -HashAlgorithm "SHA256" -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider"
$bin = $cert.RawData
$base64Value = [System.Convert]::ToBase64String($bin)
$bin = $cert.GetCertHash()
$base64Thumbprint = [System.Convert]::ToBase64String($bin)
$keyid = [System.Guid]::NewGuid().ToString()
$jsonObj = @{customKeyIdentifier=$base64Thumbprint;keyId=$keyid;type="AsymmetricX509Cert";usage="Verify";value=$base64Value}
ConvertTo-Json @($jsonObj)