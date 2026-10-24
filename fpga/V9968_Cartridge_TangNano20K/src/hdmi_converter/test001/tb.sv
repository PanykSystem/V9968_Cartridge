`timescale 1ns/1ps
module tb;
	localparam integer H_TOTAL = 912;
	reg reset_n = 0;
	reg clk85m = 0;
	reg clk42m = 0;
	reg clk28m = 0;
	wire display_hs, display_vs, display_en;
	wire [7:0] display_r, display_g, display_b;
	wire locked, overflow, underflow, input_error;
	integer scenario = 0;
	integer phase_ps = 0;
	integer div_phase = 0;
	integer target_frames = 8;
	reg test_passed = 0;

	reg video_de = 0;
	reg video_vs = 1;
	reg [23:0] video_rgb = 0;

	hdmi_converter dut (
		.reset_n(reset_n), .clk42m(clk42m), .clk28m(clk28m),
		.video_de(video_de), .video_vs(video_vs),
		.video_r(video_rgb[23:16]), .video_g(video_rgb[15:8]),
		.video_b(video_rgb[7:0]),
		.display_hs(display_hs), .display_vs(display_vs), .display_en(display_en),
		.display_r(display_r), .display_g(display_g), .display_b(display_b),
		.locked(locked), .overflow(overflow), .underflow(underflow),
		.input_error(input_error)
	);

	// clk28m (u_pll / 5) and clk42m (u_pll2 / 2) share clk14m: the ratio is exactly 2:3,
	// the phase between the two PLLs is arbitrary (+PHASE).
	initial begin
		if( $value$plusargs("SCENARIO=%d", scenario) ) begin end
		if( $value$plusargs("PHASE=%d", phase_ps) ) begin end
		if( $value$plusargs("DIVPHASE=%d", div_phase) ) begin end
		if( $value$plusargs("FRAMES=%d", target_frames) ) begin end
		clk42m = div_phase[0];
		fork
			forever #5.820 clk85m = ~clk85m;
			begin
				#(phase_ps * 0.001);
				forever #17.460 clk28m = ~clk28m;
			end
		join
	end
	always @( posedge clk85m ) clk42m = ~clk42m;

	function automatic [23:0] pixel;
		input integer f, y, x;
		begin
			pixel = { f[4:0], y[8:0], x[9:0] };
		end
	endfunction

	// ----------------------------------------------------------------
	//	V9968 model: vdp_video_out register timing in clk85m (free running)
	// ----------------------------------------------------------------
	integer h85 = 0, v85 = 0, f85 = 0;
	integer v_max = 523;
	integer de_end85;
	reg [23:0] rgb85 = 0;
	reg h_en85 = 0;
	always @( posedge clk85m ) begin
		if( h85 % 2 == 1 )
			rgb85 <= (h85 >= 749 && h85 <= 2187) ? pixel(f85, v85 - 15, (h85 - 749) / 2) : (24'hA5A5A5 ^ h85);
		de_end85 = 749 + 1440;
		if( scenario == 2 && f85 == 3 && v85 == 115 ) de_end85 = 749 + 1438;
		if( scenario == 3 && f85 == 3 && v85 == 115 ) de_end85 = 749 + 1442;
		if( h85 == 749 ) h_en85 <= 1;
		else if( h85 == de_end85 ) h_en85 <= 0;
		if( h85 == 2735 ) begin
			h85 <= 0;
			if( v85 == v_max || v85 == 1023 ) begin
				v85 <= 0;
				f85 <= f85 + 1;
			end
			else v85 <= v85 + 1;
			// Software switches 60/50Hz at arbitrary lines, as the VDP register allows.
			if( scenario == 7 && f85 == 3 && v85 == 300 ) v_max = 625;
			if( scenario == 7 && f85 == 6 && v85 == 560 ) v_max = 523;
			if( scenario == 7 && f85 == 9 && v85 == 450 ) v_max = 625;
		end
		else h85 <= h85 + 1;
	end
	always @* begin
		video_de = h_en85 && v85 >= 15 && v85 < 495;
		if( scenario == 4 && f85 == 3 && v85 == 494 ) video_de = 0;
		if( scenario == 6 && f85 == 3 && v85 >= 65 ) video_de = 0;
		if( scenario == 8 ) video_de = 0;
		video_rgb = video_de ? rgb85 : 24'd0;
		video_vs = scenario == 8 ? 1'b1 : !(v85 >= v_max - 13 && v85 < v_max - 6);
	end

	initial begin
		#1;
		if( scenario == 1 ) v_max = 625;
	end
	localparam real LINE_NS = 2736 * 11.64;
	realtime de_rise [0:479];
	reg old_video_de = 0;
	always @( posedge clk42m ) begin
		if( video_de && !old_video_de && v85 >= 15 && v85 < 495 ) de_rise[v85 - 15] = $realtime;
		old_video_de <= video_de;
	end
	reg debug = 0;
	initial if( $test$plusargs("DEBUG") ) debug = 1;
	always @( dut.state ) if( debug )
		$display("%t state=%0d v=%0d ready=%0d frame_total=%0d valid=%0d f85=%0d v85=%0d",
			$realtime, dut.state, dut.v_count, dut.ready_lines, dut.frame_total, dut.frame_valid, f85, v85);

	// ----------------------------------------------------------------
	//	Output checker
	// ----------------------------------------------------------------
	integer x = 0, y = 0, fid = 0, last_fid = 0;
	integer frames = 0;
	integer output_cycles = 0;
	integer last_hs = -1, hs_width = 0, vs_lines = 0, last_vs = -1;
	integer frame_start = -1, last_frame_start = -1, period;
	integer lock_losses = 0, free_vs = 0;
	reg run_valid = 0;
	reg skip_h = 0;
	reg locked_d = 0;
	reg old_de = 0, old_hs = 0, old_vs = 0, old_locked_d = 0;
	reg vs_in_lock = 0;
	reg [23:0] data;
	realtime reset_release;
	realtime first_lock_time = 0;

	always @( negedge clk28m ) begin
		if( !reset_n ) begin
			x = 0; y = 0; run_valid = 0; locked_d = 0;
			output_cycles = 0; last_hs = -1; last_vs = -1; hs_width = 0; vs_lines = 0;
			old_de = 0; old_hs = 0; old_vs = 0; old_locked_d = 0;
		end
		else begin
			output_cycles = output_cycles + 1;
			// Locking reloads h_count once: skip HS checks until the next full HS pulse.
			if( locked && !locked_d ) skip_h = 1;
			if( display_hs && !old_hs ) begin
				if( !skip_h && last_hs >= 0 && output_cycles - last_hs != H_TOTAL )
					$fatal(1, "Horizontal period %0d", output_cycles - last_hs);
				last_hs = output_cycles;
				if( display_vs ) vs_lines = vs_lines + 1;
				skip_h = 0;
			end
			if( display_hs ) hs_width = hs_width + 1;
			if( !display_hs && old_hs ) begin
				if( !skip_h && hs_width != 62 ) $fatal(1, "HS width %0d", hs_width);
				hs_width = 0;
			end
			if( display_vs && !old_vs ) begin
				vs_in_lock = locked_d;
				if( scenario == 8 ) begin
					if( last_vs >= 0 && output_cycles - last_vs != 524 * H_TOTAL )
						$fatal(1, "Free-run VS period %0d", output_cycles - last_vs);
					free_vs = free_vs + 1;
				end
				last_vs = output_cycles;
			end
			if( !display_vs && old_vs ) begin
				if( vs_in_lock && locked_d && vs_lines != 6 ) $fatal(1, "VS width %0d lines", vs_lines);
				vs_lines = 0;
			end

			if( !locked_d ) begin
				if( display_en ) $fatal(1, "Active pixel while unlocked");
				if( old_locked_d ) lock_losses = lock_losses + 1;
				x = 0; y = 0; run_valid = 0;
			end
			else begin
				if( display_en ) begin
					data = { display_r, display_g, display_b };
					if( x == 0 && y == 0 ) begin
						fid = data[23:19];
						frame_start = output_cycles;
						if( run_valid ) begin
							if( fid != ((last_fid + 1) & 31) )
								$fatal(1, "Frame id %0d after %0d (dropped or repeated frame)", fid, last_fid);
							period = frame_start - last_frame_start;
							if( scenario == 1 && period != 626 * H_TOTAL )
								$fatal(1, "50Hz frame period %0d", period);
							if( scenario != 1 && scenario != 7 && period != 524 * H_TOTAL )
								$fatal(1, "60Hz frame period %0d", period);
							if( scenario == 7 && period != 524 * H_TOTAL && period != 626 * H_TOTAL )
								$fatal(1, "Frame period %0d", period);
						end
						if( first_lock_time == 0 ) first_lock_time = $realtime;
					end
					if( data !== pixel(fid, y, x) )
						$fatal(1, "Pixel mismatch fid=%0d y=%0d x=%0d got=%h expected=%h",
							fid, y, x, data, pixel(fid, y, x));
					if( x == 0 && ($realtime - de_rise[y] < 0.49 * LINE_NS || $realtime - de_rise[y] > 0.52 * LINE_NS) )
						$fatal(1, "Read start %0.1fns after write start (expected about half a line)",
							$realtime - de_rise[y]);
					if( output_cycles - last_hs != 122 + x )
						$fatal(1, "Active horizontal position");
					x = x + 1;
				end
				if( !display_en && old_de ) begin
					if( x != 720 ) $fatal(1, "Line width %0d", x);
					x = 0;
					if( y == 479 ) begin
						y = 0;
						frames = frames + 1;
						last_fid = fid;
						last_frame_start = frame_start;
						run_valid = 1;
					end
					else y = y + 1;
				end
			end
			if( !display_en && { display_r, display_g, display_b } !== 24'd0 )
				$fatal(1, "Nonblack blanking");
			old_de = display_en; old_hs = display_hs; old_vs = display_vs;
			old_locked_d = locked_d;
			locked_d = locked;
		end
	end

	task automatic check_flags;
		input exp_over, exp_under, exp_input;
		begin
			if( overflow !== exp_over || underflow !== exp_under || input_error !== exp_input )
				$fatal(1, "Flags overflow=%b underflow=%b input_error=%b, expected %b %b %b",
					overflow, underflow, input_error, exp_over, exp_under, exp_input);
		end
	endtask

	task automatic hard_reset;
		begin
			reset_n = 0;
			#503;
			reset_n = 1;
			reset_release = $realtime;
			frames = 0;
			first_lock_time = 0;
			lock_losses = 0;
		end
	endtask

	integer losses_before;
	initial begin
		#500;
		reset_n = 1;
		reset_release = $realtime;
		case( scenario )
		0, 1: begin
			wait( frames == 2 );
			if( first_lock_time - reset_release > 3 * 626 * 31.85e3 )
				$fatal(1, "Lock took too long");
			// Reset in active video.
			wait( display_en );
			#100;
			hard_reset();
			wait( frames == target_frames );
			if( lock_losses != 0 ) $fatal(1, "Lock lost %0d times in steady state", lock_losses);
			check_flags(0, 0, 0);
		end
		2, 3, 4, 6: begin
			// A missing last line runs the reader dry before the writer reaches VS.
			if( scenario == 6 || scenario == 4 ) wait( underflow );
			else wait( input_error );
			frames = 0;
			wait( frames == 3 );
			check_flags(0, scenario == 6 || scenario == 4, scenario == 2 || scenario == 3);
		end
		5: begin
			wait( frames == 2 );
			wait( display_en );
			// Freeze the pointer seen by the writer: the FIFO fills while output is correct.
			force dut.read_gray = dut.read_gray;
			wait( dut.overflow42 );
			release dut.read_gray;
			wait( overflow );
			frames = 0;
			wait( frames == 3 );
			check_flags(1, 0, 0);
		end
		7: begin
			wait( f85 >= 11 );
			frames = 0;
			losses_before = lock_losses;
			wait( frames == 3 );
			if( lock_losses != losses_before ) $fatal(1, "Lock lost after mode settled");
			check_flags(0, 0, 0);
		end
		8: begin
			wait( free_vs == 4 );
			if( locked ) $fatal(1, "Locked without input");
			check_flags(0, 0, 0);
		end
		endcase
		if( scenario != 0 && scenario != 1 ) begin
			hard_reset();
			repeat(100) @(negedge clk28m);
			check_flags(0, 0, 0);
		end
		test_passed = 1;
		$display("PASS scenario=%0d phase=%0d divphase=%0d frames=%0d losses=%0d",
			scenario, phase_ps, div_phase, frames, lock_losses);
		$finish;
	end
	initial begin
		#1000000000;
		$fatal(1, "Timeout");
	end
endmodule
