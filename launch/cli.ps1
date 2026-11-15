<#
  launch\cli.ps1 - make と build.bat の中身（引数の解釈・ヘルプ・一覧・lint の呼び出し）。ビルドは launch\run.bat を呼ぶ

    make synth iq_top CLOCK=100
    .\build.bat synth iq_top CLOCK=100   （make と同じ書き方）

  前の build.bat の書き方（build iq_top synth、timing 20、100mhz、clean など）もそのまま受け付ける
#>
[CmdletBinding()]
param(
    # 出力を UTF-8 にする（WSL の make から呼ぶとき。Makefile が付ける）
    [switch]$Utf8Output,

    # コマンド・対象・オプション（CLOCK=100 N=20 SYNTH=1 など）を全部ここで受け取る
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell は出力を Windows の文字コード（Shift-JIS）で書くので、WSL から呼ぶときは UTF-8 にする
if ($Utf8Output) { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 }

# リポジトリ直下（このスクリプトは launch\ の中にある）
$Root = Split-Path -Parent $PSScriptRoot

# 全角を 2 文字分と数えて右を空白で埋める
function Pad([string]$s, [int]$w) {
    $n = 0
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -gt 0x2e7f) { $n += 2 } else { $n += 1 } }
    if ($n -ge $w) { return $s + ' ' }
    return $s + (' ' * ($w - $n))
}

function Write-Row([string]$a, [string]$b, [string]$color = 'Cyan') {
    Write-Host ('    ' + (Pad $a 34)) -ForegroundColor $color -NoNewline
    Write-Host $b
}

function Show-Help {
    Write-Host ''
    Write-Host '  make' -ForegroundColor Yellow -NoNewline
    Write-Host ' - Vivado のビルド（中身は launch\）'
    Write-Host ''
    Write-Host '  make <コマンド> [対象] [CLOCK=100] [N=20] [SYNTH=1] [CLEAN=1] [STRATEGY=..] [SYNTH_STRATEGY=..]' -ForegroundColor White
    Write-Host '  .\build.bat <コマンド> [対象] [CLOCK=100] ...（make と同じ書き方）' -ForegroundColor White
    Write-Host ''
    Write-Host '  コマンド' -ForegroundColor Yellow
    Write-Row 'synth'   '合成だけ。速い（配線遅延は見積もりなので段数を見るとき用）'
    Write-Row 'build'   'ビルド（全体はビットストリームまで、それ以外は配置配線まで）'
    Write-Row 'timing'  '前回の結果のクリティカルパス（N= で本数）'
    Write-Row 'lint'    'Verilator などで静的チェック（WSL）。対象を付けるとそのモジュールから下だけ'
    Write-Row 'list'    'これまでの結果の一覧'
    Write-Row 'status'  '前回の結果の規模とタイミングの概要'
    Write-Row 'view'    'ビルドして GUI で開く'
    Write-Row 'open'    'ビルドせずに前回の結果を GUI で開く'
    Write-Row 'program' '全体を（必要なら）ビルドしてボードに書き込む'
    Write-Row 'write'   'ビルドせずに、今あるビットストリームをボードに書き込むだけ'
    Write-Row 'errors'  '前回の全体のビルドのエラーと警告'
    Write-Host ''
    Write-Host '  対象' -ForegroundColor Yellow
    Write-Row '（なし） / top'      '全体（top.sv）。.xpr のプロジェクトでビルド' 'Green'
    Write-Row 'backend'             'backend_top だけ' 'Green'
    Write-Row 'iq_top, lsu_top ...' 'そのモジュールだけ。結果は timing\<名前>\' 'Green'
    Write-Host ''
    Write-Host '  オプション' -ForegroundColor Yellow
    Write-Row 'CLOCK=100' 'クロック（100 / 100mhz / 10ns）。既定 80MHz。全体には効かない（clk_wiz_0 で決まる）' 'Magenta'
    Write-Row 'N=20'      'クリティカルパスをワースト 20 本（既定 10 本）' 'Magenta'
    Write-Row 'SYNTH=1'   'view を合成までにする。全体の open は合成の結果を開く' 'Magenta'
    Write-Row 'CLEAN=1'   '全体の合成と配置配線をやり直す' 'Magenta'
    Write-Row 'STRATEGY=Performance_Explore' '配置配線の strategy（Vivado の名前）。付けなければ既定' 'Magenta'
    Write-Row 'SYNTH_STRATEGY=Flow_PerfOptimized_high' '合成の strategy。間違った名前なら選べる名前を表示' 'Magenta'
    Write-Row 'ALL=1 STRICT=1 V=1' 'lint で note も表示 / style も失敗にする / 生の出力も表示' 'Magenta'
    Write-Host ''
    Write-Host '  例' -ForegroundColor Yellow
    Write-Row 'make synth iq_top'            'iq_top を合成だけして段数を見る' 'White'
    Write-Row 'make build backend CLOCK=100' 'backend_top を 100MHz で配置配線' 'White'
    Write-Row 'make view iq_top'             'iq_top を配置配線して GUI で開く' 'White'
    Write-Row 'make timing backend N=20'     '前回の backend のワースト 20 本' 'White'
    Write-Row 'make build backend STRATEGY=Performance_Explore' 'strategy を変えて配置配線' 'White'
    Write-Row 'make list'                    'これまでの結果を並べて比べる' 'White'
    Write-Row 'make program'                 '全体をビルドしてボードに書き込む' 'White'
    Write-Row 'make lint iq_top'             'iq_top から下だけを lint' 'White'
    Write-Host ''
    Write-Host '  build.bat は前の書き方（build iq_top synth、timing 20 など）もそのまま使える' -ForegroundColor DarkGray
    Write-Host ''
}

# レポートから WNS / クロック / LUT を読む
function Read-Result([string]$name, [string]$summary, [string]$util, [string]$dcp, [string]$stage) {
    $r = [ordered]@{ Name = $name; Stage = $stage; Date = ''; Clock = '-'; WNS = '-'; Fmax = '-'; LUT = '-' }
    if (Test-Path $dcp) { $r.Date = (Get-Item $dcp).LastWriteTime.ToString('MM/dd HH:mm') }
    if (Test-Path $summary) {
        $lines = Get-Content $summary
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s+WNS\(ns\)' -and $i + 2 -lt $lines.Count) {
                $r.WNS = ($lines[$i + 2].Trim() -split '\s+')[0]
                break
            }
        }
        $clocks = @($lines | Where-Object { $_ -match '^\s*\S+\s+\{[\d.]+\s+[\d.]+\}\s+[\d.]+\s+[\d.]+' })
        if ($clocks.Count -eq 1 -and $clocks[0] -match '\}\s+([\d.]+)\s+([\d.]+)') {
            $period = [double]$Matches[1]
            $r.Clock = '{0:0.#}MHz' -f [double]$Matches[2]
            if ($r.WNS -match '^-?[\d.]+$') {
                $r.Fmax = '{0:0.0}MHz' -f (1000.0 / ($period - [double]$r.WNS))
            }
        }
    }
    if (Test-Path $util) {
        $m = Select-String -Path $util -Pattern '^\| Slice LUTs\*?\s+\|\s+(\d+)\s+\|\s+\d+\s+\|\s+\d+\s+\|\s+([\d.]+)' | Select-Object -First 1
        if ($m) { $r.LUT = '{0} ({1}%)' -f $m.Matches[0].Groups[1].Value, $m.Matches[0].Groups[2].Value }
    }
    return [pscustomobject]$r
}

function Show-List {
    $rows = @()
    $impl = Join-Path $Root 'core.runs\impl_1'
    if (Test-Path (Join-Path $impl 'top_routed.dcp')) {
        $rows += Read-Result 'top' (Join-Path $impl 'top_timing_summary_routed.rpt') `
            (Join-Path $impl 'top_utilization_placed.rpt') (Join-Path $impl 'top_routed.dcp') 'routed'
    }
    $timing = Join-Path $Root 'timing'
    if (Test-Path $timing) {
        foreach ($d in Get-ChildItem $timing -Directory) {
            $top = if ($d.Name -eq 'backend') { 'backend_top' } else { $d.Name }
            $best = $null
            foreach ($kind in 'routed', 'synth') {
                $f = Join-Path $d.FullName "${top}_$kind.dcp"
                if ((Test-Path $f) -and (-not $best -or (Get-Item $f).LastWriteTime -gt (Get-Item $best.File).LastWriteTime)) {
                    $best = @{ File = $f; Kind = $kind }
                }
            }
            if (-not $best) { continue }
            $rows += Read-Result $d.Name (Join-Path $d.FullName 'summary.rpt') `
                (Join-Path $d.FullName 'utilization.rpt') $best.File $best.Kind
        }
    }
    if ($rows.Count -eq 0) {
        Write-Host '  まだ結果が無い。例: make synth iq_top'
        return
    }
    Write-Host ''
    Write-Host ('  ' + (Pad '対象' 17) + (Pad '段階' 8) + (Pad '日時' 13) + (Pad 'クロック' 9) + ('{0,8} {1,9}  {2}' -f 'WNS', 'Fmax', 'LUT')) -ForegroundColor Yellow
    foreach ($r in $rows) {
        $color = if ($r.WNS -match '^-') { 'Red' } elseif ($r.WNS -match '^[\d.]+$') { 'Green' } else { 'Gray' }
        Write-Host ('  {0,-16} {1,-7} {2,-12} {3,-8} ' -f $r.Name, $r.Stage, $r.Date, $r.Clock) -NoNewline
        Write-Host ('{0,8}' -f $r.WNS) -ForegroundColor $color -NoNewline
        Write-Host (' {0,9}  {1}' -f $r.Fmax, $r.LUT)
    }
    Write-Host ''
    Write-Host '  synth の行は配線遅延が見積もりなので、Fmax は甘め' -ForegroundColor DarkGray
    Write-Host ''
}

function Convert-Clock([string]$c) {
    if ($c -match '^\d+(\.\d+)?$') { return "${c}mhz" }
    if ($c -match '^\d+(\.\d+)?(mhz|ns)$') { return $c.ToLower() }
    Write-Host "  クロックは 100 / 100mhz / 10ns のように書く（$c）" -ForegroundColor Red
    exit 1
}

function Stop-Usage([string]$msg) {
    Write-Host "  $msg" -ForegroundColor Red
    Write-Host '  使い方は make help（.\build.bat help）' -ForegroundColor DarkGray
    exit 1
}

# 引数を並べ直す。1 つ目のコマンド、2 つ目の対象のほかに、
# make と同じ KEY=VALUE と、前の build.bat の書き方（synth / clean / all / 20 / 100mhz）を受け付ける
$Commands = 'help', 'build', 'synth', 'view', 'open', 'timing', 'status', 'list',
            'program', 'write', 'errors', 'lint'
$words = @($Rest | Where-Object { $_ })
$Command = ''
$Target = ''
$Clock = ''
$Paths = 0
$Synth = $false
$Clean = $false
$All = $false
$Strict = $false
$VerboseLint = $false
$Strategy = ''
$SynthStrategy = ''
foreach ($w in $words) {
    if ($w -match '^(\w+)=(.*)$') {
        $key = $Matches[1].ToUpper()
        $val = $Matches[2]
        $on = $val -ne '' -and $val -ne '0'
        switch ($key) {
            'CLOCK'  { $Clock = $val }
            'N'      { if ($val -notmatch '^\d+$') { Stop-Usage "N= は数で書く（$w）" }; $Paths = [int]$val }
            'SYNTH'  { $Synth = $on }
            'CLEAN'  { $Clean = $on }
            'ALL'    { $All = $on }
            'STRICT' { $Strict = $on }
            'V'      { $VerboseLint = $on }
            'STRATEGY' {
                if ($val -notmatch '^\w+$') { Stop-Usage "STRATEGY= は Vivado の strategy の名前（$w）" }
                $Strategy = $val
            }
            'SYNTH_STRATEGY' {
                if ($val -notmatch '^\w+$') { Stop-Usage "SYNTH_STRATEGY= は Vivado の strategy の名前（$w）" }
                $SynthStrategy = $val
            }
            default  { Stop-Usage "知らないオプション: $w（CLOCK= N= SYNTH=1 CLEAN=1 STRATEGY= SYNTH_STRATEGY= ALL=1 STRICT=1 V=1）" }
        }
    } elseif ($w -match '^\d+$') {
        $Paths = [int]$w
    } elseif ($w -match '^\d+(\.\d+)?(mhz|ns)$') {
        $Clock = $w
    } elseif ($w -eq 'synth' -and $Command) {
        $Synth = $true
    } elseif ($w -eq 'clean') {
        $Clean = $true
    } elseif ($w -eq 'all' -and -not $Command) {
        $Command = 'program'
    } elseif (-not $Command -and $w -in $Commands) {
        $Command = $w.ToLower()
    } elseif (-not $Target -and $w -match '^[A-Za-z_]\w*$') {
        $Target = $w
    } else {
        Stop-Usage "余分な引数: $w"
    }
}
# コマンドを書かなければ、対象があれば build、clean だけなら program（前の build.bat clean）、何も無ければ使い方
if (-not $Command) {
    if ($Target) { $Command = 'build' } elseif ($Clean) { $Command = 'program' } else { $Command = 'help' }
}

switch ($Command) {
    'help' { Show-Help; exit 0 }
    'list' { Show-List; exit 0 }
}

$whole = -not $Target -or $Target -eq 'top'

# lint は WSL の Verilator で launch/lint.py を動かす（対象が無ければ全部）
if ($Command -eq 'lint') {
    $la = @('python3', 'launch/lint.py')
    if (-not $whole) { $la += $Target }
    if ($All) { $la += '-a' }
    if ($Strict) { $la += '--strict' }
    if ($VerboseLint) { $la += '-v' }
    Write-Host "> wsl $($la -join ' ')" -ForegroundColor DarkGray
    Push-Location $Root
    try { & wsl @la } finally { Pop-Location }
    exit $LASTEXITCODE
}
if (-not $whole -and $Command -in 'program', 'write', 'errors') {
    Write-Host "  $Command は全体だけ（対象を付けない）" -ForegroundColor Red
    exit 1
}

if ($Command -eq 'synth') {
    $Command = 'build'
    $Synth = $true
}
# launch/run.bat のモード名に直す（program はビルドして書き込む = all、write は書き込むだけ = program）
$mode = @{ program = 'all'; write = 'program' }[$Command]
if (-not $mode) { $mode = $Command }

$a = @($mode)
if (-not $whole) { $a += $Target }
if ($Synth) { $a += 'synth' }
if ($Paths -gt 0) { $a += "$Paths" }
if ($Clock) { $a += (Convert-Clock $Clock) }
if ($Clean) { $a += 'clean' }
# strategy はビルドするときだけ渡す（status などで渡すと全体の run の設定を書き換えてしまう）
if ($mode -in 'build', 'view', 'all') {
    if ($Strategy) { $a += "strategy:$Strategy" }
    if ($SynthStrategy) { $a += "synth_strategy:$SynthStrategy" }
} elseif ($Strategy -or $SynthStrategy) {
    Write-Host "  STRATEGY= / SYNTH_STRATEGY= はビルドするときだけ効く（$Command では無視）" -ForegroundColor DarkGray
}

Write-Host "> launch\run.bat $($a -join ' ')" -ForegroundColor DarkGray
& (Join-Path $Root 'launch\run.bat') @a
exit $LASTEXITCODE
