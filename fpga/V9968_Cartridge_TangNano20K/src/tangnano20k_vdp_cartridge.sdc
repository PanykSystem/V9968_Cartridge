//Copyright (C)2014-2026 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.12.02_SP2 (64-bit) 
//Created Time: 2026-04-14 21:33:47

# 入力クロック (全クロックの源振は clk14m のみ)
create_clock -name clk14m -period 69.84128 -waveform {0 34.921} [get_ports {clk14m}]

# PLL 出力クロック
# u_pll: 14.31818MHz x 10 = 143.1818MHz (HDMI serializer)
create_generated_clock -name clk143m  -source [get_ports {clk14m}] -master_clock clk14m -multiply_by 10 [get_nets {clk143m}]
# Gowin_CLKDIV: clk143m / 5 = 28.63636MHz (HDMI pixel clock)
create_generated_clock -name clk28m   -source [get_ports {clk14m}] -master_clock clk14m -multiply_by 2 [get_nets {clk28m}]
create_generated_clock -name clk85m   -source [get_ports {clk14m}] -master_clock clk14m -multiply_by 6 [get_nets {clk85m}]
# create_generated_clock -name clk85m_n -source [get_ports {clk14m}] -master_clock clk14m -multiply_by 6 -phase 180 [get_nets {clk85m_n}]
# geo3d: engine clock = CLKOUTD of u_pll2 (CLKOUT / 2), same PLL and phase as clk85m,
# so the geo3d_bus crossings clk85m <-> clk42g are timed as related clocks
create_generated_clock -name clk42m   -source [get_ports {clk14m}] -master_clock clk14m -multiply_by 3 [get_nets {clk42m}]
# geo3d: retain setup margin in both directions for the unmodelled CLKOUTD divider delay.
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk85m}] -to [get_clocks {clk42m}]
set_clock_uncertainty 0.5 -setup -from [get_clocks {clk42m}] -to [get_clocks {clk85m}]
# CLKOUTD is delayed relative to CLKOUT in hardware, improving hold on clk42m -> clk85m.
# Keep hold uncertainty only on the opposite direction where that delay reduces hold margin.
set_clock_uncertainty 0.5 -hold -from [get_clocks {clk85m}] -to [get_clocks {clk42m}]

# 非同期クロックグループ宣言 → clk1とclk2間の全パスをタイミング除外
set_clock_groups -asynchronous -group [get_clocks {clk143m}] -group [get_clocks {clk42m}]
# SPI ROM uses two-flop request/ack synchronizers and holds data until acknowledged.
set_clock_groups -asynchronous -group [get_clocks {clk143m}] -group [get_clocks {clk85m}]
set_clock_groups -asynchronous -group [get_clocks {clk28m}] -group [get_clocks {clk85m}]
# clk28m/clk143m (u_pll) と clk85m/clk42m (u_pll2) は同じ源振だが別 PLL のため位相は不定。
# 周波数比は固定 (clk28m:clk42m = 2:3) でも、クロック間の受け渡しは非同期として扱う。
# HDMI FIFO: bound async transfer delay below each source period for Gray coherence.
# Do not use clock_groups here: it overrides max_delay in Gowin.
set_max_delay -from [get_clocks {clk42m}] -to [get_clocks {clk28m}] 18.0
set_max_delay -from [get_clocks {clk28m}] -to [get_clocks {clk42m}] 30.0
set_false_path -hold -from [get_clocks {clk42m}] -to [get_clocks {clk28m}]
set_false_path -hold -from [get_clocks {clk28m}] -to [get_clocks {clk42m}]
