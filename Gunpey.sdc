derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 85.86 MHz output, shifted about half a period (rtl/pll/pll_0002.v); as in the owner's other
# cores the pin's clock is modelled as the machine clock inverted, and the read data -- launched by the chip's edge, captured by
# gunpey_sdram's input register a few edges after the READ command -- gets a two-cycle path. sys/sys.tcl puts the SDRAM pins' registers
# in the IO cells.
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# ==============================================================================
# The V30 (rtl/v30, the Irem M72 core's ucore) steps on a clock enable that gunpey_main never gives closer than five clocks apart
# (CE_MIN): its longest path, from its decode ROM, is about 46 ns, five clocks 58 ns. So:
#  * between its own clock-enabled registers (and ROMs): five clocks (the M72 core constrains its two-clock spacing the same way);
#  * from it to the bus adapter's registers that take its outputs at a clock enable (the address, the byte enables, the write word):
#    five clocks; to bs_q, which samples the bus status every clock but is only used at a clock enable, four (the sample used is the
#    one a clock before the enable);
#  * into it from gunpey_main's read word: two clocks (the word is written, then rd_wait falls, then the clock enable comes); from the
#    interrupt line the adapter takes at the clock enables: five.
# Its save-state read port is not clock-enabled and is not used here.
# ==============================================================================
set v30u_regs [add_to_collection [get_keepers -nowarn {*|v30u_eu:*|*}] [get_keepers -nowarn {*|v30u_biu:*|*}]]
set v30u_ssrd [add_to_collection [get_keepers -nowarn {*|v30u_biu:*|ss_rdata[*]}] [get_keepers -nowarn {*|v30u_eu:*|ss_rdata[*]}]]
set v30u_ce [remove_from_collection $v30u_regs $v30u_ssrd]
if {[get_collection_size $v30u_ce] > 0} {
    set_multicycle_path -setup 5 -from $v30u_ce -to $v30u_ce
    set_multicycle_path -hold  4 -from $v30u_ce -to $v30u_ce
    set v30_take [get_keepers -nowarn {*|gunpey_v30:u_cpu|addr_ann[*] *|gunpey_v30:u_cpu|be_lat[*] *|gunpey_v30:u_cpu|dout_q[*]}]
    set_multicycle_path -setup 5 -from $v30u_ce -to $v30_take
    set_multicycle_path -hold  4 -from $v30u_ce -to $v30_take
    set v30_bs [get_keepers -nowarn {*|gunpey_v30:u_cpu|bs_q[*]}]
    set_multicycle_path -setup 4 -from $v30u_ce -to $v30_bs
    set_multicycle_path -hold  3 -from $v30u_ce -to $v30_bs
    set v30_rd [get_keepers -nowarn {*|gunpey_main:u_main|rd_data[*]}]
    set_multicycle_path -setup 2 -from $v30_rd -to $v30u_ce
    set_multicycle_path -hold  1 -from $v30_rd -to $v30u_ce
    set v30_int [get_keepers -nowarn {*|gunpey_v30:u_cpu|int_q}]
    set_multicycle_path -setup 5 -from $v30_int -to $v30u_ce
    set_multicycle_path -hold  4 -from $v30_int -to $v30u_ce
}

# ==============================================================================
# The framework's HQ2x (sys/hq2x.sv) updates its datapath on the scandoubler's ce_x4i, four times per input pixel: for this core's
# 12-clock pixels at least three clocks apart. The framework does not constrain it (as in the Mystic Warriors core).
# ==============================================================================
set HQ [get_registers -nowarn {*|Blend:*|*}]
foreach n {cyc nextpatt pattern Prev0 Prev1 Prev2 Curr0 Curr1 Curr2 Next0 Next1 Next2 A B D F G H
           curbuf prevbuf offs wrdata wrdata_finished waddr wrout_addr wrpix wrin_addr2
           old_reset_line old_reset_frame} {
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s} $n]]]
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s[*]} $n]]]
}
set_multicycle_path -setup 3 -from $HQ -to $HQ
set_multicycle_path -hold  2 -from $HQ -to $HQ
