# launch/flow.tcl - Vivado を GUI なしで動かすスクリプト（Vivado の中で動く本体）
#
# リポジトリ直下の launch/ に置く。普通は make か build.bat（-> launch/run.bat）から呼ぶ。Vivado は -source のファイルを Windows の文字コードで読むので、
# launch/boot.tcl から UTF-8 として読み込む:
#   vivado -mode batch -nojournal -notrace -source launch/boot.tcl -tclargs [モード] [対象] [オプション]
#
# 対象（どのモードでも同じ）:
#   （なし） 全体（top.sv）。.xpr のプロジェクトでビルドする。top と書いても同じ
#   backend  backend_top だけ
#   <名前>   そのモジュールだけ（例 iq_top、lsu_top）
#   backend とモジュールは .xpr を使わず out-of-context で合成・配置配線する。
#   結果は timing/<名前>/（backend は timing/backend/）に保存（配置の図は placement.svg）
#
# モード:
#   all      全体：必要ならビットストリームを作り、ボードに書き込む（全体だけ）
#   build    全体：ビットストリームを作るだけ。モジュール：合成・配置配線して結果を表示
#   program  今あるビットストリームをボードに書き込むだけ（全体だけ）
#   errors   前回の実行の ERROR と CRITICAL WARNING を表示（全体だけ）
#   status   前回の結果の状態と概要を表示（ビルドはしない）
#   timing   前回の結果からクリティカルパスを分析して表示（ビルドはしない）
#            全体は配置配線が終わっていればその結果、無ければ合成の結果を使う
#            モジュールは配線後と合成後のうち新しい方を使う
#   ip       IP の状態を表示し、ロックされた IP を更新して、出力ファイルを作り直す（全体だけ）
#   view     build をして、通ったら結果を Vivado の GUI で開く
#   open     ビルドせずに前回の結果を Vivado の GUI で開く（launch/run.bat が GUI で起動する）
#   モードを書かなければ、全体は all、backend とモジュールは build
#
# オプション:
#   synth    合成で止める（配線遅延は見積もり）。build / view で使う
#   N        クリティカルパスをワースト N 本表示（既定 10 本）
#   100mhz   クロックを指定（10ns とも書ける。既定 12.5ns = 80MHz）。全体は clk_wiz_0 で決まるので効かない
#   clean    全体の合成と配置配線を強制的にやり直す
#   strategy:<名前>        配置配線の strategy（Vivado の名前。例 Performance_Explore）。無ければ既定
#   synth_strategy:<名前>  合成の strategy（例 Flow_PerfOptimized_high）。無ければ既定
#            全体は synth_1 / impl_1 に設定し、変わったらやり直す（次に付けずにビルドすると既定に戻る）
#            モジュールは仮のプロジェクトで中身を読み出し、同じオプションで合成・配置配線する
#   違反パスを「始点の FF の束 -> 終点の束」でまとめた表を groups.rpt に出す
#
# 終了コード: 0 = 成功、1 = 失敗（シェルスクリプトから判定に使える）

# リポジトリ直下（このスクリプトは launch/ の中にある）
set root_dir [file dirname [file dirname [file normalize [info script]]]]

proc die {msg} {
    puts stderr "\n*** FAILED: $msg\n"
    exit 1
}

proc section {title} {
    puts "\n========== $title =========="
}

proc cpu_count {} {
    if {[info exists ::env(NUMBER_OF_PROCESSORS)]} {
        return $::env(NUMBER_OF_PROCESSORS)
    }
    if {![catch {exec nproc} n]} {
        return $n
    }
    return 4
}

# ---------------------------------------------------------------
# メッセージ・レポート
# ---------------------------------------------------------------

# 全ランのログから ERROR と CRITICAL WARNING の行を表示する。
# 戻り値は ERROR の数
proc show_run_messages {} {
    set n_err 0
    set n_crit 0
    set n_warn 0
    foreach run [get_runs] {
        set log [file join [get_property DIRECTORY $run] runme.log]
        if {![file exists $log]} { continue }
        set fh [open $log r]
        set seen [dict create]
        set lines {}
        while {[gets $fh line] >= 0} {
            if {[regexp {^(ERROR|CRITICAL WARNING):} $line -> kind]} {
                if {[dict exists $seen $line]} { continue }
                dict set seen $line 1
                lappend lines $line
                if {$kind eq "ERROR"} { incr n_err } else { incr n_crit }
            } elseif {[string match "WARNING:*" $line]} {
                incr n_warn
            }
        }
        close $fh
        if {[llength $lines] > 0} {
            puts "\n--- $run : [get_property STATUS $run] ---"
            foreach l $lines { puts "  $l" }
        }
    }
    section "Messages"
    puts "$n_err error(s), $n_crit critical warning(s), $n_warn warning(s)"
    puts "full logs: <project>.runs/<run>/runme.log"
    return $n_err
}

proc show_timing {} {
    set impl [get_runs impl_1]
    if {[catch {get_property STATS.WNS $impl} wns] || $wns eq ""} {
        puts "Timing: no data (implementation not finished)"
        return
    }
    set whs  [get_property STATS.WHS  $impl]
    set tpws [get_property STATS.TPWS $impl]
    puts "Timing: WNS = $wns ns (setup), WHS = $whs ns (hold), TPWS = $tpws ns (pulse width)"
    if {$wns < 0 || $whs < 0 || $tpws < 0} {
        puts "  !!! TIMING VIOLATED - see [get_property DIRECTORY $impl]/[get_property top [current_fileset]]_timing_summary_routed.rpt"
    }
}

proc show_status {} {
    section "Run status"
    foreach run [get_runs] {
        puts [format "  %-28s %-6s %s" $run \
                  [get_property PROGRESS $run] [get_property STATUS $run]]
    }
}

proc run_failed {run} {
    return [expr {[get_property PROGRESS $run] ne "100%" ||
                  [string match "*ERROR*" [get_property STATUS $run]]}]
}

proc bitfile_path {} {
    set top [get_property top [current_fileset]]
    return [file join [get_property DIRECTORY [get_runs impl_1]] "$top.bit"]
}

# ---------------------------------------------------------------
# クリティカルパスの分析（timing モード）
# ---------------------------------------------------------------
proc fmt_ns {v} {
    if {$v eq ""} { return "    inf" }
    return [format "%7.3f" $v]
}

# セルが属する階層を返す。例: u_cpu/u_alu/res_i_3 なら u_cpu/u_alu
proc cell_parent {name} {
    set i [string last "/" $name]
    if {$i < 0} { return "(top)" }
    return [string range $name 0 [expr {$i - 1}]]
}

# タイミングパス上のセルを始点から終点の順に返す（連続する同じセルは 1 つにまとめる）
proc path_cells {path} {
    set cells {}
    set last ""
    foreach pin [get_pins -quiet -of_objects $path] {
        set c [get_cells -quiet -of_objects $pin]
        if {$c eq "" || $c eq $last} { continue }
        lappend cells $c
        set last $c
    }
    return $cells
}

# 連続するセルを階層ごとにまとめる。戻り値は 階層 と 種類ごとの個数 の組のリスト
proc path_by_module {cells} {
    set groups {}
    set cur ""
    set types [dict create]
    foreach c $cells {
        set h [cell_parent [get_property NAME $c]]
        if {$h ne $cur && $cur ne ""} {
            lappend groups [list $cur $types]
            set types [dict create]
        }
        set cur $h
        dict incr types [get_property REF_NAME $c]
    }
    if {$cur ne ""} { lappend groups [list $cur $types] }
    return $groups
}

proc show_critical_paths {n} {
    set synth [get_runs synth_1]
    set impl  [get_runs impl_1]
    if {[get_property PROGRESS $impl] eq "100%" && ![run_failed $impl]} {
        open_run impl_1
        set stage "after place & route (impl_1)"
    } elseif {[get_property PROGRESS $synth] eq "100%" && ![run_failed $synth]} {
        open_run synth_1
        set stage "after synthesis (synth_1) - net delays are ESTIMATES"
    } else {
        die "no finished synthesis/implementation. run 'build' first"
    }
    report_critical_paths $n $stage [file join $::root_dir timing]
    report_path_groups [file join $::root_dir timing]
}

# 今開いているデザインのクリティカルパスを表示し、Vivado の詳しいレポートを dir に保存する
proc report_critical_paths {n stage dir} {
    file mkdir $dir
    report_timing_summary -max_paths $n -file [file join $dir summary.rpt]
    report_timing -delay_type max -max_paths $n -nworst 1 -sort_by slack -input_pins \
        -file [file join $dir paths.rpt]

    section "Timing ($stage)"

    # クロックごとに 周期、ワーストスラック、見積もりの最大周波数 を表示
    puts [format "  %-24s %9s %9s %10s" "clock" "period" "WNS" "Fmax(est)"]
    foreach clk [get_clocks] {
        set period [get_property PERIOD $clk]
        set p [get_timing_paths -quiet -delay_type max -max_paths 1 -group $clk]
        if {$p eq "" || [get_property SLACK $p] eq ""} {
            puts [format "  %-24s %7.3f ns %9s %10s" $clk $period "-" "-"]
            continue
        }
        set wns [get_property SLACK $p]
        set fmax [expr {1000.0 / ($period - $wns)}]
        puts [format "  %-24s %7.3f ns %s ns %6.1f MHz" $clk $period [fmt_ns $wns] $fmax]
    }

    # 違反しているパスを全部取ってきて TNS（負のスラックの合計）を計算する
    set fail [get_timing_paths -quiet -delay_type max -max_paths 100000 -nworst 1 -slack_lesser_than 0]
    set tns 0.0
    foreach p $fail { set tns [expr {$tns + [get_property SLACK $p]}] }
    set hold [get_timing_paths -quiet -delay_type min -max_paths 1]
    set whs [expr {$hold eq "" ? "" : [get_property SLACK $hold]}]
    puts [format "  setup: TNS = %.3f ns, failing endpoints = %d" $tns [llength $fail]]
    puts "  hold : WHS = [fmt_ns $whs] ns"

    # ワースト n 本を 1 本ずつ表示し、通ったモジュールを数えておく
    set paths [get_timing_paths -delay_type max -max_paths $n -nworst 1 -sort_by slack]
    set hits [dict create]
    set i 0
    foreach p $paths {
        incr i
        set slack [get_property SLACK $p]
        set dp    [get_property DATAPATH_DELAY $p]
        set ld    [get_property DATAPATH_LOGIC_DELAY $p]
        set nd    [get_property DATAPATH_NET_DELAY $p]
        set mark  [expr {$slack ne "" && $slack < 0 ? "  <<< VIOLATED" : ""}]

        section "#$i  slack [fmt_ns $slack] ns$mark"
        puts [format "  requirement %s ns   data path %s ns = logic %s (%2.0f%%) + route %s (%2.0f%%)" \
                  [fmt_ns [get_property REQUIREMENT $p]] [fmt_ns $dp] \
                  [fmt_ns $ld] [expr {$dp > 0 ? 100.0 * $ld / $dp : 0}] \
                  [fmt_ns $nd] [expr {$dp > 0 ? 100.0 * $nd / $dp : 0}]]
        puts "  logic levels [get_property LOGIC_LEVELS $p], skew [fmt_ns [get_property SKEW $p]] ns,\
              clock [get_property STARTPOINT_CLOCK $p] -> [get_property ENDPOINT_CLOCK $p]"
        puts "  from: [get_property STARTPOINT_PIN $p]"
        puts "  to  : [get_property ENDPOINT_PIN $p]"
        puts "  through:"
        set seen [dict create]
        foreach g [path_by_module [path_cells $p]] {
            lassign $g hier types
            set ts {}
            dict for {t k} $types { lappend ts [expr {$k > 1 ? "$t x$k" : $t}] }
            puts [format "    %-40s %s" $hier [join $ts ", "]]
            # 同じパスで同じモジュールを 2 回通っても 1 回と数える
            if {![dict exists $seen $hier]} { dict set seen $hier 1; dict incr hits $hier }
        }
    }

    # 通った本数の多いモジュール順に並べる
    section "Modules on the worst $i path(s)"
    set rows {}
    dict for {h k} $hits { lappend rows [list $h $k] }
    foreach r [lsort -integer -decreasing -index 1 $rows] {
        puts [format "  %3d / %d  %s" [lindex $r 1] $i [lindex $r 0]]
    }
    puts "\nfull reports: [file join $dir summary.rpt], [file join $dir paths.rpt]"
}

# ---------------------------------------------------------------
# IP（clk_wiz_0 など）
# ---------------------------------------------------------------

# IP の状態（ロックされているか、その理由）を表示する
proc show_ip_status {} {
    set f [file join $::root_dir ip_status.rpt]
    report_ip_status -file $f
    set fh [open $f r]
    puts [read $fh]
    close $fh
    file delete $f
}

# IP の出力ファイルを作り直す。出力ファイルは git に入れていないので、
# clone 直後や別の PC では無い、または古い状態になっている
proc regenerate_ips {} {
    foreach ip [get_ips -quiet] {
        if {[catch {generate_target all $ip} err]} {
            puts "  generate_target failed for $ip: $err"
        }
        catch {export_ip_user_files -of_objects $ip -no_script -sync -force -quiet}
    }
}

# ip モード：ロックされた IP を今の Vivado 向けに更新し、出力ファイルを作り直す
proc fix_ips {} {
    section "IP status (before)"
    show_ip_status
    set locked [get_ips -quiet -filter {IS_LOCKED == 1}]
    if {[llength $locked] > 0} {
        puts "Upgrading locked IP: $locked"
        upgrade_ip $locked
    }
    puts "Regenerating IP output products ..."
    regenerate_ips
    section "IP status (after)"
    show_ip_status
    set still [get_ips -quiet -filter {IS_LOCKED == 1}]
    if {[llength $still] > 0} {
        die "still locked: $still  (see the status above)"
    }
    puts "IP OK. now run: make build"
}

# ビルドの前に呼ぶ。ロックされた IP（clone 直後や別の PC で起きる）があれば自動で更新し、
# IP の出力ファイルが無い、または古いときに備えて作り直しておく
proc prepare_ips {} {
    set locked [get_ips -quiet -filter {IS_LOCKED == 1}]
    if {[llength $locked] > 0} {
        puts "IP is locked: $locked  -> upgrading automatically"
        if {[catch {upgrade_ip $locked} err]} {
            show_ip_status
            die "upgrade_ip failed: $err"
        }
        set still [get_ips -quiet -filter {IS_LOCKED == 1}]
        if {[llength $still] > 0} {
            show_ip_status
            die "still locked: $still  (see the status above)"
        }
        puts "IP upgraded: $locked"
    }
    regenerate_ips
}

# ---------------------------------------------------------------
# memory リポジトリの取得
# ---------------------------------------------------------------

# src/memory/memory_repository に cpuex-2026-group7/memory を取ってくる。あれば最新版に更新する
proc fetch_memory_repo {} {
    set url https://github.com/cpuex-2026-group7/memory.git
    set dir [file join $::root_dir src memory memory_repository]
    section "Fetch memory"
    if {[file isdirectory [file join $dir .git]]} {
        puts "updating $dir"
        if {[catch {exec -ignorestderr git -C $dir pull --ff-only -q} err]} {
            puts "WARNING: update failed, using the local version: $err"
        }
    } else {
        puts "cloning $url into $dir"
        file mkdir [file dirname $dir]
        if {[catch {exec -ignorestderr git clone -q --depth 1 $url $dir} err]} {
            die "git clone failed: $err"
        }
    }
}

# src/fpu/fpu_repository に cpuex-2026-group7/fpu を取ってくる。あれば最新版に更新する
proc fetch_fpu_repo {} {
    set url https://github.com/cpuex-2026-group7/fpu.git
    set dir [file join $::root_dir src fpu fpu_repository]
    section "Fetch fpu"
    if {[file isdirectory [file join $dir .git]]} {
        puts "updating $dir"
        if {[catch {exec -ignorestderr git -C $dir pull --ff-only -q} err]} {
            puts "WARNING: update failed, using the local version: $err"
        }
    } else {
        puts "cloning $url into $dir"
        file mkdir [file dirname $dir]
        if {[catch {exec -ignorestderr git clone -q --depth 1 $url $dir} err]} {
            die "git clone failed: $err"
        }
    }
}

# dir 以下の .sv を再帰的に集める（. で始まるフォルダは見ない）
proc find_sv_files {dir} {
    set files [glob -nocomplain -types f -directory $dir *.sv]
    foreach d [glob -nocomplain -types d -directory $dir *] {
        if {[string index [file tail $d] 0] eq "."} { continue }
        lappend files {*}[find_sv_files $d]
    }
    return $files
}

# プロジェクトに入れる .sv：src/ の下（src/ip と *_repository の下は除く）と、FPU リポジトリの src/ の下
proc project_sv_files {} {
    set src [file normalize [file join $::root_dir src]]
    set want {}
    foreach f [find_sv_files $src] {
        set f [file normalize $f]
        if {[string match -nocase "$src/ip/*" $f]} { continue }
        if {[regexp -nocase {_repository/} $f]} { continue }
        lappend want $f
    }
    set fpu [file join $src fpu fpu_repository src]
    if {[file isdirectory $fpu]} {
        foreach f [find_sv_files $fpu] { lappend want [file normalize $f] }
    } else {
        puts "WARNING: $fpu not found"
    }
    return $want
}

# プロジェクトの .sv を project_sv_files に合わせる。増えたものは追加し、無くなったものは外す
# （.xpr を作った後に足したファイルも、GUI で Add Sources しなくてよいように）
proc sync_sources {} {
    section "Sync sources"
    set src [file normalize [file join $::root_dir src]]
    set want [project_sv_files]

    set have {}
    foreach f [get_files -quiet -of_objects [get_filesets sources_1] -filter {FILE_TYPE == SystemVerilog}] {
        set f [file normalize $f]
        if {[string match -nocase "$src/*" $f]} { lappend have $f }
    }

    set added {}
    foreach f $want {
        if {[lsearch -exact -nocase $have $f] < 0} { lappend added $f }
    }
    set removed {}
    foreach f $have {
        if {[lsearch -exact -nocase $want $f] < 0} { lappend removed $f }
    }

    if {[llength $added] > 0} {
        add_files -fileset sources_1 -norecurse $added
        set_property file_type SystemVerilog [get_files $added]
    }
    if {[llength $removed] > 0} {
        remove_files -fileset sources_1 $removed
    }
    foreach f $added   { puts "  + [string range $f [expr {[string length $::root_dir] + 1}] end]" }
    foreach f $removed { puts "  - [string range $f [expr {[string length $::root_dir] + 1}] end]" }
    puts "sources: [llength $want] files (added [llength $added], removed [llength $removed])"
}

# ---------------------------------------------------------------
# プロジェクトの作成
# ---------------------------------------------------------------

# .xpr が無いときに、フォルダ名のプロジェクト（core.xpr）を作る。
# src/ の .sv（src/ip と *_repository の下は除く）、制約、clk_wiz_0、fib.mem を登録し、top を top にする
proc create_core_project {board_found} {
    set dir $::root_dir
    set name [file tail $dir]
    section "Create project $name.xpr"
    # .xpr が無いのに $name.runs などが残っていると作れないので、-force で古い結果ごと作り直す
    create_project -force $name $dir -part xc7a100tcsg324-1
    if {$board_found} {
        set_property board_part digilentinc.com:nexys-a7-100t:part0:1.3 [current_project]
    }
    set_property target_language Verilog [current_project]

    set src [file join $dir src]
    set files {}
    foreach f [find_sv_files $src] {
        set r [file normalize $f]
        if {[string match -nocase "[file normalize [file join $src ip]]/*" $r]} { continue }
        if {[regexp -nocase {_repository/} $r]} { continue }
        lappend files $r
    }
    add_files -fileset sources_1 -norecurse $files
    set_property file_type SystemVerilog [get_files $files]

    add_files -fileset sources_1 -norecurse [file join $src ip clk_wiz_0 clk_wiz_0.xci]

    set mem [file join $dir test fib.mem]
    if {[file exists $mem]} {
        add_files -fileset sources_1 -norecurse $mem
    } else {
        puts "WARNING: $mem not found, i_mem is not initialized"
    }

    add_files -fileset constrs_1 -norecurse [file join $src constraints Nexys-A7-100T-Master.xdc]

    set_property top top [get_filesets sources_1]
    update_compile_order -fileset sources_1
    puts "[llength $files] sources added"
    close_project
}

# ---------------------------------------------------------------
# ビルド
# ---------------------------------------------------------------
proc build_bitstream {force} {
    section "Build"
    update_compile_order -fileset sources_1

    prepare_ips

    set synth [get_runs synth_1]
    set impl  [get_runs impl_1]
    set bit   [bitfile_path]

    # 前回の結果が古いとき（ソースが変わった、未完了、clean 指定）だけやり直す
    set need_synth [expr {$force ||
                          [get_property NEEDS_REFRESH $synth] ||
                          [get_property PROGRESS $synth] ne "100%"}]
    set need_impl  [expr {$need_synth ||
                          [get_property NEEDS_REFRESH $impl] ||
                          [get_property PROGRESS $impl] ne "100%" ||
                          ![file exists $bit]}]

    if {!$need_impl} {
        puts "Up to date, skip build: $bit"
        return $bit
    }

    catch {reset_run $impl}
    if {$need_synth} { catch {reset_run $synth} }

    set jobs [cpu_count]
    puts "Launching synth/impl/write_bitstream (jobs = $jobs) ..."
    launch_runs $impl -to_step write_bitstream -jobs $jobs

    wait_on_run $synth
    if {[run_failed $synth]} {
        show_run_messages
        die "synthesis failed"
    }
    wait_on_run $impl
    if {[run_failed $impl] || ![file exists $bit]} {
        show_run_messages
        die "implementation / bitstream failed"
    }

    show_run_messages
    show_timing
    puts "Bitstream: $bit"
    return $bit
}

# ---------------------------------------------------------------
# バックエンドだけの合成（backend モード）
# ---------------------------------------------------------------

# backend_top を top にして out-of-context で合成・配置配線し、回路規模とタイミングを表示する。
# .xpr は使わず、ファイルを直接読む。ピン配置はしないのでボードには書き込めない
# ファイルを読んで、行コメント（// から行末）を消したものを返す
proc read_sv_text {f} {
    set fh [open $f r]
    fconfigure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    regsub -all -line {//.*$} $text {} text
    return $text
}

# モジュール単位のビルドで読むファイル。top から下の階層で使っているモジュールのファイルと、
# それらが使っている package（package が使っているものも）を、package を先に import の順で並べて返す。
# インスタンスは正規表現で拾う（launch/lint.py と同じやり方）。新しいファイルや package も勝手に入る
proc hierarchy_sv_files {top} {
    set defs  [dict create]
    set pkgs  [dict create]
    set texts [dict create]
    foreach f [project_sv_files] {
        set text [read_sv_text $f]
        dict set texts $f $text
        foreach {m name} [regexp -all -inline -lineanchor {^\s*module\s+(\w+)} $text] {
            dict set defs $name $f
        }
        if {[regexp -lineanchor {^\s*package\s+(\w+)\s*;} $text -> p]} {
            set deps {}
            foreach {m d} [regexp -all -inline {\m(\w+)::} $text] {
                if {$d ne $p} { lappend deps $d }
            }
            dict set pkgs $p [list $f [lsort -unique $deps]]
        }
    }
    if {![dict exists $defs $top]} { die "module $top not found in src/" }

    # top から下のモジュールをたどる
    set seen {}
    set files {}
    set stack [list $top]
    while {[llength $stack] > 0} {
        set name [lindex $stack end]
        set stack [lrange $stack 0 end-1]
        if {$name in $seen || ![dict exists $defs $name]} { continue }
        lappend seen $name
        set f [dict get $defs $name]
        if {$f ni $files} { lappend files $f }
        set text [dict get $texts $f]
        set body $text
        if {[regexp -lineanchor -indices "^\\s*module\\s+${name}\\M" $text pos]} {
            set e [string first endmodule $text [lindex $pos 1]]
            if {$e < 0} { set e end }
            set body [string range $text [lindex $pos 1] $e]
        }
        foreach {m inst} [regexp -all -inline -lineanchor {^\s*(\w+)\s*(?:#\s*\(|\w+\s*(?:\[[^\]]*\]\s*)?\()} $body] {
            if {[dict exists $defs $inst] && $inst ni $seen} { lappend stack $inst }
        }
    }

    # 使っている package
    set need {}
    set stack {}
    foreach f $files {
        foreach {m d} [regexp -all -inline {\m(\w+)::} [dict get $texts $f]] { lappend stack $d }
    }
    while {[llength $stack] > 0} {
        set p [lindex $stack end]
        set stack [lrange $stack 0 end-1]
        if {[dict exists $pkgs $p] && $p ni $need} {
            lappend need $p
            lappend stack {*}[lindex [dict get $pkgs $p] 1]
        }
    }

    # 使われる側を先に並べる
    set ordered {}
    set left $need
    while {[llength $left] > 0} {
        set progress 0
        foreach p $left {
            set ok 1
            foreach d [lindex [dict get $pkgs $p] 1] {
                if {$d in $need && $d ni $ordered} { set ok 0 }
            }
            if {$ok} {
                lappend ordered $p
                set left [lsearch -all -inline -not -exact $left $p]
                set progress 1
            }
        }
        if {!$progress} { die "package import loop: $left" }
    }

    set result {}
    foreach p $ordered { lappend result [lindex [dict get $pkgs $p] 0] }
    foreach f $files {
        if {$f ni $result} { lappend result $f }
    }
    puts "$top: [llength $files] module files, [llength $ordered] packages ([join $ordered {, }])"
    return $result
}

proc backend_out_dir {top} {
    return [file join $::root_dir timing [expr {$top eq "backend_top" ? "backend" : $top}]]
}

# モジュール単位の前回の結果（配線後と合成後のうち新しい方）を開き、どちらを開いたかを返す
# モジュール単位の前回の結果（配線後と合成後のうち新しい方）の .dcp を {パス 種類} で返す。無ければ空
proc newest_module_dcp {top} {
    set dir [backend_out_dir $top]
    set best {}
    set best_t -1
    foreach kind {routed synth} {
        set f [file join $dir ${top}_$kind.dcp]
        if {[file exists $f] && [file mtime $f] > $best_t} {
            set best [list $f $kind]
            set best_t [file mtime $f]
        }
    }
    return $best
}

proc open_module_result {top} {
    set r [newest_module_dcp $top]
    if {[llength $r] == 0} {
        die "no result in [backend_out_dir $top]  -> run: build.bat build $top"
    }
    lassign $r best best_kind
    puts "opening $best ([clock format [file mtime $best] -format {%Y-%m-%d %H:%M}])"
    open_checkpoint $best
    if {$best_kind eq "routed"} {
        return "$top, after place & route (out-of-context)"
    }
    return "$top, after synthesis - net delays are ESTIMATES"
}

# モジュール単位の前回の結果の、回路規模とタイミングの概要を表示する
proc show_module_status {top} {
    set stage [open_module_result $top]
    section "Utilization ($stage)"
    puts [report_utilization -hierarchical -hierarchical_depth 2 -return_string]
    section "Timing ($stage)"
    set clk [get_clocks -quiet clk]
    if {$clk eq ""} {
        puts "  no clock"
        return
    }
    set period [get_property PERIOD $clk]
    set p [get_timing_paths -quiet -delay_type max -max_paths 1]
    set h [get_timing_paths -quiet -delay_type min -max_paths 1]
    set wns [expr {$p eq "" ? "" : [get_property SLACK $p]}]
    set whs [expr {$h eq "" ? "" : [get_property SLACK $h]}]
    set fail [llength [get_timing_paths -quiet -delay_type max -max_paths 100000 -nworst 1 -slack_lesser_than 0]]
    puts [format "  period %.3f ns, WNS %s ns, WHS %s ns, failing endpoints %d" $period [fmt_ns $wns] [fmt_ns $whs] $fail]
    if {$wns ne ""} {
        puts [format "  Fmax(est) %.1f MHz" [expr {1000.0 / ($period - $wns)}]]
    }
}

# strategy の名前を確かめる。default は Vivado の既定の strategy
proc check_strategy {run name} {
    if {$name in {default Default}} {
        return [expr {[string match synth* [get_property NAME $run]] ? "Vivado Synthesis Defaults" : "Vivado Implementation Defaults"}]
    }
    set names [list_property_value strategy $run]
    if {$name ni $names} {
        error "unknown strategy for [get_property NAME $run]: $name\n  choose from: [join $names {, }]"
    }
    return $name
}

# 全体：synth_1 / impl_1 の strategy を設定する（指定が無ければ既定に戻す）。変わった run はやり直す
proc apply_project_strategies {impl synth} {
    foreach {run name} [list synth_1 $synth impl_1 $impl] {
        set r [get_runs $run]
        if {$name eq ""} { set name default }
        if {[catch {check_strategy $r $name} name]} { die $name }
        set old [get_property strategy $r]
        puts "$run strategy: $name"
        if {$old ne $name} {
            puts "  changed from: $old"
            set_property strategy $name $r
            catch {reset_run $r}
        }
    }
}

# モジュール単位：strategy の中身を仮のプロジェクトで Vivado から読み出し、
# {合成のオプション 配置配線のコマンドの列} にする。合成は既定と違うオプションだけを返す
proc strategy_flow {impl synth dir} {
    set steps {opt_design place_design phys_opt_design route_design}
    if {$impl eq "" && $synth eq ""} { return [list {} $steps] }

    set tmp [file join $dir strategy_tmp]
    create_project -force strategy_tmp $tmp -part xc7a100tcsg324-1
    if {[catch {read_strategies $impl $synth $steps} r]} {
        close_project
        file delete -force $tmp
        die $r
    }
    close_project
    file delete -force $tmp
    return $r
}

proc read_strategies {impl synth steps} {
    set sr [get_runs synth_1]
    set ir [get_runs impl_1]

    set synth_opts {}
    if {$synth ne ""} {
        set synth [check_strategy $sr $synth]
        set props [lsearch -all -inline -glob [list_property $sr] STEPS.SYNTH_DESIGN.ARGS.*]
        set base [dict create]
        foreach p $props { dict set base $p [get_property $p $sr] }
        set_property strategy $synth $sr
        foreach p $props {
            set v [get_property $p $sr]
            if {$v eq [dict get $base $p]} { continue }
            set key [lindex [split $p .] end]
            if {$key eq "MORE OPTIONS"} {
                lappend synth_opts {*}$v
            } elseif {$key in {KEEP_EQUIVALENT_REGISTERS NO_LC NO_SRLEXTRACT RETIMING ASSERT}} {
                if {$v} { lappend synth_opts -[string tolower $key] }
            } else {
                lappend synth_opts -[string tolower $key] $v
            }
        }
    }

    if {$impl ne ""} {
        set impl [check_strategy $ir $impl]
        set_property strategy $impl $ir
        set steps {}
        foreach {st cmd} {
            OPT_DESIGN opt_design POWER_OPT_DESIGN power_opt_design PLACE_DESIGN place_design
            POST_PLACE_POWER_OPT_DESIGN power_opt_design PHYS_OPT_DESIGN phys_opt_design
            ROUTE_DESIGN route_design POST_ROUTE_PHYS_OPT_DESIGN phys_opt_design
        } {
            # PLACE_DESIGN と ROUTE_DESIGN には IS_ENABLED が無い（いつも走る）
            if {![catch {get_property STEPS.$st.IS_ENABLED $ir} en] && $en eq "0"} { continue }
            set c [list $cmd]
            if {![catch {get_property STEPS.$st.ARGS.DIRECTIVE $ir} d] && $d ne ""} { lappend c -directive $d }
            if {![catch {get_property "STEPS.$st.ARGS.MORE OPTIONS" $ir} m]} { lappend c {*}$m }
            lappend steps $c
        }
    }
    return [list $synth_opts $steps]
}

proc synth_backend {n period top synth_only impl_strategy synth_strategy} {
    set part xc7a100tcsg324-1
    set src [file join $::root_dir src]
    set out [backend_out_dir $top]
    file mkdir $out
    lassign [strategy_flow $impl_strategy $synth_strategy $out] synth_opts steps
    if {$synth_strategy ne ""} { puts "synthesis strategy: $synth_strategy -> $synth_opts" }
    if {$impl_strategy ne ""} { puts "implementation strategy: $impl_strategy -> [join $steps {; }]" }
    set t0 [clock seconds]

    # top から下の階層のファイルと、それが使っている package（使われる側が先）を毎回集める
    set files [hierarchy_sv_files $top]

    section "Synthesize $top ([llength $files] files)"
    read_verilog -sv $files
    if {[catch {synth_design -top $top -part $part -mode out_of_context {*}$synth_opts} err]} {
        die "synthesis failed: $err"
    }
    puts "synthesis: [expr {[clock seconds] - $t0}] s"
    if {[llength [get_ports -quiet clk]] == 0} { die "$top has no port named clk" }

    # ポートの外は遅延 0 とみなして、入力から FF、FF から出力のパスも見る
    create_clock -name clk -period $period [get_ports clk]
    set ins [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_input_delay  -clock clk 0 $ins
    set outs [get_ports -filter {DIRECTION == OUT}]
    set_output_delay -clock clk 0 $outs
    # ポートの hold は外の回路が無いと意味が無い（クロックの遅延ぶん必ず違反に見える）ので見ない
    set_false_path -hold -from $ins
    set_false_path -hold -to $outs

    # クロックは外の BUFG から来るものとして扱う（指定しないと普通の配線で引かれて skew が大きく出る）
    set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]

    file mkdir $out
    write_checkpoint -force [file join $out ${top}_synth.dcp]

    # synth を付けたときは合成で止める（配線遅延は見積もり。段数を見るだけならこれで足りる）
    if {$synth_only} {
        report_utilization -file [file join $out utilization.rpt]
        report_utilization -hierarchical -file [file join $out utilization_hier.rpt]
        section "Utilization (after synthesis)"
        puts [report_utilization -hierarchical -hierarchical_depth 2 -return_string]
        report_critical_paths $n "$top, after synthesis - net delays are ESTIMATES" $out
        report_path_groups $out
        return
    }

    # route_design は tight_setup_hold_pins.txt をカレントディレクトリに出すので、出力先に移っておく
    section "Place & route $top"
    set t1 [clock seconds]
    set cwd [pwd]
    cd $out
    foreach step $steps {
        puts "> $step"
        if {[catch {{*}$step} err]} {
            cd $cwd
            die "[lindex $step 0] failed: $err"
        }
    }
    cd $cwd
    puts "place & route: [expr {[clock seconds] - $t1}] s"
    write_checkpoint -force [file join $out ${top}_routed.dcp]
    report_utilization -file [file join $out utilization.rpt]
    report_utilization -hierarchical -file [file join $out utilization_hier.rpt]

    section "Utilization (after place & route)"
    puts [report_utilization -hierarchical -hierarchical_depth 2 -return_string]
    puts "full reports: [file join $out utilization.rpt], [file join $out utilization_hier.rpt]"

    write_placement_svg [file join $out placement.svg]

    report_critical_paths $n "$top, after place & route (out-of-context)" $out
    report_path_groups $out
}

# ピンの名前から添字とセルの種類を落として、同じ FF の束を 1 つにまとめる
proc path_group_name {pin} {
    set n [get_property NAME $pin]
    regsub {/[A-Za-z0-9]+$} $n {} n
    regsub -all {\[[0-9]+\]} $n {[*]} n
    regsub -all {_rep(lica)?(__?[0-9]+)?} $n {} n
    regsub -all {_reg} $n {} n
    regsub {g_lvt.*$} $n {lutram} n
    regsub {payload_ram.*$} $n {payload_ram} n
    return $n
}

# 違反しているパスを「始点の束 -> 終点の束」でまとめ、悪い順に表示する（全部は groups.rpt）。
# 違反が無ければワースト 2000 本で同じことをする
proc report_path_groups {dir} {
    set paths [get_timing_paths -quiet -delay_type max -max_paths 30000 -nworst 1 -slack_lesser_than 0]
    set what "failing endpoints"
    if {[llength $paths] == 0} {
        set paths [get_timing_paths -quiet -delay_type max -max_paths 2000 -nworst 1]
        set what "worst endpoints (no violation)"
    }
    set g [dict create]
    foreach p $paths {
        set k "[path_group_name [get_property STARTPOINT_PIN $p]] -> [path_group_name [get_property ENDPOINT_PIN $p]]"
        set s [get_property SLACK $p]
        set l [get_property LOGIC_LEVELS $p]
        if {![dict exists $g $k]} {
            dict set g $k [list $s 1 $l]
        } else {
            lassign [dict get $g $k] ws c ml
            dict set g $k [list [expr {$s < $ws ? $s : $ws}] [expr {$c + 1}] [expr {$l > $ml ? $l : $ml}]]
        }
    }
    set rows {}
    dict for {k v} $g { lappend rows [list [lindex $v 0] [lindex $v 1] [lindex $v 2] $k] }
    set rows [lsort -real -index 0 $rows]

    set file [file join $dir groups.rpt]
    set fh [open $file w]
    puts $fh "# [llength $paths] $what, [llength $rows] groups"
    puts $fh "#  slack  endpoints  levels  startpoint -> endpoint"
    foreach r $rows { puts $fh [format "%7.3f  %5d  %2d  %s" {*}$r] }
    close $fh

    section "Path groups ([llength $paths] $what, [llength $rows] groups)"
    puts "    slack  endpoints  levels  startpoint -> endpoint"
    foreach r [lrange $rows 0 29] { puts [format "  %7.3f  %5d  %2d  %s" {*}$r] }
    puts "all groups: $file"
}

# 配置の結果を SVG の図にする。Vivado の Device 画面と同じタイルの並び（GRID_POINT）で、
# 列の幅はタイルの種類に合わせて変える（CLB / BRAM / DSP は太く、配線の INT は細く、区切りの列はもっと細く）。
# 黒い背景に、使っている LUT / FF / CARRY などをモジュール（top の直下の階層）ごとの色で塗る。配線は描かない
proc write_placement_svg {file} {
    set palette {#ff5a5a #4fe05a #4f9dff #f2e94e #ff6bff #3fe0e0 #ffa040 #b38cff #c8c8c8 #ff9eb5}

    # セルの置き場所。サイト -> {{持ち主 部品} ...}
    set cells [get_cells -hier -quiet -filter {IS_PRIMITIVE}]
    set used [dict create]
    set owners {}
    foreach name [get_property NAME $cells] loc [get_property LOC $cells] bel [get_property BEL $cells] {
        if {$loc eq ""} { continue }
        set i [string first "/" $name]
        set owner [expr {$i < 0 ? "(top)" : [string range $name 0 [expr {$i - 1}]]}]
        if {$owner ni $owners} { lappend owners $owner }
        set part [lindex [split $bel .] end]
        if {[regexp {^([A-D])(6LUT|5LUT)$} $part -> letter]} {
            set kind "L$letter"
        } elseif {[regexp {^([A-D])(5?FF)$} $part -> letter]} {
            set kind "F$letter"
        } elseif {$part eq "CARRY4" || [regexp {MUX} $part]} {
            set kind C
        } else {
            set kind W
        }
        dict lappend used $loc [list $owner $kind]
    }
    set owners [lsort $owners]
    set colors [dict create]
    set i 0
    foreach o $owners {
        dict set colors $o [lindex $palette [expr {$i % [llength $palette]}]]
        incr i
    }

    # 列の幅と行の高さ。列はそこにあるタイルの種類で、行は CLB や INT がある行だけ普通の高さ
    set all [get_tiles]
    array set colw {}
    array set rowh {}
    foreach type [get_property TYPE $all] gx [get_property GRID_POINT_X $all] gy [get_property GRID_POINT_Y $all] {
        switch -glob -- $type {
            CLBL* - BRAM_? - DSP_? { set w 14 }
            *IOB33* { set w 9 }
            *IOI3 { set w 6 }
            INT_? { set w 5 }
            *INTERFACE* { set w 2 }
            default { set w 1 }
        }
        if {![info exists colw($gx)] || $w > $colw($gx)} { set colw($gx) $w }
        set h [expr {[string match INT_? $type] || [string match CLBL* $type] || [string match *IOB33* $type] ? 10 : 3}]
        if {![info exists rowh($gy)] || $h > $rowh($gy)} { set rowh($gy) $h }
    }
    array set xpos {}
    set x 0
    foreach gx [lsort -integer [array names colw]] { set xpos($gx) $x; set x [expr {$x + $colw($gx)}] }
    set gw $x
    array set ypos {}
    set y 0
    foreach gy [lsort -integer [array names rowh]] { set ypos($gy) $y; set y [expr {$y + $rowh($gy)}] }
    set gh $y

    set body {}
    set nslice 0
    set nslice_used 0
    set slices_of [dict create]

    # 配線の INT タイル（小さい箱だけ）
    set ints [get_tiles -filter {TYPE == INT_L || TYPE == INT_R}]
    foreach gx [get_property GRID_POINT_X $ints] gy [get_property GRID_POINT_Y $ints] {
        lappend body [format {<rect class="i" x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>} \
                          [expr {$xpos($gx) + 0.8}] [expr {$ypos($gy) + 1.5}] [expr {$colw($gx) - 1.6}] [expr {$rowh($gy) - 3}]]
    }

    set tiles [get_tiles -filter {TYPE =~ CLBL* || TYPE =~ BRAM_? || TYPE =~ DSP_? || TYPE =~ *IOB33*}]
    foreach t $tiles type [get_property TYPE $tiles] gx [get_property GRID_POINT_X $tiles] gy [get_property GRID_POINT_Y $tiles] {
        set x0 $xpos($gx)
        set cw $colw($gx)
        set sites [lsort -dictionary [get_property NAME [get_sites -quiet -of_objects $t]]]
        switch -glob -- $type {
            CLBL* {
                # スライスは左右に 2 つ（X の小さい方が左）
                set k 0
                foreach s $sites {
                    incr nslice
                    set sw [expr {$cw / 2.0 - 1.2}]
                    set sh [expr {$rowh($gy) - 1.2}]
                    set sx [expr {$x0 + 0.6 + $k * $cw / 2.0}]
                    set sy [expr {$ypos($gy) + 0.6}]
                    lappend body [format {<rect class="s" x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>} $sx $sy $sw $sh]
                    if {[dict exists $used $s]} {
                        incr nslice_used
                        set mine {}
                        set rh4 [expr {$sh / 4.0}]
                        foreach u [dict get $used $s] {
                            lassign $u owner kind
                            if {$owner ni $mine} {
                                lappend mine $owner
                                dict incr slices_of $owner
                            }
                            set col [dict get $colors $owner]
                            # 部品の位置：A が下、D が上。LUT が左、FF が真ん中、CARRY4 と MUX は右端の細い帯
                            switch -glob -- $kind {
                                L? - F? {
                                    set r [string first [string index $kind 1] ABCD]
                                    set by [expr {$sy + (3 - $r) * $rh4 + 0.15}]
                                    if {[string index $kind 0] eq "L"} {
                                        set bx [expr {$sx + 0.3}]
                                        set bw [expr {$sw * 0.45}]
                                    } else {
                                        set bx [expr {$sx + $sw * 0.55}]
                                        set bw [expr {$sw * 0.25}]
                                    }
                                    lappend body [format {<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s"/>} $bx $by $bw [expr {$rh4 - 0.3}] $col]
                                }
                                C {
                                    lappend body [format {<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s"/>} [expr {$sx + $sw * 0.85}] [expr {$sy + 0.15}] [expr {$sw * 0.12}] [expr {$sh - 0.3}] $col]
                                }
                                default {
                                    lappend body [format {<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s" opacity="0.6"/>} $sx $sy $sw $sh $col]
                                }
                            }
                        }
                    }
                    incr k
                }
            }
            BRAM_? - DSP_? {
                # 5 行分の高さ。RAMB18 / DSP48 は Y の偶数が下半分、奇数が上半分。RAMB36 は全体
                set top [expr {$ypos([expr {$gy - 4}]) + 0.6}]
                set h [expr {$ypos($gy) + $rowh($gy) - $top - 0.6}]
                set bx [expr {$x0 + 0.8}]
                set bw [expr {$cw - 1.6}]
                lappend body [format {<rect class="b" x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>} $bx $top $bw $h]
                foreach s $sites {
                    if {![dict exists $used $s]} { continue }
                    set col [dict get $colors [lindex [lindex [dict get $used $s] 0] 0]]
                    if {[regexp {^(RAMB18|DSP48)_X\d+Y(\d+)$} $s -> kind yy]} {
                        set hy [expr {$yy % 2 ? $top : $top + $h / 2.0}]
                        lappend body [format {<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>} [expr {$bx + 1}] [expr {$hy + 1}] [expr {$bw - 2}] [expr {$h / 2.0 - 2}] $col]
                    } else {
                        lappend body [format {<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>} [expr {$bx + 1}] [expr {$top + 1}] [expr {$bw - 2}] [expr {$h - 2}] $col]
                    }
                }
            }
            default {
                # I/O。サイトごとに 1 行（Y の大きい方が上）
                set n [llength $sites]
                set k 0
                foreach s [lsort -dictionary -decreasing $sites] {
                    set ry [expr {$gy - $n + 1 + $k}]
                    if {![info exists ypos($ry)]} { set ry $gy }
                    set cls [expr {[dict exists $used $s] ? "iou" : "io"}]
                    lappend body [format {<rect class="%s" x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>} $cls [expr {$x0 + 1.5}] [expr {$ypos($ry) + 1.5}] [expr {$cw - 3}] [expr {$rowh($ry) - 3}]]
                    incr k
                }
            }
        }
    }

    # クロック領域の境界と名前
    foreach cr [get_clock_regions] {
        set tl [get_tiles [get_property TOP_LEFT_TILE $cr]]
        set br [get_tiles [get_property BOTTOM_RIGHT_TILE $cr]]
        set tx [get_property GRID_POINT_X $tl]
        set ty [get_property GRID_POINT_Y $tl]
        set bx [get_property GRID_POINT_X $br]
        set by [get_property GRID_POINT_Y $br]
        set x1 $xpos($tx)
        set y1 $ypos($ty)
        set x2 [expr {$xpos($bx) + $colw($bx)}]
        set y2 [expr {$ypos($by) + $rowh($by)}]
        lappend body [format {<rect class="cr" x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>} $x1 $y1 [expr {$x2 - $x1}] [expr {$y2 - $y1}]]
        lappend body [format {<text class="crl" x="%.1f" y="%.1f">%s</text>} [expr {$x1 + 6}] [expr {$y1 + 18}] $cr]
    }

    set lw 300
    set w [expr {$gw + $lw}]
    set h [expr {$gh + 40}]

    set fh [open $file w]
    fconfigure $fh -encoding utf-8
    puts $fh "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$w\" height=\"$h\" viewBox=\"0 0 $w $h\">"
    puts $fh {<style>
text{font-family:Segoe UI,Arial,sans-serif}
.s{fill:#161616;stroke:#3c3c3c;stroke-width:.4}
.i{fill:#0b0b0b;stroke:#262626;stroke-width:.3}
.b{fill:#10161c;stroke:#3b4b5b;stroke-width:.6}
.io{fill:#1a1a1a;stroke:#4a4a4a;stroke-width:.5}
.iou{fill:#d0d0d0;stroke:#ffffff;stroke-width:.5}
.cr{fill:none;stroke:#8a8a8a;stroke-width:1.2;stroke-dasharray:8 5}
.crl{fill:#9a9a9a;font-size:16px}
.lg{fill:#e0e0e0;font-size:15px}
.tt{fill:#ffffff;font-size:17px}
</style>}
    puts $fh "<rect width=\"100%\" height=\"100%\" fill=\"#000000\"/>"
    puts $fh "<g transform=\"translate(0,30)\">"
    puts $fh [join $body "\n"]
    puts $fh "</g>"
    puts $fh [format {<text class="tt" x="8" y="21">%s: %d / %d slices used (%.1f%%)</text>} \
                  [get_property TOP [current_design]] $nslice_used $nslice \
                  [expr {$nslice > 0 ? 100.0 * $nslice_used / $nslice : 0}]]
    set lx [expr {$gw + 20}]
    set ly 60
    foreach o $owners {
        set k [expr {[dict exists $slices_of $o] ? [dict get $slices_of $o] : 0}]
        puts $fh "<rect x=\"$lx\" y=\"[expr {$ly - 13}]\" width=\"16\" height=\"16\" fill=\"[dict get $colors $o]\"/>"
        puts $fh "<text class=\"lg\" x=\"[expr {$lx + 24}]\" y=\"$ly\">$o ($k slices)</text>"
        incr ly 24
    }
    puts $fh "</svg>"
    close $fh
    puts "placement figure: $file"
}

# プロジェクトの合成（synth_1）だけをする。前回から変わっていなければ飛ばす
proc build_synth {force} {
    section "Synthesize (synth_1)"
    update_compile_order -fileset sources_1
    prepare_ips

    set synth [get_runs synth_1]
    if {!$force && ![get_property NEEDS_REFRESH $synth] && [get_property PROGRESS $synth] eq "100%"} {
        puts "Up to date, skip synthesis"
        return
    }
    catch {reset_run $synth}
    launch_runs $synth -jobs [cpu_count]
    wait_on_run $synth
    if {[run_failed $synth]} {
        show_run_messages
        die "synthesis failed"
    }
    show_run_messages
}

# ---------------------------------------------------------------
# ボードへの書き込み
# ---------------------------------------------------------------
proc program_device {bit} {
    section "Program"
    if {![file exists $bit]} {
        die "bitstream not found: $bit  (run with 'build' first)"
    }

    if {[catch {open_hw_manager}]} { open_hw }
    if {[catch {connect_hw_server -allow_non_jtag}]} { connect_hw_server }

    set targets [get_hw_targets -quiet]
    if {[llength $targets] == 0} {
        die "no board found - check USB cable / power switch / driver"
    }
    current_hw_target [lindex $targets 0]
    open_hw_target

    set dev [lindex [get_hw_devices -quiet xc7a*] 0]
    if {$dev eq ""} { set dev [lindex [get_hw_devices] 0] }
    current_hw_device $dev
    refresh_hw_device -update_hw_probes false $dev

    # ILA などのデバッグコア用のプローブファイルがあれば一緒に設定する
    set ltx "[file rootname $bit].ltx"
    if {[file exists $ltx]} {
        set_property PROBES.FILE      $ltx $dev
        set_property FULL_PROBES.FILE $ltx $dev
    } else {
        set_property PROBES.FILE      {} $dev
        set_property FULL_PROBES.FILE {} $dev
    }
    set_property PROGRAM.FILE $bit $dev

    puts "Programming $dev with $bit ..."
    if {[catch {program_hw_devices $dev} err]} {
        die "program_hw_devices failed: $err"
    }

    close_hw_target
    disconnect_hw_server
    catch {close_hw_manager}
    puts "Done."
}

# ---------------------------------------------------------------
# メイン
# ---------------------------------------------------------------
set mode  ""
set force 0
set npaths 10
set period 12.5
set period_given 0
set synth_only 0
set gui 0
set impl_strategy ""
set synth_strategy ""
set names {}
set usage "(\[all|build|program|errors|status|timing|ip|view\] \[top|backend|<module>\] \[synth\] \[N\] \[100mhz|10ns\] \[clean\] \[strategy:<name>\] \[synth_strategy:<name>\])"
foreach a $argv {
    switch -- $a {
        all - build - program - errors - status - timing - ip - view - open {
            if {$mode ne ""} { die "two modes: $mode and $a  $usage" }
            set mode $a
        }
        backend { lappend names backend_top }
        clean   { set force 1 }
        synth   { set synth_only 1 }
        gui     { set gui 1 }
        default {
            if {[regexp {^strategy:(\w+)$} $a -> s]} {
                set impl_strategy $s
            } elseif {[regexp {^synth_strategy:(\w+)$} $a -> s]} {
                set synth_strategy $s
            } elseif {[string is integer -strict $a] && $a > 0} {
                set npaths $a
            } elseif {[regexp -nocase {^([0-9]+\.?[0-9]*)(mhz|ns)$} $a -> v unit] && $v > 0} {
                set period [expr {[string tolower $unit] eq "ns" ? double($v) : 1000.0 / $v}]
                set period_given 1
            } elseif {[regexp {^[a-z][a-z0-9_]*$} $a]} {
                lappend names $a
            } else {
                die "unknown argument: $a  $usage"
            }
        }
    }
}
if {[llength $names] > 1} {
    die "two targets: $names  $usage"
}

# 対象：名前が無いか top なら全体（.xpr のプロジェクト）、backend なら backend_top、
# それ以外はそのモジュールだけを out-of-context で（.xpr は使わない。結果は timing/<名前>/）
set target [expr {[llength $names] == 1 ? [lindex $names 0] : "top"}]
set whole  [expr {$target eq "top"}]

# open（ビルドせずに前回の結果を GUI で開く）は launch/run.bat が GUI で起動したときだけ。中身は view の GUI 側と同じ
if {$mode eq "open"} {
    if {!$gui} { die "'open' is started by launch/run.bat in the GUI" }
    set mode view
}

# モードを書かなければ、全体は all（ビルドして書き込む）、モジュールは build
if {$mode eq ""} { set mode [expr {$whole ? "all" : "build"}] }

if {!$whole && $mode in {all program ip errors}} {
    die "'$mode' is only for the whole design (got target: $target)"
}
if {$synth_only && $mode in {all program}} {
    die "'synth' can't be used with '$mode' (it needs a bitstream)"
}
if {$whole && $period_given} {
    puts "WARNING: the clock of the whole design is set by clk_wiz_0, ignore [format %.3f $period] ns"
}

# ---------------------------------------------------------------
# モジュール単位（.xpr を使わない）
# ---------------------------------------------------------------
if {!$whole} {
    # view を gui 付きで呼ぶのは build.bat だけ（ビルドが通った後に GUI で起動する）。
    # 結果のチェックポイントを開いて終わる。GUI が閉じないよう exit は使わない
    # 配線後と合成後のうち新しい方を開く（view ならさっき作った方）
    if {$mode eq "view" && $gui} {
        set r [newest_module_dcp $target]
        if {[llength $r] == 0} {
            puts "*** no result in [backend_out_dir $target]"
        } else {
            open_checkpoint [lindex $r 0]
        }
        return
    }
    switch -- $mode {
        build - view {
            fetch_fpu_repo
            synth_backend $npaths $period $target $synth_only $impl_strategy $synth_strategy
        }
        timing {
            set stage [open_module_result $target]
            set dir [backend_out_dir $target]
            report_critical_paths $npaths $stage $dir
            report_path_groups $dir
        }
        status { show_module_status $target }
    }
    exit 0
}

# ---------------------------------------------------------------
# 全体（.xpr のプロジェクト）
# ---------------------------------------------------------------

# リポジトリ直下の .xpr を開く。無ければ作る
# バッチ起動時にも Nexys A7 のボード定義を登録する。
# 候補を上から順に見て、最初に見つかったフォルダを使う（PC ごとに置き場所が違うため）
set board_repo_candidates [list \
    C:/Users/n1rat/vivado-boards/new/board_files \
    C:/Users/dito0/FPGA/vivado-boards-master/new/board_files \
]
set board_repo ""
foreach d $board_repo_candidates {
    if {[file isdirectory $d]} { set board_repo $d; break }
}
if {$board_repo ne ""} {
    puts "board files: $board_repo"
    set_param board.repoPaths [list $board_repo]
} else {
    puts "WARNING: board files not found in: [join $board_repo_candidates {, }]"
}
set fetch [expr {$mode in {all build} || ($mode eq "view" && !$gui)}]
if {$fetch} {
    fetch_memory_repo
    fetch_fpu_repo
}
set xprs [glob -nocomplain -directory $root_dir *.xpr]
if {[llength $xprs] == 0} {
    create_core_project [expr {$board_repo ne ""}]
    set xprs [glob -nocomplain -directory $root_dir *.xpr]
}
if {[llength $xprs] != 1} {
    die "expected exactly one .xpr in $root_dir (found [llength $xprs])"
}
open_project [lindex $xprs 0]
if {$fetch} {
    sync_sources
    apply_project_strategies $impl_strategy $synth_strategy
}

# view を GUI で開くときは、結果のランを開いて終わる（GUI が閉じないよう exit しない）
if {$mode eq "view" && $gui} {
    # 配置配線が終わっていればその結果、無ければ合成の結果（synth を付けたら合成の結果）
    set run synth_1
    set impl [get_runs impl_1]
    if {!$synth_only && [get_property PROGRESS $impl] eq "100%" && ![run_failed $impl]} {
        set run impl_1
    }
    if {[get_property PROGRESS [get_runs $run]] eq "100%" && ![run_failed [get_runs $run]]} {
        open_run $run
    } else {
        puts "*** $run is not finished"
    }
    return
}

set rc 0
switch -- $mode {
    all     { program_device [build_bitstream $force] }
    build - view {
        if {$synth_only} { build_synth $force } else { build_bitstream $force }
    }
    program { program_device [bitfile_path] }
    errors  { set rc [expr {[show_run_messages] > 0}]; show_timing }
    status  { show_status; show_timing }
    timing  { show_critical_paths $npaths }
    ip      { fix_ips }
}

close_project
exit $rc
