# launch/boot.tcl - Vivado reads a -source file in the Windows code page, which breaks the
# Japanese comments in flow.tcl. Read flow.tcl again as UTF-8. Keep this file ASCII only.
source -encoding utf-8 [file join [file dirname [file normalize [info script]]] flow.tcl]
