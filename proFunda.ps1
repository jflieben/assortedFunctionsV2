$fundaNew = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://www.funda.nl/koop/provincie-utrecht,provincie-gelderland/beschikbaar/300000-1400000/1000+perceelopp/sorteer-datum-af/"
$start = $fundaNew.IndexOf("<script type=`"application/ld+json`">")+35
$end = $fundaNew.IndexOf("</script>",$start)
$huizen = ($fundaNew.SubString($start,$end-$start) | convertfrom-json).itemListElement

Write-Output "Checking $($huizen.count) huizen..."

function get-adressMeta(){
    Param($adres)
    $adr = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://geodata.nationaalgeoregister.nl/locatieserver/v3/suggest?&rows=5&fq=type:adres&q=$adres"
    if(!$adr.response.docs.id){
        Throw "Nothing found!"   
    }else{
        $id = $adr.response.docs.id
        Write-Verbose "Found ID scoring $($adr.response.docs.score)% $($adr.response.docs.id)"
    }
    $retObj = @{}

    $baseAdrData = (Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://geodata.nationaalgeoregister.nl/locatieserver/v3/lookup?id=$id").response.docs
    $i = [Math]::Round($baseAdrData.centroide_rd.Split(" ")[0].Split("(")[1])
    $j = 650000-([Math]::Round($baseAdrData.centroide_rd.Split(" ")[1].Split(")")[0]))
    $hemelHelderheid = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://data.rivm.nl/geo/dmg/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo&LAYERS=dmg:licht_20150315_gm_hhnachtonbew&QUERY_LAYERS=dmg:licht_20150315_gm_hhnachtonbew&BBOX=0,300000,300000,650000&WIDTH=300000&HEIGHT=350000&FEATURE_COUNT=1&INFO_FORMAT=text/plain&CRS=EPSG:28992&i=$i&j=$j"
    $retObj.hemelHelderheid = $hemelHelderheid.SubString($hemelHelderheid.IndexOf("GRAY_INDEX")+13,4)
    Write-Verbose "Helderheid: $($retObj.hemelHelderheid)"
    $schaduwRijkeBomenOppProcent = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://data.rivm.nl/geo/alo/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo&LAYERS=20200629_gm_bomenkaart_cjp_500m_v3&QUERY_LAYERS=20200629_gm_bomenkaart_cjp_500m_v3&BBOX=0,300000,300000,650000&WIDTH=300000&HEIGHT=350000&FEATURE_COUNT=1&INFO_FORMAT=text/plain&CRS=EPSG:28992&i=$i&j=$j"
    $retObj.schaduwRijkeBomenOppProcent = $schaduwRijkeBomenOppProcent.SubString($schaduwRijkeBomenOppProcent.IndexOf("GRAY_INDEX")+13,4)
    Write-Verbose "Percentage opp bedekt door boomschaduw: $($retObj.schaduwRijkeBomenOppProcent)%"
    $groenBinnen500m = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://data.rivm.nl/geo/alo/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo&LAYERS=20200629_gm_groenkaart_cjp_500m_v3&QUERY_LAYERS=20200629_gm_groenkaart_cjp_500m_v3&BBOX=0,300000,300000,650000&WIDTH=300000&HEIGHT=350000&FEATURE_COUNT=1&INFO_FORMAT=text/plain&CRS=EPSG:28992&i=$i&j=$j"
    $retObj.groenBinnen500m = $groenBinnen500m.SubString($groenBinnen500m.IndexOf("GRAY_INDEX")+13,4)
    Write-Verbose "Groenj binnen 500m: $($retObj.groenBinnen500m)%"
    $geluidInDb = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://data.rivm.nl/geo/alo/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo&LAYERS=rivm_20210201_g_geluidkaart_lden_alle_bronnen_v3&QUERY_LAYERS=rivm_20210201_g_geluidkaart_lden_alle_bronnen_v3&BBOX=0,300000,300000,650000&WIDTH=300000&HEIGHT=350000&FEATURE_COUNT=1&INFO_FORMAT=application/json&CRS=EPSG:28992&i=$i&j=$j"
    $retObj.geluidInDb = $geluidInDb.features[0].properties.GRAY_INDEX
    Write-Verbose "Geluidsniveau: $($retObj.geluidInDb) dB"
    $stikstof = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://data.rivm.nl/geo/alo/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo&LAYERS=rivm_nsl_20220101_gm_NO22020_Int&QUERY_LAYERS=rivm_nsl_20220101_gm_NO22020_Int&BBOX=0,300000,300000,650000&WIDTH=300000&HEIGHT=350000&FEATURE_COUNT=1&INFO_FORMAT=application/json&CRS=EPSG:28992&i=$i&j=$j"
    $retObj.stikstof = $stikstof.features[0].properties.GRAY_INDEX
    Write-Verbose "Stikstof: $($retObj.stikstof) μg NO2 / m3"
    $fijnstof = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://data.rivm.nl/geo/alo/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo&LAYERS=rivm_nsl_20220101_gm_PM252020_Int&QUERY_LAYERS=rivm_nsl_20220101_gm_PM252020_Int&BBOX=0,300000,300000,650000&WIDTH=300000&HEIGHT=350000&FEATURE_COUNT=1&INFO_FORMAT=application/json&CRS=EPSG:28992&i=$i&j=$j"
    $retObj.fijnstof = $fijnstof.features[0].properties.GRAY_INDEX
    Write-Verbose "Fijnstof: $($retObj.fijnstof) μg PM2,5 / m3"
    $extAdrData = Invoke-RestMethod -Method GET -UseBasicParsing -Uri "https://geodata.nationaalgeoregister.nl/wijkenbuurten2020/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo&LAYERS=cbs_buurten_2020&QUERY_LAYERS=cbs_buurten_2020&BBOX=0,300000,300000,650000&WIDTH=300000&HEIGHT=350000&FEATURE_COUNT=1&INFO_FORMAT=text/plain&CRS=EPSG:28992&i=$i&j=$j"
    $retObj.treinstationAfstand = ($extAdrData.SubString($extAdrData.IndexOf("treinstation_gemiddelde_afstand_in_km")+40,4)).Trim()
    Write-Verbose "Afstand tot treinstation: $($retObj.treinstationAfstand) km"
    return $retObj
}

foreach($huis in $huizen){
    $stad = $huis.url.Split("/")[-3].Split("-")[0]
    $straat = $huis.url.Split("/")[-2]
    $straat = $straat.Split("-")[2..$($straat.Split("-").Count)] -Join " "
    try{
        $huisMeta = $Null
        $huisMeta = get-adressMeta -adres "$straat, $stad"
    }catch{
        continue
    }

    if([Int]$huisMeta.treinstationAfstand -gt 7){
        continue
    }
    if([Int]$huisMeta.groenBinnen500m -le 20){
        continue
    }
    if([Int]$huisMeta.geluidInDb -gt 52){
        continue
    }
    Write-Host "MATCH!" -ForegroundColor Green
    Write-Output $huis.url
    write-output $huisMeta | ft -HideTableHeaders
    Write-Host " "
    Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" $huis.url
}

