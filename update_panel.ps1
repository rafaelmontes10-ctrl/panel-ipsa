<#
Panel IPSA - actualiza datos de mercado (Yahoo Finance) y regenera panel.html
Se ejecuta cada vez que se abre el acceso directo del escritorio.
-Ci: modo GitHub Actions (sin ventanas, sin abrir navegador; falla con exit 1).
-Output: ruta del HTML a generar (por defecto panel.html junto al script).
#>
param(
    [switch]$Ci,
    [string]$Output
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$outFile = if ($Output) { $Output } else { Join-Path $root "panel.html" }
$logFile = Join-Path $root "update_panel_error.log"
$updateNote = if ($Ci) {
    "Este panel se regenera automáticamente con GitHub Actions cada día hábil después del cierre de la Bolsa de Santiago."
} else {
    "Este panel se actualiza automáticamente cada vez que se abre el acceso directo del escritorio."
}

try {
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Pagina de carga inmediata: da feedback visual mientras se descargan los precios (~20-30s)
$loadingHtml = @'
<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="2">
<title>Panel IPSA</title>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:#f9f9f7;color:#0b0b0b;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;}
  .box{text-align:center;}
  .spin{width:34px;height:34px;border:3px solid #e1e0d9;border-top-color:#2a78d6;border-radius:50%;
    margin:0 auto 14px;animation:s 0.8s linear infinite;}
  @keyframes s{to{transform:rotate(360deg);}}
  p{color:#52514e;font-size:0.9rem;}
  @media (prefers-color-scheme: dark){
    body{background:#0d0d0d;color:#fff;} p{color:#c3c2b7;}
  }
</style></head>
<body><div class="box"><div class="spin"></div><p>Actualizando precios del IPSA...</p></div></body></html>
'@
if (-not $Ci) {
    Set-Content -Path $outFile -Value $loadingHtml -Encoding UTF8
    Start-Process $outFile
}

# Ticker -> (Nombre, Sector)
$meta = [ordered]@{
    "AGUAS-A"    = @("Aguas Andinas", "Utilities")
    "CHILE"      = @("Banco de Chile", "Financiero")
    "BCI"        = @("Banco de Crédito e Inversiones", "Financiero")
    "ITAUCL"     = @("Banco Itaú Chile", "Financiero")
    "BSANTANDER" = @("Banco Santander-Chile", "Financiero")
    "CAP"        = @("CAP S.A.", "Materiales")
    "CENCOSUD"   = @("Cencosud", "Consumo discrecional")
    "CENCOMALLS" = @("Cencosud Shopping", "Inmobiliario")
    "COLBUN"     = @("Colbún", "Utilities")
    "CCU"        = @("Compañía Cervecerías Unidas", "Consumo básico")
    "VAPORES"    = @("Vapores (CSAV)", "Industrial")
    "ANDINA-B"   = @("Embotelladora Andina", "Consumo básico")
    "ENTEL"      = @("Entel", "Comunicaciones")
    "CMPC"       = @("Empresas CMPC", "Materiales")
    "COPEC"      = @("Empresas Copec", "Energía")
    "ENELAM"     = @("Enel Américas", "Utilities")
    "ENELCHILE"  = @("Enel Chile", "Utilities")
    "ECL"        = @("Engie Energía Chile", "Utilities")
    "FALABELLA"  = @("Falabella", "Consumo discrecional")
    "IAM"        = @("Inversiones Aguas Metropolitanas", "Utilities")
    "ILC"        = @("Inversiones La Construcción", "Financiero")
    "LTM"        = @("LATAM Airlines Group", "Industrial")
    "PARAUCO"    = @("Parque Arauco", "Inmobiliario")
    "MALLPLAZA"  = @("Plaza S.A. (Mallplaza)", "Inmobiliario")
    "QUINENCO"   = @("Quiñenco", "Holding / Industrial")
    "RIPLEY"     = @("Ripley Corp", "Consumo discrecional")
    "SALFACORP"  = @("Salfacorp", "Industrial")
    "SMU"        = @("SMU", "Consumo básico")
    "SQM-B"      = @("SQM-B", "Materiales (litio/minería)")
    "CONCHATORO" = @("Viña Concha y Toro", "Consumo básico")
    "PAMPA"      = @("Pampa Investments", "Financiero / Holding")
}

Write-Host "Descargando precios (Yahoo Finance)..." -ForegroundColor Cyan
$headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }
$stocks = @()
$failed = @()

foreach ($ticker in $meta.Keys) {
    $symbol = "$ticker.SN"
    $url = "https://query1.finance.yahoo.com/v8/finance/chart/$symbol`?range=1y&interval=1d"
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
        $result = $resp.chart.result[0]
        $closes = $result.indicators.quote[0].close
        $timestamps = $result.timestamp
        $valid = @()
        for ($i = 0; $i -lt $closes.Count; $i++) {
            if ($null -ne $closes[$i]) { $valid += [pscustomobject]@{ T = $timestamps[$i]; C = [double]$closes[$i] } }
        }
        if ($valid.Count -lt 2) { throw "datos insuficientes" }
        $first = $valid[0].C
        $last = $valid[-1].C
        $pct = [math]::Round((($last / $first) - 1) * 100, 1)

        # Variación 30 días: punto de cierre más cercano a (fecha final - 30 días)
        $targetT = $valid[-1].T - (30 * 86400)
        $closest = $valid[0]
        $bestDiff = [math]::Abs($valid[0].T - $targetT)
        foreach ($p in $valid) {
            $diff = [math]::Abs($p.T - $targetT)
            if ($diff -lt $bestDiff) { $bestDiff = $diff; $closest = $p }
        }
        $pct30 = [math]::Round((($last / $closest.C) - 1) * 100, 1)

        # Variación 3 días hábiles: cierre de hace 3 ruedas bursátiles (los datos ya excluyen fines de semana y feriados)
        $base3 = if ($valid.Count -ge 4) { $valid[-4] } else { $valid[0] }
        $pct3 = [math]::Round((($last / $base3.C) - 1) * 100, 1)
        $date3 = [DateTimeOffset]::FromUnixTimeSeconds([int64]$base3.T).ToLocalTime().ToString("dd-MM-yyyy")

        $stocks += [pscustomobject]@{
            Ticker  = $ticker
            Name    = $meta[$ticker][0]
            Sector  = $meta[$ticker][1]
            First   = [math]::Round($first, 2)
            Last    = [math]::Round($last, 2)
            Pct     = $pct
            First30 = [math]::Round($closest.C, 2)
            Pct30   = $pct30
            Pct3    = $pct3
            Date3   = $date3
        }
    } catch {
        $failed += $ticker
    }
}

if ($stocks.Count -eq 0) {
    if ($Ci) { throw "No se pudo descargar ningun precio desde Yahoo Finance." }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "No se pudo descargar la informacion de mercado (Yahoo Finance). Revisa tu conexion a internet e intenta nuevamente.",
        "Panel IPSA", "OK", "Error") | Out-Null
    exit 1
}

$stocks = $stocks | Sort-Object -Property Pct -Descending
$avgPct = [math]::Round((($stocks | Measure-Object -Property Pct -Average).Average), 1)
$nPos = ($stocks | Where-Object { $_.Pct -gt 0 }).Count
$nNeg = ($stocks | Where-Object { $_.Pct -lt 0 }).Count
$nStocks = $stocks.Count
$generated = Get-Date -Format "dd-MM-yyyy HH:mm"
$periodEnd = Get-Date -Format "dd-MM-yyyy"
$periodStart = (Get-Date).AddYears(-1).ToString("dd-MM-yyyy")
$period30Start = (Get-Date).AddDays(-30).ToString("dd-MM-yyyy")

$top10Up = $stocks | Select-Object -First 10
$top10Down = $stocks | Sort-Object -Property Pct | Select-Object -First 10

$avgPct30 = [math]::Round((($stocks | Measure-Object -Property Pct30 -Average).Average), 1)
$nPos30 = ($stocks | Where-Object { $_.Pct30 -gt 0 }).Count
$nNeg30 = ($stocks | Where-Object { $_.Pct30 -lt 0 }).Count
$top10Up30 = $stocks | Sort-Object -Property Pct30 -Descending | Select-Object -First 10
$top10Down30 = $stocks | Sort-Object -Property Pct30 | Select-Object -First 10

$avgPct3 = [math]::Round((($stocks | Measure-Object -Property Pct3 -Average).Average), 1)
$nPos3 = ($stocks | Where-Object { $_.Pct3 -gt 0 }).Count
$nNeg3 = ($stocks | Where-Object { $_.Pct3 -lt 0 }).Count
$top10Up3 = $stocks | Sort-Object -Property Pct3 -Descending | Select-Object -First 10
$top10Down3 = $stocks | Sort-Object -Property Pct3 | Select-Object -First 10
$period3Start = ($stocks | Select-Object -First 1).Date3

function Esc([string]$s) {
    if ($null -eq $s) { return "" }
    return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Build-Bars($list, [bool]$isGain, [string]$field = "Pct") {
    $maxAbs = ($list | ForEach-Object { [math]::Abs($_.$field) } | Measure-Object -Maximum).Maximum
    if ($maxAbs -eq 0) { $maxAbs = 1 }
    $color = if ($isGain) { "var(--good)" } else { "var(--critical)" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $list) {
        $val = $s.$field
        $width = [math]::Round(([math]::Abs($val) / $maxAbs) * 100, 1)
        $sign = if ($val -ge 0) { "+" } else { "" }
        [void]$sb.AppendLine("<div class=`"bar-row`">")
        [void]$sb.AppendLine("  <div class=`"bar-label`"><span class=`"bar-ticker`">$(Esc($s.Ticker))</span><span class=`"bar-name`">$(Esc($s.Name))</span></div>")
        [void]$sb.AppendLine("  <div class=`"bar-track`"><div class=`"bar-fill`" style=`"width:$width%;background:$color`"></div></div>")
        [void]$sb.AppendLine("  <div class=`"bar-value`" style=`"color:$color`">$sign$val%</div>")
        [void]$sb.AppendLine("</div>")
    }
    return $sb.ToString()
}

function Build-Rows($list) {
    $sb = New-Object System.Text.StringBuilder
    $rank = 1
    foreach ($s in $list) {
        $cls = if ($s.Pct -ge 0) { "pos" } else { "neg" }
        $sign = if ($s.Pct -ge 0) { "+" } else { "" }
        $cls30 = if ($s.Pct30 -ge 0) { "pos" } else { "neg" }
        $sign30 = if ($s.Pct30 -ge 0) { "+" } else { "" }
        $cls3 = if ($s.Pct3 -ge 0) { "pos" } else { "neg" }
        $sign3 = if ($s.Pct3 -ge 0) { "+" } else { "" }
        [void]$sb.AppendLine("<tr>")
        [void]$sb.AppendLine("<td class=`"num muted`">$rank</td>")
        [void]$sb.AppendLine("<td class=`"tkr`">$(Esc($s.Ticker))</td>")
        [void]$sb.AppendLine("<td>$(Esc($s.Name))</td>")
        [void]$sb.AppendLine("<td class=`"muted`">$(Esc($s.Sector))</td>")
        [void]$sb.AppendLine("<td class=`"num`">$($s.First.ToString('N2'))</td>")
        [void]$sb.AppendLine("<td class=`"num`">$($s.Last.ToString('N2'))</td>")
        [void]$sb.AppendLine("<td class=`"num $cls`">$sign$($s.Pct)%</td>")
        [void]$sb.AppendLine("<td class=`"num $cls30`">$sign30$($s.Pct30)%</td>")
        [void]$sb.AppendLine("<td class=`"num $cls3`">$sign3$($s.Pct3)%</td>")
        [void]$sb.AppendLine("</tr>")
        $rank++
    }
    return $sb.ToString()
}

$barsUp = Build-Bars -list $top10Up -isGain $true -field "Pct"
$barsDown = Build-Bars -list $top10Down -isGain $false -field "Pct"
$barsUp30 = Build-Bars -list $top10Up30 -isGain $true -field "Pct30"
$barsDown30 = Build-Bars -list $top10Down30 -isGain $false -field "Pct30"
$barsUp3 = Build-Bars -list $top10Up3 -isGain $true -field "Pct3"
$barsDown3 = Build-Bars -list $top10Down3 -isGain $false -field "Pct3"
$rows = Build-Rows -list $stocks

$failedNote = ""
if ($failed.Count -gt 0) {
    $failedNote = "<p class=`"note warn`">No se pudo actualizar: $(Esc(($failed -join ', '))).</p>"
}

$html = @"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Panel IPSA</title>
<style>
  :root{
    color-scheme: light;
    --page:#f9f9f7; --surface:#fcfcfb; --text:#0b0b0b; --text2:#52514e; --muted:#898781;
    --grid:#e1e0d9; --baseline:#c3c2b7; --border:rgba(11,11,11,0.10);
    --good:#0ca30c; --critical:#d03b3b; --blue:#2a78d6;
  }
  @media (prefers-color-scheme: dark){
    :root{
      color-scheme: dark;
      --page:#0d0d0d; --surface:#1a1a19; --text:#ffffff; --text2:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --baseline:#383835; --border:rgba(255,255,255,0.10);
      --good:#0ca30c; --critical:#e66767; --blue:#3987e5;
    }
  }
  *{box-sizing:border-box}
  body{margin:0;padding-block:28px;background:var(--page);color:var(--text);
    font-family:system-ui,-apple-system,"Segoe UI",sans-serif;}
  .wrap{max-width:1120px;margin:0 auto;padding-inline:20px;}
  header{margin-bottom:22px;}
  h1{font-size:1.55rem;margin:0 0 4px;font-weight:700;letter-spacing:-0.01em;}
  .sub{color:var(--text2);font-size:0.92rem;margin:0;}
  .meta-row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:10px;}
  .badge{font-size:0.78rem;color:var(--muted);background:var(--surface);border:1px solid var(--border);
    border-radius:999px;padding:4px 10px;}
  .kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:18px 0 28px;}
  @media (max-width:720px){.kpis{grid-template-columns:repeat(2,1fr);}}
  .kpi{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px 16px;}
  .kpi .lbl{font-size:0.76rem;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;}
  .kpi .val{font-size:1.5rem;font-weight:700;margin-top:4px;font-variant-numeric:tabular-nums;}
  .kpi .val.pos{color:var(--good);} .kpi .val.neg{color:var(--critical);}
  .tabs{display:inline-flex;gap:4px;background:var(--surface);border:1px solid var(--border);
    border-radius:10px;padding:4px;margin-bottom:16px;}
  .tab-btn{border:none;background:transparent;color:var(--text2);font:inherit;font-size:0.84rem;
    font-weight:600;padding:7px 14px;border-radius:7px;cursor:pointer;}
  .tab-btn.active{background:var(--blue);color:#fff;}
  [hidden]{display:none!important;}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:30px;}
  @media (max-width:760px){.grid2{grid-template-columns:1fr;}}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:18px 18px 8px;}
  .card h2{font-size:1.02rem;margin:0 0 14px;font-weight:700;}
  .card h2 .n{color:var(--muted);font-weight:500;font-size:0.85rem;}
  .bar-row{display:grid;grid-template-columns:130px 1fr 64px;align-items:center;gap:10px;padding:6px 0;
    border-bottom:1px solid var(--grid);}
  .bar-row:last-child{border-bottom:none;}
  .bar-label{display:flex;flex-direction:column;min-width:0;line-height:1.2;}
  .bar-ticker{font-weight:700;font-size:0.82rem;}
  .bar-name{font-size:0.72rem;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .bar-track{background:var(--grid);border-radius:4px;height:10px;overflow:hidden;}
  .bar-fill{height:100%;border-radius:4px;min-width:3px;}
  .bar-value{text-align:right;font-variant-numeric:tabular-nums;font-weight:700;font-size:0.84rem;}
  table{width:100%;border-collapse:collapse;font-size:0.86rem;}
  thead th{position:sticky;top:0;background:var(--surface);text-align:left;font-size:0.74rem;
    text-transform:uppercase;letter-spacing:.03em;color:var(--muted);padding:9px 10px;
    border-bottom:1px solid var(--baseline);cursor:pointer;user-select:none;}
  thead th:hover{color:var(--text);}
  tbody td{padding:8px 10px;border-bottom:1px solid var(--grid);font-variant-numeric:tabular-nums;}
  tbody tr:hover td{background:rgba(137,135,129,0.08);}
  td.tkr{font-weight:700;}
  td.num{text-align:right;}
  td.muted{color:var(--text2);}
  .pos{color:var(--good);font-weight:700;} .neg{color:var(--critical);font-weight:700;}
  .table-wrap{background:var(--surface);border:1px solid var(--border);border-radius:14px;
    padding:6px 18px 14px;max-height:640px;overflow:auto;}
  .table-wrap h2{font-size:1.02rem;margin:14px 0 12px;}
  input#filterBox{width:100%;max-width:280px;padding:7px 10px;border-radius:8px;border:1px solid var(--border);
    background:var(--page);color:var(--text);font-size:0.85rem;margin:4px 0 12px;}
  footer{margin-top:24px;color:var(--muted);font-size:0.78rem;line-height:1.6;}
  .note.warn{color:var(--critical);font-size:0.8rem;}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Panel de análisis — Acciones IPSA</h1>
    <p class="sub">Rendimiento a 12 meses de los componentes del índice IPSA (Bolsa de Santiago)</p>
    <div class="meta-row">
      <span class="badge">Periodo: $periodStart – $periodEnd</span>
      <span class="badge">Actualizado: $generated</span>
      <span class="badge">$nStocks acciones analizadas</span>
      <span class="badge">Fuente: Yahoo Finance</span>
    </div>
    $failedNote
  </header>

  <div class="tabs" role="tablist">
    <button type="button" class="tab-btn active" data-tab="12m">Últimos 12 meses</button>
    <button type="button" class="tab-btn" data-tab="30d">Últimos 30 días</button>
    <button type="button" class="tab-btn" data-tab="3d">Últimos 3 días hábiles</button>
  </div>

  <div id="period-12m">
    <div class="kpis">
      <div class="kpi"><div class="lbl">Retorno promedio simple</div><div class="val $(if($avgPct -ge 0){'pos'}else{'neg'})">$(if($avgPct -ge 0){'+'})$avgPct%</div></div>
      <div class="kpi"><div class="lbl">Acciones al alza</div><div class="val pos">$nPos de $nStocks</div></div>
      <div class="kpi"><div class="lbl">Acciones a la baja</div><div class="val neg">$nNeg de $nStocks</div></div>
      <div class="kpi"><div class="lbl">Mayor alza / mayor baja</div><div class="val" style="font-size:1.1rem">$(Esc($top10Up[0].Ticker)) <span class="pos">+$($top10Up[0].Pct)%</span> · $(Esc($top10Down[0].Ticker)) <span class="neg">$($top10Down[0].Pct)%</span></div></div>
    </div>
    <div class="grid2">
      <div class="card">
        <h2>Top 10 alzas <span class="n">últimos 12 meses ($periodStart – $periodEnd)</span></h2>
        $barsUp
      </div>
      <div class="card">
        <h2>Top 10 bajas <span class="n">últimos 12 meses ($periodStart – $periodEnd)</span></h2>
        $barsDown
      </div>
    </div>
  </div>

  <div id="period-30d" hidden>
    <div class="kpis">
      <div class="kpi"><div class="lbl">Retorno promedio simple</div><div class="val $(if($avgPct30 -ge 0){'pos'}else{'neg'})">$(if($avgPct30 -ge 0){'+'})$avgPct30%</div></div>
      <div class="kpi"><div class="lbl">Acciones al alza</div><div class="val pos">$nPos30 de $nStocks</div></div>
      <div class="kpi"><div class="lbl">Acciones a la baja</div><div class="val neg">$nNeg30 de $nStocks</div></div>
      <div class="kpi"><div class="lbl">Mayor alza / mayor baja</div><div class="val" style="font-size:1.1rem">$(Esc($top10Up30[0].Ticker)) <span class="pos">+$($top10Up30[0].Pct30)%</span> · $(Esc($top10Down30[0].Ticker)) <span class="neg">$($top10Down30[0].Pct30)%</span></div></div>
    </div>
    <div class="grid2">
      <div class="card">
        <h2>Top 10 alzas <span class="n">últimos 30 días ($period30Start – $periodEnd)</span></h2>
        $barsUp30
      </div>
      <div class="card">
        <h2>Top 10 bajas <span class="n">últimos 30 días ($period30Start – $periodEnd)</span></h2>
        $barsDown30
      </div>
    </div>
  </div>

  <div id="period-3d" hidden>
    <div class="kpis">
      <div class="kpi"><div class="lbl">Retorno promedio simple</div><div class="val $(if($avgPct3 -ge 0){'pos'}else{'neg'})">$(if($avgPct3 -ge 0){'+'})$avgPct3%</div></div>
      <div class="kpi"><div class="lbl">Acciones al alza</div><div class="val pos">$nPos3 de $nStocks</div></div>
      <div class="kpi"><div class="lbl">Acciones a la baja</div><div class="val neg">$nNeg3 de $nStocks</div></div>
      <div class="kpi"><div class="lbl">Mayor alza / mayor baja</div><div class="val" style="font-size:1.1rem">$(Esc($top10Up3[0].Ticker)) <span class="pos">+$($top10Up3[0].Pct3)%</span> · $(Esc($top10Down3[0].Ticker)) <span class="neg">$($top10Down3[0].Pct3)%</span></div></div>
    </div>
    <div class="grid2">
      <div class="card">
        <h2>Top 10 alzas <span class="n">últimos 3 días hábiles (cierre $period3Start – $periodEnd)</span></h2>
        $barsUp3
      </div>
      <div class="card">
        <h2>Top 10 bajas <span class="n">últimos 3 días hábiles (cierre $period3Start – $periodEnd)</span></h2>
        $barsDown3
      </div>
    </div>
  </div>

  <div class="table-wrap">
    <h2>Ranking completo — $nStocks acciones IPSA</h2>
    <input id="filterBox" type="text" placeholder="Filtrar por nombre, ticker o sector...">
    <table id="fullTable">
      <thead>
        <tr>
          <th data-k="rank">#</th>
          <th data-k="tkr">Ticker</th>
          <th data-k="name">Nombre</th>
          <th data-k="sector">Sector</th>
          <th data-k="first" style="text-align:right">Precio inicial (12m)</th>
          <th data-k="last" style="text-align:right">Precio actual</th>
          <th data-k="pct" style="text-align:right">Var. 12m</th>
          <th data-k="pct30" style="text-align:right">Var. 30d</th>
          <th data-k="pct3" style="text-align:right">Var. 3 días háb.</th>
        </tr>
      </thead>
      <tbody>
        $rows
      </tbody>
    </table>
  </div>

  <footer>
    Panel generado localmente a partir de precios de cierre diarios (Yahoo Finance, sufijo .SN, Bolsa de Santiago).
    El retorno promedio es un simple promedio aritmético de las $nStocks acciones (no ponderado por capitalización
    bursátil ni por el peso real dentro del índice IPSA). $updateNote
    Uso informativo, no constituye recomendación de inversión.
  </footer>
</div>
<script>
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const tab = btn.dataset.tab;
      ['12m', '30d', '3d'].forEach(t => {
        document.getElementById('period-' + t).hidden = (tab !== t);
      });
    });
  });

  const box = document.getElementById('filterBox');
  const tbody = document.querySelector('#fullTable tbody');
  const rows = Array.from(tbody.querySelectorAll('tr'));
  box.addEventListener('input', () => {
    const q = box.value.trim().toLowerCase();
    rows.forEach(r => {
      r.style.display = r.textContent.toLowerCase().includes(q) ? '' : 'none';
    });
  });
  document.querySelectorAll('#fullTable thead th').forEach((th, idx) => {
    let asc = true;
    th.addEventListener('click', () => {
      const list = Array.from(tbody.querySelectorAll('tr'));
      list.sort((a, b) => {
        const av = a.children[idx].textContent.replace(/[%,+]/g,'').trim();
        const bv = b.children[idx].textContent.replace(/[%,+]/g,'').trim();
        const an = parseFloat(av), bn = parseFloat(bv);
        const cmp = (!isNaN(an) && !isNaN(bv)) ? (an - bn) : av.localeCompare(bv, 'es');
        return asc ? cmp : -cmp;
      });
      list.forEach(r => tbody.appendChild(r));
      asc = !asc;
    });
  });
</script>
</body>
</html>
"@

Set-Content -Path $outFile -Value $html -Encoding UTF8
Write-Host "Panel actualizado: $outFile" -ForegroundColor Green
if (-not $Ci) { Start-Process $outFile }

} catch {
    $msg = "Error al generar el panel IPSA:`n`n$($_.Exception.Message)`n`nEn: $($_.InvocationInfo.PositionMessage)"
    if ($Ci) { Write-Error $msg -ErrorAction Continue; exit 1 }
    try { Add-Content -Path $logFile -Value ("`n[$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')] " + $msg) -Encoding UTF8 } catch {}
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($msg, "Panel IPSA - Error", "OK", "Error") | Out-Null
}
