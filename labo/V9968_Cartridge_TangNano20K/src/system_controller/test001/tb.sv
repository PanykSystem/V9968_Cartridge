// System Controller busy-access and ROM command sequence regression.
module tb;
	reg test_passed = 0;
	reg clk = 0;
	always #5820 clk = ~clk;
	reg reset_n = 0;
	reg bus_cs = 0, bus_valid = 0, bus_write = 0;
	reg [3:0] bus_address = 0;
	reg [7:0] bus_wdata = 0;
	wire bus_ready, bus_rdata_en;
	wire [7:0] bus_rdata;
	wire rom_bus_address, rom_bus_valid, rom_bus_write;
	wire [7:0] rom_bus_wdata;
	reg rom_bus_ready = 0;
	reg [9:0] transfers [0:31];
	integer count = 0;

	system_controller u_dut (
		.clk(clk), .reset_n(reset_n),
		.bus_cs(bus_cs), .bus_address(bus_address), .bus_valid(bus_valid),
		.bus_ready(bus_ready), .bus_write(bus_write), .bus_wdata(bus_wdata),
		.bus_rdata(bus_rdata), .bus_rdata_en(bus_rdata_en),
		.rom_bus_address(rom_bus_address), .rom_bus_valid(rom_bus_valid),
		.rom_bus_ready(rom_bus_ready), .rom_bus_write(rom_bus_write),
		.rom_bus_wdata(rom_bus_wdata), .rom_bus_rdata(8'h00), .rom_bus_rdata_en(1'b0)
	);

	always @(posedge clk) begin
		if( reset_n && rom_bus_valid ) begin
			if( !rom_bus_ready ) $fatal(1, "ROM transfer while not ready");
			transfers[count] = {rom_bus_write, rom_bus_address, rom_bus_wdata};
			count = count + 1;
		end
	end

	task access(input wr, input [3:0] address, input [7:0] data,
				input expected_en, input [7:0] expected_data);
		@(negedge clk);
		bus_cs = 1;
		bus_valid = 1;
		bus_write = wr;
		bus_address = address;
		bus_wdata = data;
		@(posedge clk);
		#1;
		if( bus_rdata_en !== expected_en ||
			(expected_en && bus_rdata !== expected_data) )
			$fatal(1, "Access %h: en=%b data=%h expected en=%b data=%h",
				address, bus_rdata_en, bus_rdata, expected_en, expected_data);
		@(negedge clk);
		bus_cs = 0;
		bus_valid = 0;
	endtask

	task check_transfer(input integer index, input [9:0] expected);
		if( transfers[index] !== expected )
			$fatal(1, "ROM transfer %0d: %h expected %h", index, transfers[index], expected);
	endtask

	integer i;
	initial begin
		repeat(5) @(negedge clk);
		reset_n = 1;
		repeat(10) @(negedge clk);
		if( count != 0 || !bus_ready ) $fatal(1, "Unexpected boot operation");
		access(1, 0, 8'h80, 0, 0);
		access(1, 1, 8'h01, 0, 0);
		access(1, 2, 8'h01, 0, 0);
		access(1, 3, 8'h56, 0, 0);
		access(1, 4, 8'h34, 0, 0);
		access(1, 5, 8'h12, 0, 0);
		access(1, 7, 8'hA5, 0, 0);
		access(1, 9, 8'h03, 0, 0);
		access(1, 10, 8'h03, 0, 0);
		access(1, 8, 8'hA6, 0, 0);
		access(1, 6, 8'h01, 0, 0);
		if( bus_ready ) $fatal(1, "Command did not become busy");
		for( i = 0; i < 16; i = i + 1 ) access(0, i[3:0], 0, 0, 0);
		access(1, 0, 8'h00, 0, 0);
		access(1, 1, 8'h02, 0, 0);
		access(1, 2, 8'hFF, 0, 0);
		access(1, 3, 8'hFF, 0, 0);
		access(1, 4, 8'hFF, 0, 0);
		access(1, 5, 8'hFF, 0, 0);
		access(1, 7, 8'hFF, 0, 0);
		access(1, 8, 8'hFF, 0, 0);
		access(1, 9, 8'hFF, 0, 0);
		access(1, 10, 8'hFF, 0, 0);
		access(1, 6, 8'h03, 0, 0);
		rom_bus_ready = 1;
		wait(bus_ready);
		repeat(5) @(negedge clk);
		if( count != 9 ) $fatal(1, "Expected 9 write transfers, got %0d", count);
		check_transfer(0, 10'h206);
		check_transfer(1, 10'h300);
		check_transfer(2, 10'h200);
		check_transfer(3, 10'h356);
		check_transfer(4, 10'h334);
		check_transfer(5, 10'h312);
		check_transfer(6, 10'h203);
		check_transfer(7, 10'h3A5);
		check_transfer(8, 10'h207);
		access(0, 0, 0, 1, 8'h7F);
		access(0, 1, 0, 1, 8'hFE);
		access(0, 2, 0, 1, 8'hFE);
		access(0, 3, 0, 1, 8'h56);
		access(0, 4, 0, 1, 8'h34);
		access(0, 5, 0, 1, 8'h12);
		access(0, 6, 0, 1, 8'hFF);
		access(0, 7, 0, 1, 8'hA5);
		access(0, 9, 0, 1, 8'h03);
		access(0, 10, 0, 1, 8'h04);
		access(1, 10, 8'h03, 0, 0);
		access(0, 8, 0, 1, 8'hA6);
		access(0, 10, 0, 1, 8'h04);
		for( i = 7; i < 256; i = i + 1 ) access(1, 6, i[7:0], 0, 0);
		if( count != 9 || !bus_ready ) $fatal(1, "Reserved command executed");
		bus_cs = 0;
		bus_valid = 1;
		bus_write = 1;
		bus_address = 0;
		bus_wdata = 0;
		repeat(3) @(negedge clk);
		bus_valid = 0;
		access(0, 0, 0, 1, 8'h7F);
		test_passed = 1;
		$display("[RESULT] ALL TESTS PASSED: busy accesses dropped, reserved commands ignored");
		$finish;
	end

	initial begin
		#100_000_000;
		$fatal(1, "Simulation timeout");
	end
endmodule
