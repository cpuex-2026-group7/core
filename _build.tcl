# _build.tcl - Vivado を GUI なしで動かすスクリプト
#
# .xpr と同じフォルダに置き、そのフォルダで実行する（普通は build.bat から呼ぶ）:
#   vivado -mode batch -nojournal -notrace -source _build.tcl -tclargs [モード] [clean]
#
# モード:
#   all      （既定）必要ならビットストリームを作り、ボードに書き込む
#   build    ビットストリームを作るだけ
#   program  今あるビットストリームをボードに書き込むだけ
#   errors   前回の実行の ERROR と CRITICAL WARNING を表示（ビルドはしない）
#   status   各ランの状態とタイミングの概要を表示
#   timing   前回の結果からクリティカルパスを分析して表示（ビルドはしない）
#            配置配線が終わっていればその結果、無ければ合成の結果を使う
#            timing 20 のように数を付けるとワースト 20 本（既定 10 本）
#   ip       IP の状態を表示し、ロックされた IP を更新して、出力ファイルを作り直す
# clean      合成と配置配線を強制的にやり直す
#
# 終了コード: 0 = 成功、1 = 失敗（シェルスクリプトから判定に使える）

set script_dir [file dirname [file normalize [info script]]]

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

    # Vivado の詳しいレポートは timing/ に保存する
    set dir [file join $::script_dir timing]
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
    puts "\nfull reports: timing/summary.rpt, timing/paths.rpt"
}

# ---------------------------------------------------------------
# IP（clk_wiz_0 など）
# ---------------------------------------------------------------

# IP の状態（ロックされているか、その理由）を表示する
proc show_ip_status {} {
    set f [file join $::script_dir ip_status.rpt]
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
    puts "IP OK. now run: build.bat build"
}

# ---------------------------------------------------------------
# ビルド
# ---------------------------------------------------------------
proc build_bitstream {force} {
    section "Build"
    update_compile_order -fileset sources_1

    # ロックされた IP があれば理由を表示して止まる（直すのは ip モード）
    set locked [get_ips -quiet -filter {IS_LOCKED == 1}]
    if {[llength $locked] > 0} {
        show_ip_status
        die "locked IP: $locked  -> run: build.bat ip"
    }
    # IP の出力ファイルが無い、または古いときに備えて作り直しておく
    regenerate_ips

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
set mode  "all"
set force 0
set npaths 10
foreach a $argv {
    switch -- $a {
        all - build - program - errors - status - timing - ip { set mode $a }
        clean   { set force 1 }
        default {
            if {[string is integer -strict $a] && $a > 0} {
                set npaths $a
            } else {
                die "unknown argument: $a  (all|build|program|errors|status|timing \[N\]|ip \[clean\])"
            }
        }
    }
}

# このスクリプトと同じフォルダにある .xpr を開く
set xprs [glob -nocomplain -directory $script_dir *.xpr]
if {[llength $xprs] != 1} {
    die "expected exactly one .xpr in $script_dir (found [llength $xprs])"
}
# バッチ起動時にも Nexys A7 のボード定義を登録する。
set_param board.repoPaths [list C:/Users/n1rat/vivado-boards/new/board_files]
open_project [lindex $xprs 0]

set rc 0
switch -- $mode {
    all     { program_device [build_bitstream $force] }
    build   { build_bitstream $force }
    program { program_device [bitfile_path] }
    errors  { set rc [expr {[show_run_messages] > 0}]; show_timing }
    status  { show_status; show_timing }
    timing  { show_critical_paths $npaths }
    ip      { fix_ips }
}

close_project
exit $rc
