// --------------------------------------------------------------------
//	system_controller I/O register test (doc/spec/system_controller.md)
//		40h enabler / 41h device select / 42h function select
//		43h-47h Config ROM Reader/Writer
// --------------------------------------------------------------------

module tb #(
	parameter FLASH_OUTPUT_DELAY = 12000
) ();
	reg test_passed = 0;
	localparam		CLK_PERIOD			= 11640;	//	85.9MHz
	localparam		CLK_SERIAL_PERIOD	= 4656;		//	214.8MHz

	reg				clk;
	reg				clk_serial;
	reg				reset_n;

	reg				bus_cs;
	reg		[3:0]	bus_address;
	reg				bus_valid;
	reg				bus_write;
	reg		[7:0]	bus_wdata;
	wire			bus_ready;
	wire	[7:0]	bus_rdata;
	wire			bus_rdata_en;

	wire			rom_bus_address;
	wire			rom_bus_valid;
	wire			rom_bus_write;
	wire	[7:0]	rom_bus_wdata;
	wire			spi_bus_ready;
	wire	[7:0]	spi_bus_rdata;
	wire			spi_bus_rdata_en;

	wire			flash_spi_clk;
	wire			flash_spi_cs_n;
	wire	[3:0]	flash_spi_io;
	integer			errors;
	integer			i;

	pullup( flash_spi_io[2] );
	pullup( flash_spi_io[3] );

	system_controller u_dut (
		.clk					( clk					),
		.reset_n				( reset_n				),
		.bus_cs					( bus_cs				),
		.bus_address			( bus_address			),
		.bus_valid				( bus_valid				),
		.bus_ready				( bus_ready				),
		.bus_write				( bus_write				),
		.bus_wdata				( bus_wdata				),
		.bus_rdata				( bus_rdata				),
		.bus_rdata_en			( bus_rdata_en			),
		.rom_bus_address		( rom_bus_address		),
		.rom_bus_valid			( rom_bus_valid			),
		.rom_bus_ready			( spi_bus_ready			),
		.rom_bus_write			( rom_bus_write			),
		.rom_bus_wdata			( rom_bus_wdata			),
		.rom_bus_rdata			( spi_bus_rdata			),
		.rom_bus_rdata_en		( spi_bus_rdata_en		)
	);

	ip_spi_rom u_spi_rom (
		.reset_n				( reset_n				),
		.clk					( clk					),
		.clk_serial				( clk_serial			),
		.bus_cs					( 1'b1					),
		.bus_address			( rom_bus_address		),
		.bus_write				( rom_bus_write			),
		.bus_valid				( rom_bus_valid			),
		.bus_ready				( spi_bus_ready			),
		.bus_wdata				( rom_bus_wdata			),
		.bus_rdata				( spi_bus_rdata			),
		.bus_rdata_en			( spi_bus_rdata_en		),
		.stream_rdata			(						),
		.stream_valid			(						),
		.stream_ready			( 1'b0					),
		.stream_stop			( 1'b0					),
		.srom_cs_n				( flash_spi_cs_n		),
		.srom_clk				( flash_spi_clk			),
		.srom_hold_n			( flash_spi_io[3]		),
		.srom_wp_n				( flash_spi_io[2]		),
		.srom_do				( flash_spi_io[1]		),
		.srom_di				( flash_spi_io[0]		)
	);

	sfrom_test_model #(
		.OUTPUT_DELAY			( FLASH_OUTPUT_DELAY	)
	) u_flash (
		.spi_clk				( flash_spi_clk			),
		.spi_cs_n				( flash_spi_cs_n		),
		.spi_io					( flash_spi_io			)
	);

	//	SPI frame monitor (real Flash semantics): commands are latched at CS# rising,
	//	so every frame must be a whole number of bytes and CS# high time >= 50ns.
	integer			mon_bits;
	reg		[63:0]	mon_shift;
	time			mon_cs_rise;
	time			mon_clk_edge = 0;
	integer			mon_programs = 0;
	integer			mon_reads = 0;
	reg		[7:0]	mon_command;
	integer			page_programs;
	integer			page_reads;
	initial begin
		mon_bits	= 0;
		mon_shift	= 0;
		mon_cs_rise	= 0;
	end
	always @( negedge flash_spi_cs_n ) begin
		if( mon_cs_rise != 0 && ($time - mon_cs_rise) < 50000 ) begin
			$display( "[ERROR] SPI: CS# high time %0t < 50ns", $time - mon_cs_rise );
			errors = errors + 1;
		end
		mon_bits	= 0;
		mon_shift	= 0;
	end
	always @( posedge flash_spi_clk ) begin
		if( !flash_spi_cs_n ) begin
			mon_bits	= mon_bits + 1;
			mon_shift	= { mon_shift[62:0], flash_spi_io[0] };
			if( mon_bits == 8 ) mon_command = mon_shift[7:0];
		end
	end
	always @( flash_spi_clk ) begin
		if( reset_n && mon_clk_edge != 0 && ($time - mon_clk_edge) < 18000 ) begin
			$display( "[ERROR] SPI half-cycle shorter than 18ns" );
			errors = errors + 1;
		end
		mon_clk_edge = $time;
	end
	always @( posedge flash_spi_cs_n ) begin
		mon_cs_rise = $time;
		if( mon_bits >= 8 && mon_command == 8'h02 ) mon_programs = mon_programs + 1;
		if( mon_bits >= 8 && mon_command == 8'h0B ) mon_reads = mon_reads + 1;
		if( (mon_bits % 8) != 0 ) begin
			$display( "[ERROR] SPI: frame of %0d bits (not byte aligned)", mon_bits );
			errors = errors + 1;
		end
		else if( mon_bits != 0 && mon_bits <= 64 ) begin
			$display( "[SPI] frame %0d bytes: %h", mon_bits / 8, mon_shift );
		end
		else if( mon_bits != 0 ) begin
			$display( "[SPI] frame %0d bytes (long)", mon_bits / 8 );
		end
	end

	always #(CLK_PERIOD/2)			clk <= ~clk;
	always #(CLK_SERIAL_PERIOD/2)	clk_serial <= ~clk_serial;

	//	One I/O access. Returns rdata_en/rdata of the cycle following the handshake.
	task io_access( input write, input [7:0] port, input [7:0] wdata, output en, output [7:0] rdata );
		integer	timeout;
		reg		poll_en;
		reg	[7:0]	poll_data;
		begin
			@( negedge clk );
			timeout		= 0;
			if( !bus_ready ) begin
				poll_en = 1'b0;
				poll_data = 8'hFF;
				while( !poll_en || poll_data != 8'h7F ) begin
					bus_cs = 1'b1;
					bus_valid = 1'b1;
					bus_write = 1'b0;
					bus_address = 4'h0;
					@( posedge clk );
					#1;
					poll_en = bus_rdata_en;
					poll_data = bus_rdata;
					bus_cs = 1'b0;
					bus_valid = 1'b0;
					@( negedge clk );
					timeout = timeout + 1;
					if( timeout > 2_000_000 ) $fatal( 1, "40h polling timeout (port %02Xh)", port );
				end
			end
			bus_cs		= 1'b1;
			bus_valid	= 1'b1;
			bus_write	= write;
			bus_address	= port[3:0];
			bus_wdata	= wdata;
			@( posedge clk );
			#1;
			bus_cs		= 1'b0;
			bus_valid	= 1'b0;
			bus_write	= 1'b0;
			en			= bus_rdata_en;
			rdata		= bus_rdata;
			@( posedge clk );
			#1;
			if( bus_rdata_en !== 1'b0 ) begin
				$display( "[ERROR] bus_rdata_en held after the access (port %02Xh)", port );
				errors = errors + 1;
			end
		end
	endtask

	task io_write( input [7:0] port, input [7:0] wdata );
		reg			en;
		reg	[7:0]	rdata;
		begin
			io_access( 1'b1, port, wdata, en, rdata );
			if( en !== 1'b0 ) begin
				$display( "[ERROR] write %02Xh: bus_rdata_en asserted", port );
				errors = errors + 1;
			end
		end
	endtask

	task expect_read( input [7:0] port, input [7:0] expected, input [8*40-1:0] label );
		reg			en;
		reg	[7:0]	rdata;
		begin
			io_access( 1'b0, port, 8'h00, en, rdata );
			if( en !== 1'b1 || rdata !== expected ) begin
				$display( "[ERROR] %0s: read %02Xh -> en=%b data=%02Xh, expected %02Xh", label, port, en, rdata, expected );
				errors = errors + 1;
			end
		end
	endtask

	task expect_no_response( input [7:0] port, input [8*40-1:0] label );
		reg			en;
		reg	[7:0]	rdata;
		begin
			io_access( 1'b0, port, 8'h00, en, rdata );
			if( en !== 1'b0 ) begin
				$display( "[ERROR] %0s: read %02Xh must not respond (data=%02Xh)", label, port, rdata );
				errors = errors + 1;
			end
		end
	endtask

	task expect_all_silent( input [8*40-1:0] label );
		integer	p;
		begin
			for( p = 8'h40; p <= 8'h4F; p = p + 1 ) begin
				expect_no_response( p[7:0], label );
			end
		end
	endtask

	task set_rom_address( input [23:0] address );
		begin
			io_write( 8'h43, address[ 7: 0] );
			io_write( 8'h44, address[15: 8] );
			io_write( 8'h45, address[23:16] );
		end
	endtask

	task rom_read( input [23:0] address, input [7:0] expected, input [8*40-1:0] label );
		begin
			set_rom_address( address );
			io_write( 8'h46, 8'h00 );
			expect_read( 8'h47, expected, label );
		end
	endtask

	//	MSX side completion check of write/erase: poll BUSY (bit0) with the
	//	read status command (46h=04h).
	task rom_wait_ready( input [8*40-1:0] label );
		reg			en;
		reg	[7:0]	rdata;
		integer		tries;
		integer		busy_count;
		begin
			tries = 0;
			busy_count = 0;
			rdata = 8'h01;
			while( rdata[0] !== 1'b0 && tries < 10000 ) begin
				io_write( 8'h46, 8'h04 );
				io_access( 1'b0, 8'h47, 8'h00, en, rdata );
				if( rdata[0] === 1'b1 ) busy_count = busy_count + 1;
				tries = tries + 1;
			end
			if( rdata[0] !== 1'b0 ) begin
				$display( "[ERROR] %0s: BUSY timeout (status %02Xh)", label, rdata );
				errors = errors + 1;
			end
			else if( busy_count == 0 ) begin
				$display( "[ERROR] %0s: BUSY was never observed", label );
				errors = errors + 1;
			end
			else begin
				$display( "[INFO] %0s: BUSY observed %0d time(s)", label, busy_count );
			end
		end
	endtask

	task rom_poll( input [23:0] address, input [7:0] expected, input [8*40-1:0] label );
		reg			en;
		reg	[7:0]	rdata;
		integer		tries;
		begin
			set_rom_address( address );
			tries = 0;
			rdata = ~expected;
			while( rdata !== expected && tries < 200 ) begin
				io_write( 8'h46, 8'h00 );
				io_access( 1'b0, 8'h47, 8'h00, en, rdata );
				tries = tries + 1;
			end
			if( rdata !== expected ) begin
				$display( "[ERROR] %0s: polling timeout, read %02Xh, expected %02Xh", label, rdata, expected );
				errors = errors + 1;
			end
			else begin
				$display( "[INFO] %0s: completed after %0d read(s)", label, tries );
			end
		end
	endtask

	integer	stage_errors;
	integer	p;

	task stage_begin;
		stage_errors = errors;
	endtask

	task stage_end( input [8*64-1:0] label );
		if( errors == stage_errors ) $display( "[PASS] %0s", label );
	endtask

	initial begin
		clk			= 1'b0;
		clk_serial	= 1'b0;
		reset_n		= 1'b0;
		errors		= 0;
		bus_cs		= 1'b0;
		bus_valid	= 1'b0;
		bus_write	= 1'b0;
		bus_address	= 4'd0;
		bus_wdata	= 8'd0;

		#1;
		u_flash.memory[ 24'h123456 ] = 8'hA5;
		u_flash.memory[ 24'h123457 ] = 8'h3C;
		u_flash.memory[ 24'h7F0000 ] = 8'h81;
		u_flash.memory[ 24'h1FFFFF ] = 8'h77;
		u_flash.memory[ 24'h210000 ] = 8'h88;
		u_flash.memory[ 24'h20FFF0 ] = 8'h00;

		repeat( 20 ) @( posedge clk );
		reset_n = 1'b1;
		repeat( 200 ) @( posedge clk );
		if( flash_spi_cs_n !== 1'b1 || flash_spi_clk !== 1'b0 ) begin
			$fatal( 1, "Flash must remain idle after reset (no boot copy)" );
		end

		//	---- disabled ----
		stage_begin;
		expect_all_silent( "after reset" );
		io_write( 8'h40, 8'h40 );
		expect_all_silent( "enabler=40h" );
		io_write( 8'h41, 8'h01 );
		io_write( 8'h42, 8'h01 );
		expect_all_silent( "41h/42h written while disabled" );
		stage_end( "disabled: 40h-4Fh do not respond" );

		//	---- enabled, no device ----
		stage_begin;
		io_write( 8'h40, 8'h80 );
		expect_read( 8'h40, 8'h7F, "enabled" );
		for( p = 8'h41; p <= 8'h4F; p = p + 1 ) expect_no_response( p[7:0], "enabled, no devsel" );
		io_write( 8'h41, 8'h02 );
		expect_read( 8'h40, 8'h7F, "devsel=02h" );
		for( p = 8'h41; p <= 8'h4F; p = p + 1 ) expect_no_response( p[7:0], "devsel=02h" );
		io_write( 8'h41, 8'hFF );
		expect_no_response( 8'h41, "devsel=FFh" );
		stage_end( "enabled: 40h=7Fh, other device IDs do not respond" );

		//	---- device selected ----
		stage_begin;
		io_write( 8'h41, 8'h01 );
		expect_read( 8'h41, 8'hFE, "devsel=01h" );
		expect_read( 8'h42, 8'hFF, "function not selected" );
		for( p = 8'h43; p <= 8'h4F; p = p + 1 ) expect_no_response( p[7:0], "function not selected" );
		io_write( 8'h42, 8'h02 );
		expect_read( 8'h42, 8'hFF, "function=02h" );
		for( p = 8'h43; p <= 8'h4F; p = p + 1 ) expect_no_response( p[7:0], "function=02h" );
		io_write( 8'h42, 8'h01 );
		expect_read( 8'h42, 8'hFE, "function=01h" );
		stage_end( "devsel=01h: 41h=FEh, 42h=FEh/FFh" );

		//	---- Config ROM Reader/Writer registers ----
		stage_begin;
		set_rom_address( 24'h563412 );
		expect_read( 8'h43, 8'h12, "address L" );
		expect_read( 8'h44, 8'h34, "address M" );
		expect_read( 8'h45, 8'h56, "address H" );
		for( p = 8'h4B; p <= 8'h4D; p = p + 1 ) expect_no_response( p[7:0], "reserved" );
		expect_read( 8'h4F, 8'hA1, "page capability" );
		expect_read( 8'h4E, 8'h00, "initial page result" );
		stage_end( "function=01h: address and page registers, reserved silent" );

		//	---- ROM read ----
		stage_begin;
		rom_read( 24'h123456, 8'hA5, "ROM read 123456h" );
		rom_read( 24'h123457, 8'h3C, "ROM read 123457h" );
		rom_read( 24'h7F0000, 8'h81, "ROM read 7F0000h" );
		stage_end( "ROM read command" );

		//	---- ROM write / sector erase ----
		stage_begin;
		set_rom_address( 24'h200010 );
		io_write( 8'h47, 8'h5A );
		io_write( 8'h46, 8'h01 );
		rom_wait_ready( "ROM write" );
		rom_read( 24'h200010, 8'h5A, "ROM read after write" );
		if( u_flash.memory[ 24'h200010 ] !== 8'h5A ) begin
			$display( "[ERROR] ROM write: memory[200010h] = %02Xh", u_flash.memory[ 24'h200010 ] );
			errors = errors + 1;
		end
		rom_read( 24'h200000, 8'hFF, "ROM write must not touch page top" );
		set_rom_address( 24'h20ABCD );
		io_write( 8'h46, 8'h02 );
		rom_wait_ready( "sector erase" );
		rom_read( 24'h200010, 8'hFF, "ROM read after erase" );
		if( u_flash.memory[ 24'h200010 ] !== 8'hFF ) begin
			$display( "[ERROR] sector erase: memory[200010h] = %02Xh", u_flash.memory[ 24'h200010 ] );
			errors = errors + 1;
		end
		rom_read( 24'h20FFF0, 8'hFF, "ROM read after erase (block end)" );
		if( u_flash.memory[ 24'h1FFFFF ] !== 8'h77 || u_flash.memory[ 24'h210000 ] !== 8'h88 ) begin
			$display( "[ERROR] block erase touched outside 200000h-20FFFFh" );
			errors = errors + 1;
		end
		io_write( 8'h46, 8'h07 );
		expect_read( 8'h42, 8'hFE, "reserved command ignored" );
		rom_read( 24'h123456, 8'hA5, "ROM read after status commands" );
		stage_end( "ROM write / sector(64KB block) erase commands" );

		stage_begin;
		io_write( 8'h4A, 8'h00 );
		for( p = 0; p < 256; p = p + 1 ) io_write( 8'h48, p[7:0] ^ 8'hA5 );
		expect_read( 8'h4A, 8'h00, "buffer index wraps" );
		io_write( 8'h49, 8'hFF );
		set_rom_address( 24'h220000 );
		page_programs = mon_programs;
		io_write( 8'h46, 8'h05 );
		rom_wait_ready( "page program 256" );
		expect_read( 8'h4E, 8'h00, "page program accepted" );
		if( mon_programs != page_programs + 1 ) $fatal( 1, "Page was not one Program frame" );
		for( p = 0; p < 256; p = p + 1 ) begin
			if( u_flash.memory[24'h220000 + p] !== (p[7:0] ^ 8'hA5) )
				$fatal( 1, "Page memory mismatch at offset %0d", p );
		end
		// Destroy the CPU buffer before reading back from the Flash.
		for( p = 0; p < 256; p = p + 1 ) io_write( 8'h48, 8'h00 );
		io_write( 8'h47, 8'h73 );
		page_reads = mon_reads;
		io_write( 8'h46, 8'h06 );
		expect_read( 8'h4E, 8'h00, "page read accepted" );
		if( mon_reads != page_reads + 1 ) $fatal( 1, "Page read was not one Fast Read frame" );
		io_write( 8'h4A, 8'h00 );
		for( p = 0; p < 256; p = p + 1 ) expect_read( 8'h48, p[7:0] ^ 8'hA5, "page read buffer" );
		expect_read( 8'h47, 8'h73, "page read preserves legacy data" );
		expect_read( 8'h43, 8'h00, "page address unchanged L" );
		expect_read( 8'h44, 8'h00, "page address unchanged M" );
		expect_read( 8'h45, 8'h22, "page address unchanged H" );

		set_rom_address( 24'h2200FF );
		io_write( 8'h49, 8'h01 );
		page_programs = mon_programs;
		page_reads = mon_reads;
		io_write( 8'h46, 8'h05 );
		expect_read( 8'h4E, 8'h01, "cross-page program rejected" );
		io_write( 8'h46, 8'h06 );
		expect_read( 8'h4E, 8'h01, "cross-page read rejected" );
		if( mon_programs != page_programs || mon_reads != page_reads )
			$fatal( 1, "Rejected command touched Flash" );

		// Nonaligned partial page ending at FFh and a one-byte next page.
		set_rom_address( 24'h22FFF3 );
		io_write( 8'h49, 8'd12 );
		io_write( 8'h4A, 8'h00 );
		for( p = 0; p < 13; p = p + 1 ) io_write( 8'h48, p[7:0] + 8'h31 );
		io_write( 8'h46, 8'h05 );
		rom_wait_ready( "partial page program" );
		expect_read( 8'h4E, 8'h00, "valid page clears rejection" );
		io_write( 8'h46, 8'h06 );
		io_write( 8'h4A, 8'h00 );
		for( p = 0; p < 13; p = p + 1 ) expect_read( 8'h48, p[7:0] + 8'h31, "partial page read" );
		rom_read( 24'h22FFF2, 8'hFF, "partial page preceding byte intact" );
		rom_read( 24'h230000, 8'hFF, "partial page following byte intact" );
		set_rom_address( 24'h230000 );
		io_write( 8'h49, 8'h00 );
		io_write( 8'h4A, 8'h00 );
		io_write( 8'h48, 8'h69 );
		io_write( 8'h46, 8'h05 );
		rom_wait_ready( "one byte page program" );
		io_write( 8'h46, 8'h06 );
		io_write( 8'h4A, 8'h00 );
		expect_read( 8'h48, 8'h69, "one byte page read" );
		stage_end( "page transfers: 256 bytes, partial, boundary rejection, single byte" );

		stage_begin;
		io_write( 8'h46, 8'h03 );
		rom_wait_ready( "chip erase" );
		rom_read( 24'h123456, 8'hFF, "chip erase middle" );
		rom_read( 24'h7F0000, 8'hFF, "chip erase upper" );
		stage_end( "ROM chip erase command" );

		//	---- deselect / disable ----
		stage_begin;
		io_write( 8'h41, 8'h03 );
		for( p = 8'h41; p <= 8'h4F; p = p + 1 ) expect_no_response( p[7:0], "devsel=03h" );
		io_write( 8'h41, 8'h01 );
		expect_read( 8'h42, 8'hFF, "function cleared by deselect" );
		io_write( 8'h42, 8'h01 );
		expect_read( 8'h42, 8'hFE, "function reselected" );
		io_write( 8'h40, 8'h00 );
		expect_all_silent( "disabled again" );
		io_write( 8'h40, 8'h80 );
		expect_read( 8'h40, 8'h7F, "re-enabled" );
		expect_no_response( 8'h41, "devsel cleared by disable" );
		stage_end( "deselect / disable" );

		if( errors == 0 ) begin
			test_passed = 1;
			$display( "[RESULT] ALL TESTS PASSED" );
		end
		else begin
			$fatal( 1, "[RESULT] %0d ERROR(S)", errors );
		end
		$finish;
	end

	initial begin
		#(64'd100_000_000_000);
		$fatal( 1, "Simulation timeout" );
	end
endmodule