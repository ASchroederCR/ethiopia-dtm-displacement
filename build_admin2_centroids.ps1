<#
  build_admin2_centroids.ps1
  ------------------------------------------------------------------
  One-time helper: downloads the OCHA Common Operational Dataset (COD-AB)
  Admin 2 boundaries for Ethiopia from HDX, computes an area-weighted
  centroid (lon/lat) for every Admin 2 "zone", and writes a small pcode ->
  centroid lookup used by the site-level flow map.

  The COD file ships with empty center_lat/center_lon fields, so centroids
  are derived here from the polygon geometry (shoelace formula).

  Source: https://data.humdata.org/dataset/cod-ab-eth  (eth_admin2.geojson)
  Output: data/eth_admin2_centroids.json
#>
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir=Join-Path $root 'data'; if(-not(Test-Path $dataDir)){New-Item -ItemType Directory $dataDir|Out-Null}
$tmp=Join-Path $env:TEMP ('eth_cod_'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory $tmp|Out-Null
$h=@{ 'User-Agent'='claude-dtm' }

$zipUrl='https://data.humdata.org/dataset/cb58fa1f-687d-4cac-81a7-655ab1efb2d0/resource/0518da1b-42d1-4624-ad64-768cb69f9d40/download/eth_admin_boundaries.geojson.zip'
$zip=Join-Path $tmp 'geo.zip'
Write-Host 'Downloading OCHA COD-AB Admin2 boundaries from HDX ...'
Invoke-WebRequest $zipUrl -OutFile $zip -Headers $h -UseBasicParsing
Expand-Archive $zip -DestinationPath $tmp -Force
$gj=Get-Content (Join-Path $tmp 'eth_admin2.geojson') -Raw | ConvertFrom-Json
Write-Host ("  {0} admin2 features" -f $gj.features.Count)

# --- area-weighted centroid of a single exterior ring (shoelace) --
function Ring-Centroid($ring){
  $A=0.0;$cx=0.0;$cy=0.0;$n=$ring.Count
  for($i=0;$i -lt $n-1;$i++){
    $x0=$ring[$i][0];   $y0=$ring[$i][1]
    $x1=$ring[$i+1][0]; $y1=$ring[$i+1][1]
    $cross=($x0*$y1)-($x1*$y0)
    $A+=$cross; $cx+=($x0+$x1)*$cross; $cy+=($y0+$y1)*$cross
  }
  $A*=0.5
  if([math]::Abs($A) -lt 1e-12){  # degenerate: fall back to vertex mean
    $mx=($ring|ForEach-Object{$_[0]}|Measure-Object -Average).Average
    $my=($ring|ForEach-Object{$_[1]}|Measure-Object -Average).Average
    return @{x=$mx;y=$my;area=0.0}
  }
  return @{ x=$cx/(6*$A); y=$cy/(6*$A); area=[math]::Abs($A) }
}
# --- centroid of Polygon / MultiPolygon (exterior rings, area-weighted) --
function Geom-Centroid($geom){
  $parts=@()
  if($geom.type -eq 'Polygon'){ $parts=,($geom.coordinates[0]) }
  elseif($geom.type -eq 'MultiPolygon'){ foreach($poly in $geom.coordinates){ $parts+=,($poly[0]) } }
  else { return $null }
  $sumA=0.0;$sx=0.0;$sy=0.0
  foreach($ring in $parts){ $c=Ring-Centroid $ring; $w=[math]::Max($c.area,1e-9); $sumA+=$w; $sx+=$c.x*$w; $sy+=$c.y*$w }
  if($sumA -le 0){ return $null }
  return @{ lon=[math]::Round($sx/$sumA,4); lat=[math]::Round($sy/$sumA,4) }
}

$cent=@{}
foreach($f in $gj.features){
  $p=$f.properties; $pc=$p.adm2_pcode; if(-not $pc){continue}
  $c=Geom-Centroid $f.geometry; if(-not $c){continue}
  $cent[$pc]=[ordered]@{ pcode=$pc; name=$p.adm2_name; adm1pcode=$p.adm1_pcode; adm1name=$p.adm1_name; lat=$c.lat; lon=$c.lon }
}
Write-Host ("  computed centroids for {0} zones" -f $cent.Count)

# --- fill DTM zones absent from this COD vintage --------------------
# ET1600 (DTM codes all of Sidama as one zone; COD splits into ET1601-1605)
$sid=$cent.Values | Where-Object { $_.adm1pcode -eq 'ET16' }
if($sid -and -not $cent.ContainsKey('ET1600')){
  $cent['ET1600']=[ordered]@{ pcode='ET1600'; name='Sidama'; adm1pcode='ET16'; adm1name='Sidama';
    lat=[math]::Round((($sid.lat)|Measure-Object -Average).Average,4);
    lon=[math]::Round((($sid.lon)|Measure-Object -Average).Average,4); note='derived: mean of Sidama zones' }
}
# ET0105 Western (Western Tigray) - absent from this COD vintage; place manually
if(-not $cent.ContainsKey('ET0105')){
  $cent['ET0105']=[ordered]@{ pcode='ET0105'; name='Western'; adm1pcode='ET01'; adm1name='Tigray';
    lat=13.7; lon=36.75; note='manual: Western Tigray (not in COD vintage)' }
}

$cent.Values | Sort-Object pcode | ConvertTo-Json -Depth 4 |
  Out-File (Join-Path $dataDir 'eth_admin2_centroids.json') -Encoding utf8
Write-Host ("Wrote data/eth_admin2_centroids.json ({0} zones)" -f $cent.Count)
Remove-Item $tmp -Recurse -Force
