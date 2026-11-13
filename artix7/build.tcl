# SPDX-License-Identifier: CERN-OHL-S-2.0
# Vivado, no project: the two GTP cores, then synthesis to bitstream of inline_artix7.
# vivado -mode batch -source build.tcl -tclargs <out dir> <InlineSniffer.v> <pins.xdc>
lassign $argv out rtl pins
set here [file dirname [file normalize [info script]]]
set part xc7a35tfgg484-2
create_project -in_memory -part $part
file delete -force $out/ip
file mkdir $out/ip

proc gt {name rate width extra} {
  global out
  create_ip -name gtwizard -vendor xilinx.com -library ip -module_name $name -dir $out/ip
  set_property -dict [concat [list \
    CONFIG.identical_val_tx_line_rate $rate CONFIG.identical_val_rx_line_rate $rate \
    CONFIG.identical_val_tx_reference_clock 155.520 CONFIG.identical_val_rx_reference_clock 155.520 \
    CONFIG.gt0_val_tx_data_width $width CONFIG.gt0_val_rx_data_width $width \
    CONFIG.gt0_val_encoding None CONFIG.gt0_val_decoding None CONFIG.gt0_val_port_rxslide false \
    CONFIG.gt0_val_rxcomma_deten false CONFIG.gt0_val_align_mcomma_det false CONFIG.gt0_val_align_pcomma_det false \
    CONFIG.gt0_val_rx_termination_voltage Programmable CONFIG.gt0_val_rx_cm_trim 800 \
    CONFIG.gt0_val_drp_clock 155.52 CONFIG.gt_val_drp_clock 155.52] $extra] [get_ips $name]
  set_property generate_synth_checkpoint false [get_files $name.xci]
  generate_target all [get_ips $name]
}
# a port the wizard ties low inside its channel wrapper, tied high: exactly one place, or stop
proc tie_high {file port} {
  set f [open $file]; set text [read $f]; close $f
  if {[regsub -all "\\.$port\\s*\\(tied_to_ground_i\\)" $text ".$port (tied_to_vcc_i)" text] != 1} { error "$file: $port not tied low once" }
  set f [open $file w]; puts -nonewline $f $text; close $f
}
gt gt_ds 2.48832 20 {CONFIG.gt0_val_rxusrclk RXOUTCLK CONFIG.gt0_val_port_txpippmen true CONFIG.gt0_val_port_txpippmovrden true
  CONFIG.gt0_val_port_txpippmpd true CONFIG.gt0_val_port_txpippmsel true CONFIG.gt0_val_port_txpippmstepsize true}
gt gt_us 4.97664 40 {CONFIG.gt0_val_port_rxcdrhold true}
# upstream bursts: the offset cancellation must not adapt on the zeros between them
tie_high $out/ip/gt_us/gt_us_gt.v RXOSHOLD

read_verilog [list $rtl $here/inline_artix7.v $out/usb_serial.v]
read_xdc $here/inline.xdc
read_xdc $pins
synth_design -top inline_artix7 -part $part
opt_design
place_design
phys_opt_design
route_design
report_utilization -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt
report_clocks -file $out/clocks.rpt
foreach kind {setup hold} {
  set slack [get_property SLACK [get_timing_paths -$kind]]
  puts "RESULT $kind slack $slack ns"
  if {$slack < 0} { error "$kind timing not met: $out/timing.rpt" }
}
write_bitstream -force $out/inline.bit
# the socketed flash's image for an external programmer (flashrom wants the chip's full 4 MiB)
write_cfgmem -force -format bin -interface SPIx1 -size 4 -loadbit "up 0x0 $out/inline.bit" -file $out/inline.bin
set pad [expr {4 * 1024 * 1024 - [file size $out/inline.bin]}]
set f [open $out/inline.bin a]; fconfigure $f -translation binary
puts -nonewline $f [string repeat \xff $pad]; close $f
puts "RESULT $out/inline.bit $out/inline.bin"
