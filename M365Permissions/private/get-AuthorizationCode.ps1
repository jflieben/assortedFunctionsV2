function get-AuthorizationCode{
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        

    $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 1985)
    $tcpListener.Start()
    Write-Host "Waiting for login using your default browser..."

    $targetUrl = "https://login.microsoftonline.com/common/oauth2/authorize?client_id=$($global:LCClientId)&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1985&response_mode=query&resource=https://graph.microsoft.com&prompt=admin_consent"

    try{
        Start-Process $targetUrl
    }catch{
        Write-Host "Failed to open your browser, please go to $targetUrl"
    }

    $client = $tcpListener.AcceptTcpClient()
    Start-Sleep -s 1
    $stream = $client.GetStream();$reader = New-Object System.IO.StreamReader($stream);$writer = New-Object System.IO.StreamWriter($stream);$requestLine = $reader.ReadLine()
    Start-Sleep -s 1
    if($requestLine.Split("?")[1].StartsWith("code")){
        Write-Host "Authorization code received, retrieving access token..."
        $code = $requestLine.Split("?")[1].Split("=")[1].Split("&")[0]
    }else{
        Throw "Failed to receive auth code, please try again"
    }
        
    #thank the user for authenticating
    Start-Sleep -s 1
    $writer.Write("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=UTF-8`r`n`r`n<html><head><title>M365 Permissions by Lieben Consultancy</title></head><body><p>Logged in, thank you! You may now close this window, the scan will continue in your PowerShell terminal :)</p></body></html>");$writer.Flush()
    Start-Sleep -s 1
    $writer.Close();$reader.Close();$client.Close();$tcpListener.Stop()

    $irmSplat = @{
        Uri    = "https://login.microsoftonline.com/organizations/oauth2/v2.0/token"
        Method = 'Post'
        Body = @{
            scope                 = "offline_access https://graph.microsoft.com/.default"
            code                  = $code
            client_id             = $global:LCClientId
            grant_type            = 'authorization_code'
            redirect_uri          = "http://localhost:1985"
        }
    }

    #retrieve the refresh token
    $authResponse = (Invoke-RestMethod @irmSplat)
    $global:LCRefreshToken = $authResponse.refresh_token
}