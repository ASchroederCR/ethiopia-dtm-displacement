<#
  extract_dtm_ethiopia.ps1
  ------------------------------------------------------------------
  Extracts IOM DTM displacement-site data for Ethiopia (2020 - present)
  from the DTM API v3, then builds year-end origin->destination (Admin1)
  IDP matrices and writes them to /data for the visualisations.

  API:   https://dtmapi.iom.int/v3/displacement/admin2
  Auth:  Ocp-Apim-Subscription-Key header (key read from DTM_Primary_Key.txt)

  Analytical choices (confirmed with user):
    * Operation scope : "Countrywide monitoring" only (national coverage,
                        avoids double-counting the overlapping Tigray-crisis op)
    * Yearly value    : year-end snapshot = the latest reporting round in each
                        calendar year (stock, not summed across rounds)
    * O-D level       : Admin1 origin -> Admin1 current location
    * Metric          : numPresentIdpInd (present IDP individuals)
#>

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

# ---- credentials -------------------------------------------------
$key = (Get-Content (Join-Path $root 'DTM_Primary_Key.txt') -Raw).Trim()
$headers = @{ 'Ocp-Apim-Subscription-Key' = $key; 'User-Agent' = 'DTMClient/2.0' }

# ---- 1. extract --------------------------------------------------
$url = 'https://dtmapi.iom.int/v3/displacement/admin2' +
       '?CountryName=Ethiopia&FromReportingDate=2020-01-01&ToReportingDate=2026-07-31'
Write-Host 'Requesting DTM Admin2 data for Ethiopia 2020-2026 ...'
$resp = Invoke-RestMethod $url -Headers $headers
if (-not $resp.isSuccess) { throw "API error: $($resp.errorMessages -join '; ')" }
$raw = $resp.result
Write-Host ("  received {0} records" -f $raw.Count)

# archive the raw pull (audit trail)
$raw | ConvertTo-Json -Depth 6 | Out-File (Join-Path $dataDir 'eth_admin2_raw.json') -Encoding utf8

# ---- 2. region-name normalisation --------------------------------
# origin & destination use slightly different labels for the newer regions
$canon = @{
  'South Ethiopian'            = 'South Ethiopia'
  'South Ethiopia People'      = 'South Ethiopia'
  'South West Ethiopia'        = 'South West Ethiopia'
  'South West Ethiopia People' = 'South West Ethiopia'
}
function Get-Canon($n) {
  if ($null -eq $n) { return $null }
  $n = $n.Trim()
  if ($canon.ContainsKey($n)) { return $canon[$n] } else { return $n }
}

# ---- 3. filter to Countrywide monitoring -------------------------
$cw = $raw | Where-Object { $_.operation -eq 'Countrywide monitoring' }
Write-Host ("  countrywide-monitoring records: {0}" -f $cw.Count)

# ---- 3b. site-level tidy table (all CW rounds) -------------------
# Granular "displacement sites (Admin2) x origin (Admin1)" records, normalised.
$cw | ForEach-Object {
  [PSCustomObject]@{
    reportingDate = ([datetime]$_.reportingDate).ToString('yyyy-MM-dd')
    year          = $_.yearReportingDate
    round         = $_.roundNumber
    admin1        = Get-Canon $_.admin1Name          # current / host region
    admin1Pcode   = $_.admin1Pcode
    admin2Site    = $_.admin2Name                    # displacement site (Admin2)
    admin2Pcode   = $_.admin2Pcode
    originAdmin1  = Get-Canon $_.idpOriginAdmin1Name  # origin of displaced persons
    originPcode   = $_.idpOriginAdmin1Pcode
    idps          = $_.numPresentIdpInd
    males         = $_.numberMales
    females       = $_.numberFemales
    reason        = $_.displacementReason
  }
} | Sort-Object year, round, admin1, admin2Site |
  Export-Csv (Join-Path $dataDir 'eth_sites_long.csv') -NoTypeInformation -Encoding utf8

# ---- 4. pick the year-end round per year -------------------------
# "Year-end snapshot" = the LATEST reporting round in the calendar year that
# actually carries origin information (>= 50% of IDPs have a known origin).
# Some rounds (e.g. 2022 R30/R32) report totals with no origin breakdown and
# would otherwise yield an empty matrix.
$MIN_ORIGIN_COVERAGE = 0.5
$latestRoundByYear = @{}
$cw | Group-Object yearReportingDate | ForEach-Object {
  $yr = [int]$_.Name
  $roundStats = $_.Group | Group-Object roundNumber | ForEach-Object {
    $g = $_.Group
    $known = ($g | Where-Object { $_.idpOriginAdmin1Name -and $_.idpOriginAdmin1Name -ne 'Not available' } |
              Measure-Object numPresentIdpInd -Sum).Sum
    $tot   = ($g | Measure-Object numPresentIdpInd -Sum).Sum
    [PSCustomObject]@{
      Round    = $_.Name
      Date      = [datetime]$g[0].reportingDate
      Coverage = if ($tot) { [double]$known / [double]$tot } else { 0 }
    }
  }
  $pick = $roundStats | Where-Object { $_.Coverage -ge $MIN_ORIGIN_COVERAGE } |
          Sort-Object Date -Descending | Select-Object -First 1
  if (-not $pick) { $pick = $roundStats | Sort-Object Date -Descending | Select-Object -First 1 }
  $latestRoundByYear[$yr] = [PSCustomObject]@{
    Round = $pick.Round
    Date  = $pick.Date.ToString('yyyy-MM-dd')
  }
}

# ---- 5. aggregate origin->destination per year -------------------
$long = New-Object System.Collections.Generic.List[object]
$yearMeta = New-Object System.Collections.Generic.List[object]

foreach ($yr in ($latestRoundByYear.Keys | Sort-Object)) {
  $round = $latestRoundByYear[$yr].Round
  $snap  = $cw | Where-Object { $_.yearReportingDate -eq $yr -and $_.roundNumber -eq $round }

  $totalAll   = ($snap | Measure-Object numPresentIdpInd -Sum).Sum
  $naOrigin   = ($snap | Where-Object { (Get-Canon $_.idpOriginAdmin1Name) -eq 'Not available' } |
                 Measure-Object numPresentIdpInd -Sum).Sum
  if ($null -eq $naOrigin) { $naOrigin = 0 }

  # group by canonical origin/destination admin1, sum IDPs
  $pairs = @{}
  foreach ($rec in $snap) {
    $o = Get-Canon $rec.idpOriginAdmin1Name
    $d = Get-Canon $rec.admin1Name
    if ($o -eq 'Not available' -or [string]::IsNullOrWhiteSpace($o)) { continue }
    $v = [int]$rec.numPresentIdpInd
    $k = "$o|$d"
    if ($pairs.ContainsKey($k)) { $pairs[$k] += $v } else { $pairs[$k] = $v }
  }
  foreach ($k in $pairs.Keys) {
    $parts = $k -split '\|', 2
    $long.Add([PSCustomObject]@{
      year        = $yr
      round       = $round
      snapshotDate= $latestRoundByYear[$yr].Date
      origin      = $parts[0]
      destination = $parts[1]
      idps        = $pairs[$k]
    })
  }
  $yearMeta.Add([PSCustomObject]@{
    year=$yr; round=$round; snapshotDate=$latestRoundByYear[$yr].Date
    totalIdp=[int]$totalAll; idpUnknownOrigin=[int]$naOrigin; sites=$snap.Count
  })
  Write-Host ("  {0}: round {1} ({2})  totalIDP={3:N0}  matrix-pairs={4}" -f `
              $yr,$round,$latestRoundByYear[$yr].Date,$totalAll,$pairs.Count)
}

# ---- 6. write long CSV -------------------------------------------
$long | Sort-Object year, origin, destination |
  Export-Csv (Join-Path $dataDir 'eth_od_long.csv') -NoTypeInformation -Encoding utf8

# ---- 7. region centroids (Admin1) for the flow map ---------------
$centroids = @{
  'Addis Ababa'          = @(9.03, 38.74)
  'Afar'                 = @(11.75, 40.95)
  'Amhara'               = @(11.50, 38.20)
  'Benishangul-Gumuz'    = @(10.60, 35.30)
  'Central Ethiopia'     = @(7.70, 37.95)
  'Contested'            = @(13.60, 36.80)
  'Dire Dawa'            = @(9.60, 41.87)
  'Gambela'              = @(8.05, 34.45)
  'Harari'               = @(9.31, 42.12)
  'Oromia'               = @(8.00, 39.30)
  'Sidama'               = @(6.90, 38.48)
  'Somali'               = @(6.80, 44.30)
  'South Ethiopia'       = @(5.80, 37.10)
  'South West Ethiopia'  = @(7.05, 35.65)
  'Tigray'               = @(13.60, 39.30)
}

# ---- 8. build JSON payload for the visualisations ----------------
$destRegions   = $long.destination | Select-Object -Unique | Sort-Object
$originRegions = $long.origin       | Select-Object -Unique | Sort-Object
$allRegions    = ($destRegions + $originRegions) | Select-Object -Unique | Sort-Object

$matrices = @{}
foreach ($yr in ($latestRoundByYear.Keys | Sort-Object)) {
  $matrices["$yr"] = @($long | Where-Object year -eq $yr |
    ForEach-Object { @{ o = $_.origin; d = $_.destination; v = $_.idps } })
}

$centroidObj = @{}
foreach ($r in $allRegions) {
  if ($centroids.ContainsKey($r)) {
    $centroidObj[$r] = @{ lat = $centroids[$r][0]; lon = $centroids[$r][1] }
  } else {
    Write-Warning "No centroid defined for region '$r'"
  }
}

$payload = [ordered]@{
  meta = [ordered]@{
    country    = 'Ethiopia'
    source     = 'IOM DTM API v3 (displacement/admin2)'
    operation  = 'Countrywide monitoring'
    method     = 'Year-end snapshot (latest reporting round per year); Admin1 origin -> Admin1 current location; metric = present IDP individuals'
    generated  = (Get-Date).ToString('yyyy-MM-dd')
    years      = @($latestRoundByYear.Keys | Sort-Object)
  }
  yearMeta  = $yearMeta
  regions   = $allRegions
  origins   = $originRegions
  destinations = $destRegions
  centroids = $centroidObj
  matrices  = $matrices
}
$payload | ConvertTo-Json -Depth 8 | Out-File (Join-Path $dataDir 'eth_od_matrices.json') -Encoding utf8

# also emit a JS module the HTML visualisations load directly (works on file://,
# where fetch() is blocked by CORS). Keeps eth_data.js in sync with the pull.
$compact = $payload | ConvertTo-Json -Depth 8 -Compress
$js = @"
/* Ethiopia DTM origin-destination data - generated by extract_dtm_ethiopia.ps1.
   Loaded as a plain script (window.DTM_DATA) so the HTML visualisations work
   when opened directly from disk (file://), where fetch() is blocked by CORS. */
window.DTM_DATA = $compact;
"@
$js | Out-File (Join-Path $dataDir 'eth_data.js') -Encoding utf8

# ---- 9. site-level (Admin2) flow-map payload ---------------------
# Origin (Admin1) -> destination displacement site (Admin2), year-end snapshots.
# Requires Admin2 centroids from build_admin2_centroids.ps1.
$centFile = Join-Path $dataDir 'eth_admin2_centroids.json'
if (Test-Path $centFile) {
  $a2list = Get-Content $centFile -Raw | ConvertFrom-Json
  $a2 = @{}; foreach ($z in $a2list) {
    $a2[$z.pcode] = [ordered]@{ lat=$z.lat; lon=$z.lon; name=$z.name; a1=(Get-Canon $z.adm1name) }
  }

  $siteFlows = @{}
  $missing = New-Object System.Collections.Generic.HashSet[string]
  foreach ($yr in ($latestRoundByYear.Keys | Sort-Object)) {
    $round = $latestRoundByYear[$yr].Round
    $snap  = $cw | Where-Object { $_.yearReportingDate -eq $yr -and $_.roundNumber -eq $round }
    $agg = @{}
    foreach ($rec in $snap) {
      $o = Get-Canon $rec.idpOriginAdmin1Name
      if ($o -eq 'Not available' -or [string]::IsNullOrWhiteSpace($o)) { continue }
      $pc = $rec.admin2Pcode
      if (-not $a2.ContainsKey($pc)) { [void]$missing.Add("$pc $($rec.admin2Name)"); continue }
      $k = "$o|$pc"
      $agg[$k] = ($agg[$k] + [int]$rec.numPresentIdpInd)
    }
    $siteFlows["$yr"] = @($agg.Keys | ForEach-Object {
      $p = $_ -split '\|',2
      @{ o=$p[0]; dPc=$p[1]; v=$agg[$_] }
    })
  }
  if ($missing.Count) { Write-Warning ("Admin2 zones with no centroid (skipped): " + ($missing -join '; ')) }

  # admin1 origin centroids reuse the region centroid table from step 7
  $a1obj = @{}; foreach ($r in $centroids.Keys) { $a1obj[$r] = @{ lat=$centroids[$r][0]; lon=$centroids[$r][1] } }

  $sitePayload = [ordered]@{
    meta     = $payload.meta
    yearMeta = $yearMeta
    admin1   = $a1obj
    admin2   = $a2
    flows    = $siteFlows
  }
  $siteCompact = $sitePayload | ConvertTo-Json -Depth 8 -Compress
  $sitePayload | ConvertTo-Json -Depth 8 | Out-File (Join-Path $dataDir 'eth_sites_matrices.json') -Encoding utf8
  $sjs = "/* Site-level (Admin2) flow data - generated by extract_dtm_ethiopia.ps1. */`r`nwindow.DTM_SITES = $siteCompact;`r`n"
  $sjs | Out-File (Join-Path $dataDir 'eth_sites_data.js') -Encoding utf8
  Write-Host ("  site-level payload: {0} zones, flows for {1} years" -f $a2.Count, $siteFlows.Count)
} else {
  Write-Warning "data/eth_admin2_centroids.json not found - run build_admin2_centroids.ps1 first to enable the site-level flow map."
}

Write-Host ''
Write-Host 'Done. Outputs in /data:'
Write-Host '  eth_admin2_raw.json    (raw API pull, all records)'
Write-Host '  eth_sites_long.csv     (site-level: Admin2 site x Admin1 origin, all rounds)'
Write-Host '  eth_od_long.csv        (year-end origin-destination table)'
Write-Host '  eth_od_matrices.json   (payload for heatmaps + flow map)'
Write-Host '  eth_data.js            (same payload as window.DTM_DATA for the HTML files)'
Write-Host '  eth_sites_matrices.json / eth_sites_data.js  (Admin1->Admin2 site-level flow payload)'
