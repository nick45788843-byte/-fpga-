# This is default flow script for normal condition: neither syn ip flow nor multi-seed mode.
# Noted that only script in editable zone can be changed. 

if { ![info exists alRun] } { source ./settings.cfg }
proc step_begin { step } {
  set stopFile ".stop.f"
  if {[file isfile .stop.f]} {
    puts ""
    puts " #Halting run"
    puts ""
    return -code error
  }
  set beginFile ".$step.begin.f"
  set platform "$::tcl_platform(platform)"
  set user "$::tcl_platform(user)"
  set pid [pid]
  set host ""
  if { [string equal $platform unix] } {
    if { [info exists ::env(HOSTNAME)] } {
      set host $::env(HOSTNAME)
    }
  } else {
    if { [info exists ::env(COMPUTERNAME)] } {
      set host $::env(COMPUTERNAME)
    }
  }
  set ch [open $beginFile w]
  puts $ch "<?xml version=\"1.0\"?>"
  puts $ch "<ProcessHandle Version=\"1\" Minor=\"0\">"
  puts $ch "    <Process Ownner=\"$user\" Host=\"$host\" Pid=\"$pid\">"
  puts $ch "    </Process>"
  puts $ch "</ProcessHandle>"
  close $ch
}
proc step_end { step } {
  set endFile ".$step.end.f"
  set ch [open $endFile w]
  close $ch
}
proc step_error { step } {
  set errorFile ".$step.error.f"
  set ch [open $errorFile w]
  close $ch
}
set stepList {read_design opt_rtl opt_gate opt_place opt_route bitgen}
set l [lsearch $stepList $start_step]
set r [lsearch $stepList $end_step]
proc prepare { step } {
  upvar device_name device_name
  upvar package_name package_name
  upvar speed speed
  upvar prj_name prj_name
  upvar parent parent
  upvar synWildParams synWildParams
  upvar phyWildParams phyWildParams
  upvar alRun alRun
  upvar singleRun singleRun
  upvar sp sp
  upvar ADCList ADCList
  upvar SDCList SDCList
  set command "import_device $device_name -package $package_name"; if { [info exists speed] } { append command " -speed ${speed}" }; eval $command
  if { ![info exists singleRun] } {
    if { [info exists alRun] } { 
        open_project ${prj_name}.al -single_run
        load_run_param -run ${alRun}
    } else {
    set command "open_project {${prj_name}.prj}"; if { $step != 0 } { append command " -noanalyze" }; eval $command
    }
  }
  set preSteps {non elaborate rtl gate place pr}
  set preStep [ lindex ${preSteps} $step ]
  if { $step == 3 } { import_db $parent/${prj_name}_${preStep}.db }\
  elseif { $step != 0 } { import_db ${prj_name}_${preStep}.db }
  set wildParams ""
  if { [info exists synWildParams] } { set wildParams ${synWildParams} } elseif { [info exists phyWildParams] } { set wildParams ${phyWildParams} }
  for { set i 0 } { $i < [llength $wildParams] } { incr i 3 } {
    set_param [lindex $wildParams $i] [lindex $wildParams [expr $i + 1]] [lindex $wildParams [expr $i + 2]]
  }
  if { [info exists singleRun] } report_param
  if { [info exists sp] } {
    if { [info exists ADCList] } { foreach adc $ADCList { read_adc $adc } }
    if { [info exists SDCList] } {
      clear_sdc -user
      foreach sdc $SDCList { read_sdc $sdc }
    }
  }
}
proc read_design_fun {} {
  upvar prj_name prj_name
  upvar top_model_name top_model_name
  upvar singleRun singleRun
  upvar ADCList ADCList
  upvar IpADCList IpADCList
  upvar SDCList SDCList
  upvar IpSDCList IpSDCList
  if { ![info exists singleRun] } { commit_param -step design }

### Editable zone for read_design ###
  elaborate -top $top_model_name
#####################################
  if { [info exists ADCList] } { foreach adc $ADCList { read_adc $adc } }
  if { [info exists IpADCList] } {
    set i 0
    while {$i < [llength $IpADCList]} {
      read_ip_adc -ip [lindex $IpADCList $i] -file [lindex $IpADCList [expr $i + 1] ]
      incr i 2
    }
  }
  if { [info exists SDCList] } { foreach sdc $SDCList { read_sdc $sdc } }
  if { [info exists IpSDCList] } {
    set i 0
    while {$i < [llength $IpSDCList]} {
      read_sdc -ip [lindex $IpSDCList $i] [lindex $IpSDCList [expr $i + 1] ]
      incr i 2
    }
  }
  export_db ${prj_name}_elaborate.db
}
proc opt_rtl_fun {} {
  upvar prj_name prj_name
  upvar singleRun singleRun
  if { ![info exists singleRun] } { commit_param -step rtl }


### Editable zone for opt_rtl ###
  upvar chipDebugger chipDebugger
  if { ![info exists chipDebugger] } {
     insert_debugger
  } else { insert_debugger $chipDebugger }
  optimize_rtl
  report_area -file ${prj_name}_rtl.area
#################################

  export_db ${prj_name}_rtl.db
}
proc opt_gate_fun {} {
  upvar prj_name prj_name
  upvar area_option area_option
  upvar singleRun singleRun
  if { ![info exists singleRun] } { commit_param -step gate }

### Editable zone for opt_gate ###
  optimize_gate ${area_option} ${prj_name}_gate.area
  legalize_phy_inst
  update_timing
  report_timing_status -file ${prj_name}_gate.ts
  report_timing_summary -file ${prj_name}_gate.timing
  flow_status -file flow.status
##################################

  export_db ${prj_name}_gate.db
}
proc opt_place_fun {} {
  upvar prj_name prj_name
  upvar cwcList cwcList
  upvar singleRun singleRun
  upvar chipDebugger chipDebugger
  upvar bkaADCList bkaADCList
  upvar arr_filter arr_filter
  upvar arr_pwns arr_pwns
  upvar arr_cong arr_cong
  if { ![info exists singleRun] } { commit_param -step place }
  if { ![info exists chipDebugger] } {
     insert_debugger
  } else { insert_debugger $chipDebugger }
  if { [info exists bkaADCList] } { 
     clear_inst_adc
     foreach adc $bkaADCList { read_adc $adc } 
  }

### Editable zone for opt_place ###

clear_inst_adc
foreach adc $::ADCList {read_adc $adc}
puts A96_OPTIONAL_BRAM_ANCHORS_RELEASED

  place

report_cells -bram -mode manhattan -file actual_selected_macro_locations.adc -export_adc
set anchor_handle [open actual_selected_macro_locations.adc r]
set actual_anchors [read $anchor_handle]
close $anchor_handle
puts A96_FRESH_BRAM_PLACEMENT_REPORTED
report_area -io_info -file actual_GPIO_before_route.area
set io_handle [open actual_GPIO_before_route.area r]
set actual_gpio [read $io_handle]
close $io_handle
if {![regexp {uart_rx +INPUT +G14 +LVCMOS33[^\r\n]*NONE *\r?\n} $actual_gpio] ||
    ![regexp {uart_tx +OUTPUT +F14 +LVCMOS33[^\r\n]*NONE *\r?\n} $actual_gpio]} {error ACTUAL_GPIO_BEFORE_ROUTE_FAILED}
puts ACTUAL_G14_F14_FABRIC_GPIO_BEFORE_ROUTE_CONFIRMED

  update_timing -mode manhattan
  report_timing_summary -file ${prj_name}_place.timing
  report_area -io_info -file ${prj_name}_phy.area
  flow_status -file place_flow.status
  report_clock_utilization -file place_clock_utilization.txt
  if { [string equal $arr_filter true] } { flow_continue_check -step place -wns $arr_pwns -congestion $arr_cong }
###################################

  export_db ${prj_name}_place.db
}
proc opt_route_fun {} {
  upvar prj_name prj_name
  upvar singleRun singleRun
  upvar arr_filter arr_filter
  upvar arr_rwns arr_rwns
  upvar drHoldFix drHoldFix
  if { ![info exists singleRun] } { commit_param -step route }

### Editable zone for opt_route ###
  if { [string equal $arr_filter on] && [string equal $drHoldFix on] } { 
    set_param route fix_hold off
    set_param flow qor_monitor off
  }
  route
  # Project-local mandatory final hold stage; do not use the default template.
  update_timing -mode final
  report_timing_summary -file gui_before_final_hold.timing
  fix_hold
  update_timing -mode final
  report_qor -step route -file route.qor
  puts GUI_FINAL_HOLD_STAGE_EXECUTED
  report_timing_summary -file gui_standard_hold.timing
  set hold_report [open gui_standard_hold.timing r]
  set hold_text [read $hold_report]
  close $hold_report
  if {![regexp {HWNS:\s*([-0-9.]+)ns} $hold_text unused hold_slack]} {error "GUI_HOLD_REPORT_MISSING"}
  if {$hold_slack < 0} {
    fix_hold -clock_opt -buffer_opt -eco
    update_timing -mode final
    puts GUI_BOUNDED_OFFICIAL_EXTRA_HOLD_EXECUTED
  }
  if { [string equal $arr_filter on] && [string equal $drHoldFix on] } {
    flow_continue_check -step route -wns $arr_rwns -name ${prj_name}
    fix_hold
    set_param route fix_hold on
    set_param flow qor_monitor on
    report_qor -step route -file route.qor
  }
  report_area -io_info -file ${prj_name}_phy.area
  update_timing -mode final
  report_timing_status -file ${prj_name}_phy.ts
  report_timing_summary -file ${prj_name}_pr.timing

  # Gate actual native results before exporting DB or generating a bit.
  set report_file [open ${prj_name}_pr.timing r]
  set report_text [read $report_file]
  close $report_file
  foreach metric {SWNS HWNS STNS HTNS} {
    if {![regexp [format {%s:\s*([-0-9.]+)ns} $metric] $report_text unused value]} {
      error "GUI_FINAL_TIMING_MISSING_${metric}"
    }
    if {$value < 0} {error "GUI_FINAL_TIMING_NEGATIVE_${metric}: $value"}
    if {($metric eq "STNS" || $metric eq "HTNS") && $value != 0} {
      error "GUI_FINAL_TNS_NONZERO_${metric}: $value"
    }
  }
  check_timing -verbose -file gui_final_check.txt
  set check_file [open gui_final_check.txt r]
  set check_text [read $check_file]
  close $check_file
  foreach label {{checking no clock} {checking invalid constraint} {checking combinational loops} {checking no path constraints} {checking shadowed/ignored timing exception constraints}} {
    if {[string first "${label}(0)" $check_text] < 0} {error "GUI_FINAL_CHECK_FAILED: $label"}
  }
  report_route_status -drc
# Exhaustive native IO endpoint gate. Report with -ep_num 10000 -path_num 1.
# Never infer coverage from a count floor left by a different synthesized graph.
proc gui_assert_complete_io {report_path port direction} {
  set fd [open $report_path r]
  set text [read $fd]
  close $fd
  array set expected {Max 0 Min 0}
  set stats [regexp -all -inline -line {^(Max|Min)\s*:\s*\w+\s+([-0-9.]+)ns,\s*\w+\s+([-0-9.]+)ns,\s*(\d+) Viol Endpoints,\s*(\d+) Total Endpoints,\s*(\d+) Paths Analyzed} $text]
  foreach {whole kind wns tns viol total analyzed} $stats {
    if {$wns < 0 || $tns != 0 || $viol != 0 || $total != $analyzed || $total >= 10000} {
      error "GUI_IO_NATIVE_INCOMPLETE_OR_NEGATIVE_${port}"
    }
    incr expected($kind) $total
  }
  if {$expected(Max) <= 0 || $expected(Min) <= 0} {
    error "GUI_IO_NO_SETUP_OR_HOLD_${port}"
  }
  set records {}
  set current {}
  foreach line [split $text "\n"] {
    if {[regexp {^Slack\s*:\s*([-0-9.]+)ns} $line whole slack]} {
      if {[dict size $current]} {lappend records $current}
      set current [dict create slack $slack]
    } elseif {[dict size $current]} {
      foreach {pattern key} {{^Begin Point\s*:\s*(\S+)} start {^End Point\s*:\s*(\S+)} end {^Check Type\s*:\s*(\S+)} type} {
        if {[regexp $pattern $line whole value]} {dict set current $key $value}
      }
      foreach {pattern edge_key clock_key} {
        {^Begin Point\s*:\s*\S+\s+\((rising|falling) edge triggered by clock (\S+)\s} start_edge start_clock
        {^End Point\s*:\s*\S+\s+\((rising|falling) edge triggered by clock (\S+)\s} end_edge end_clock
      } {
        if {[regexp $pattern $line whole edge clock]} {
          dict set current $edge_key $edge
          dict set current $clock_key $clock
        }
      }
    }
  }
  if {[dict size $current]} {lappend records $current}
  set setup {}
  set hold {}
  foreach record $records {
    foreach key {slack start end type start_edge start_clock end_edge end_clock} {
      if {![dict exists $record $key]} {error "GUI_IO_RECORD_MISSING_${port}_${key}"}
    }
    if {[dict get $record slack] < 0} {error "GUI_IO_NEGATIVE_${port}"}
    if {$direction eq "input"} {
      if {[dict get $record start] ne $port} {error "GUI_IO_WRONG_SOURCE_${port}"}
      set endpoint [dict get $record end]
    } elseif {$direction eq "output"} {
      if {[dict get $record end] ne $port} {error "GUI_IO_WRONG_DESTINATION_${port}"}
      # Native output endpoints are checked clock-edge buckets. The worst
      # setup and hold launch cells need not be the same (RAM vs CS path).
      set endpoint [list $port [dict get $record start_clock] [dict get $record start_edge] [dict get $record end_clock] [dict get $record end_edge]]
    } else {error "GUI_IO_UNKNOWN_DIRECTION_${port}"}
    switch -- [dict get $record type] {
      setup - recovery {lappend setup $endpoint}
      hold - removal {lappend hold $endpoint}
      default {error "GUI_IO_UNEXPECTED_CHECK_${port}"}
    }
  }
  if {[llength $setup] != $expected(Max) || [llength $hold] != $expected(Min)} {
    error "GUI_IO_MISSING_ENDPOINT_RECORD_${port}"
  }
  # A/B/C/D/MI of the same indexed slice data group can be the
  # independently worst setup and hold arcs. Keep group 0 and group 1 distinct.
  set setup_group {}
  set hold_group {}
  foreach endpoint $setup {
    if {[regexp {^(.+)\.(a|b|c|d|mi)\[([01])\]$} $endpoint whole inst input_pin group]} {
      lappend setup_group "${inst}.__DATA_GROUP_${group}"
    } else {lappend setup_group $endpoint}
  }
  foreach endpoint $hold {
    if {[regexp {^(.+)\.(a|b|c|d|mi)\[([01])\]$} $endpoint whole inst input_pin group]} {
      lappend hold_group "${inst}.__DATA_GROUP_${group}"
    } else {lappend hold_group $endpoint}
  }
  if {[llength [lsort -unique $setup]] != [llength $setup] ||
      [llength [lsort -unique $hold]] != [llength $hold] ||
      [lsort $setup_group] ne [lsort $hold_group]} {
    error "GUI_IO_ENDPOINT_SET_MISMATCH_${port}"
  }
  puts "GUI_COMPLETE_IO_${port} setup=$expected(Max) hold=$expected(Min)"
}

  foreach p {board_mosi board_cs_n user_flash_miso} {
   report_timing_path -through [get_nets $p] -file gui_${p}.txt -ep_num 10000 -path_num 1
   gui_assert_complete_io gui_${p}.txt $p input
  }
  foreach p {board_miso user_flash_mosi user_flash_cs_n} {
   report_timing_path -through [get_nets $p] -file gui_${p}.txt -ep_num 10000 -path_num 1
   gui_assert_complete_io gui_${p}.txt $p output
  }
  report_timing_summary -file final_timing.rpt
  puts GUI_FINAL_TIMING_IO_GATES_PASSED
  report_timing_exception -file ${prj_name}_exception.timing
  flow_status -file route_flow.status
  report_clock_utilization -file route_clock_utilization.txt
###################################

  export_db ${prj_name}_pr.db
}
proc bitgen_fun {} {
  upvar prj_name prj_name
  upvar cpcList cpcList
  upvar singleRun singleRun
  if { ![info exists singleRun] } { commit_param -step bitgen }
  if { [info exists cpcList] } {
    import_chipprobe_config $cpcList
    compile_probe
  }

### Editable zone for bitgen ###
  bitgen -no_date_info -bit $prj_name.bit
################################
  upvar chipDebugger chipDebugger
  if { ![info exists chipDebugger] } {
    setup_debugger
  } else { setup_debugger $chipDebugger }
  export_bitgen_param -file .bitgen_param.f 
}
foreach s [lrange $stepList $l $r] {
  step_begin $s
  set ACTIVESTEP $s
  set rc [catch {
    if { [string equal $s $start_step] } { prepare $l }
    ${s}_fun
  } RESULT]
  if { $rc } {
    step_error $s
    return -code error $RESULT
  } else {
    step_end $s
    unset ACTIVESTEP
  }
}
export_flow_status -s $start_step -e $end_step
