//
//	system_controller.v
//	 System Controller
//
//	Copyright (C) 2026 Takayuki Hara
//
//	本ソフトウェアおよび本ソフトウェアに基づいて作成された派生物は、以下の条件を
//	満たす場合に限り、再頒布および使用が許可されます。
//
//	1.ソースコード形式で再頒布する場合、上記の著作権表示、本条件一覧、および下記
//	  免責条項をそのままの形で保持すること。
//	2.バイナリ形式で再頒布する場合、頒布物に付属のドキュメント等の資料に、上記の
//	  著作権表示、本条件一覧、および下記免責条項を含めること。
//	3.書面による事前の許可なしに、本ソフトウェアを販売、および商業的な製品や活動
//	  に使用しないこと。
//
//	本ソフトウェアは、著作権者によって「現状のまま」提供されています。著作権者は、
//	特定目的への適合性の保証、商品性の保証、またそれに限定されない、いかなる明示
//	的もしくは暗黙な保証責任も負いません。著作権者は、事由のいかんを問わず、損害
//	発生の原因いかんを問わず、かつ責任の根拠が契約であるか厳格責任であるか（過失
//	その他の）不法行為であるかを問わず、仮にそのような損害が発生する可能性を知ら
//	されていたとしても、本ソフトウェアの使用によって発生した（代替品または代用サ
//	ービスの調達、使用の喪失、データの喪失、利益の喪失、業務の中断も含め、またそ
//	れに限定されない）直接損害、間接損害、偶発的な損害、特別損害、懲罰的損害、ま
//	たは結果損害について、一切責任を負わないものとします。
//
//	Note that above Japanese version license is the formal document.
//	The following translation is only for reference.
//
//	Redistribution and use of this software or any derivative works,
//	are permitted provided that the following conditions are met:
//
//	1. Redistributions of source code must retain the above copyright
//	   notice, this list of conditions and the following disclaimer.
//	2. Redistributions in binary form must reproduce the above
//	   copyright notice, this list of conditions and the following
//	   disclaimer in the documentation and/or other materials
//	   provided with the distribution.
//	3. Redistributions may not be sold, nor may they be used in a
//	   commercial product or activity without specific prior written
//	   permission.
//
//	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//	"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//	LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//	FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
//	COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
//	INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
//	BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//	LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//	CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//	LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
//	ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//	POSSIBILITY OF SUCH DAMAGE.
//
//-----------------------------------------------------------------------------

module system_controller#(
	parameter		device_id = 8'h01
) (
	input			clk,
	input			reset_n,
	input			bus_cs,
	input	[3:0]	bus_address,
	input			bus_valid,
	output			bus_ready,
	input			bus_write,
	input	[7:0]	bus_wdata,
	output	[7:0]	bus_rdata,
	output			bus_rdata_en,
	output			rom_bus_address,
	output			rom_bus_valid,
	input			rom_bus_ready,
	output			rom_bus_write,
	output	[7:0]	rom_bus_wdata,
	input	[7:0]	rom_bus_rdata,
	input			rom_bus_rdata_en
);
	//	I/O 40h-4Fh (see doc/spec/system_controller.md)
	localparam		c_io_enabler			= 4'h0;		//	40h
	localparam		c_io_devsel				= 4'h1;		//	41h
	localparam		c_io_function			= 4'h2;		//	42h
	localparam		c_io_address_l			= 4'h3;		//	43h
	localparam		c_io_address_m			= 4'h4;		//	44h
	localparam		c_io_address_h			= 4'h5;		//	45h
	localparam		c_io_command			= 4'h6;		//	46h
	localparam		c_io_data				= 4'h7;		//	47h

	localparam		c_enable_key			= 8'h80;
	localparam		c_function_rom			= 8'h01;	//	Config ROM Reader/Writer

	localparam		c_command_read			= 8'h00;
	localparam		c_command_write			= 8'h01;
	localparam		c_command_sector_erase	= 8'h02;
	localparam		c_command_all_erase		= 8'h03;
	localparam		c_command_read_status	= 8'h04;

	//	Config ROM Reader/Writer sequencer (issues ip_spi_rom command lists)
	localparam	[2:0]	c_rs_idle				= 3'd0;
	localparam	[2:0]	c_rs_issue				= 3'd1;
	localparam	[2:0]	c_rs_gap				= 3'd2;
	localparam	[2:0]	c_rs_read_wait			= 3'd3;
	localparam	[2:0]	c_rs_finish				= 3'd4;

	localparam	[2:0]	c_src_const				= 3'd0;
	localparam	[2:0]	c_src_address_l			= 3'd1;
	localparam	[2:0]	c_src_address_m			= 3'd2;
	localparam	[2:0]	c_src_address_h			= 3'd3;
	localparam	[2:0]	c_src_data				= 3'd4;

	reg				ff_enable;
	reg				ff_devsel;
	reg				ff_func_rom;
	reg		[23:0]	ff_address;
	reg		[7:0]	ff_data;
	reg		[7:0]	ff_rdata;
	reg				ff_rdata_en;
	reg		[2:0]	ff_rom_state;
	reg		[3:0]	ff_rom_step;
	reg		[2:0]	ff_rom_command;
	reg				ff_rom_bus_address;
	reg				ff_rom_bus_valid;
	reg				ff_rom_bus_write;
	reg		[7:0]	ff_rom_bus_wdata;
	wire			w_bus_accept = bus_cs & bus_valid & bus_ready;

	always @( posedge clk ) begin
		if( !reset_n ) begin
			ff_enable <= 1'b0;
		end
		else if( w_bus_accept && bus_write && bus_address == c_io_enabler ) begin
			ff_enable <= (bus_wdata == c_enable_key);
		end
	end

	always @( posedge clk ) begin
		if( !reset_n ) begin
			ff_devsel <= 1'b0;
		end
		else if( !ff_enable ) begin
			ff_devsel <= 1'b0;
		end
		else if( w_bus_accept && bus_write && bus_address == c_io_devsel ) begin
			ff_devsel <= (bus_wdata == device_id);
		end
	end

	wire			w_selected		= ff_enable & ff_devsel;
	wire			w_rom_selected	= w_selected & ff_func_rom;

	always @( posedge clk ) begin
		if( !reset_n ) begin
			ff_func_rom <= 1'b0;
		end
		else if( !w_selected ) begin
			ff_func_rom <= 1'b0;
		end
		else if( w_bus_accept && bus_write && bus_address == c_io_function ) begin
			ff_func_rom <= (bus_wdata == c_function_rom);
		end
	end

	always @( posedge clk ) begin
		if( !reset_n ) begin
			ff_address <= 24'd0;
		end
		else if( w_rom_selected && w_bus_accept && bus_write ) begin
			case( bus_address )
			c_io_address_l:		ff_address[ 7: 0] <= bus_wdata;
			c_io_address_m:		ff_address[15: 8] <= bus_wdata;
			c_io_address_h:		ff_address[23:16] <= bus_wdata;
			default:				;
			endcase
		end
	end

	always @( posedge clk ) begin
		if( !reset_n ) begin
			ff_data <= 8'd0;
		end
		else if( rom_bus_rdata_en && ff_rom_state == c_rs_read_wait ) begin
			ff_data <= rom_bus_rdata;
		end
		else if( w_rom_selected && w_bus_accept && bus_write && bus_address == c_io_data ) begin
			ff_data <= bus_wdata;
		end
	end

	//	Command list for each Config ROM command.
	//	  [13]   last step
	//	  [12]   rom_bus_write
	//	  [11]   rom_bus_address (0: command port, 1: data port)
	//	  [10:8] wdata source
	//	  [7:0]  constant wdata
	function [13:0] f_rom_step;
		input	[2:0]	command;
		input	[3:0]	step;
		begin
			case( step )
			4'd0:		f_rom_step = { 1'b0, 1'b1, 1'b0, c_src_const,     8'h06 };	//	select serial ROM
			4'd1:		f_rom_step = { 1'b0, 1'b1, 1'b1, c_src_const,     8'h00 };
			4'd2:		f_rom_step = { 1'b0, 1'b1, 1'b0, c_src_const,     8'h00 };	//	set address
			4'd3:		f_rom_step = { 1'b0, 1'b1, 1'b1, c_src_address_l, 8'h00 };
			4'd4:		f_rom_step = { 1'b0, 1'b1, 1'b1, c_src_address_m, 8'h00 };
			4'd5:		f_rom_step = { 1'b0, 1'b1, 1'b1, c_src_address_h, 8'h00 };
			default:
				case( { command, step } )
				//	read: single read + data port read
				{ c_command_read[2:0],         4'd6 }:	f_rom_step = { 1'b0, 1'b1, 1'b0, c_src_const, 8'h01 };
				{ c_command_read[2:0],         4'd7 }:	f_rom_step = { 1'b1, 1'b0, 1'b1, c_src_const, 8'h00 };
				//	write: burst write (WREN + Page Program) + 1byte + access end
				{ c_command_write[2:0],        4'd6 }:	f_rom_step = { 1'b0, 1'b1, 1'b0, c_src_const, 8'h03 };
				{ c_command_write[2:0],        4'd7 }:	f_rom_step = { 1'b0, 1'b1, 1'b1, c_src_data,  8'h00 };
				{ c_command_write[2:0],        4'd8 }:	f_rom_step = { 1'b1, 1'b1, 1'b0, c_src_const, 8'h07 };
				//	sector erase: write enable + block erase (64KB)
				{ c_command_sector_erase[2:0], 4'd6 }:	f_rom_step = { 1'b0, 1'b1, 1'b0, c_src_const, 8'h08 };
				{ c_command_sector_erase[2:0], 4'd7 }:	f_rom_step = { 1'b1, 1'b1, 1'b0, c_src_const, 8'h09 };
				//	chip erase: chip erase mode + data port write (WREN + 60h)
				{ c_command_all_erase[2:0],    4'd6 }:	f_rom_step = { 1'b0, 1'b1, 1'b0, c_src_const, 8'h04 };
				{ c_command_all_erase[2:0],    4'd7 }:	f_rom_step = { 1'b1, 1'b1, 1'b1, c_src_const, 8'h00 };
				//	read status: read status register 1 + data port read + access end
				{ c_command_read_status[2:0],  4'd6 }:	f_rom_step = { 1'b0, 1'b1, 1'b0, c_src_const, 8'h05 };
				{ c_command_read_status[2:0],  4'd7 }:	f_rom_step = { 1'b0, 1'b0, 1'b1, c_src_const, 8'h00 };
				{ c_command_read_status[2:0],  4'd8 }:	f_rom_step = { 1'b1, 1'b1, 1'b0, c_src_const, 8'h07 };
				default:								f_rom_step = { 1'b1, 1'b1, 1'b0, c_src_const, 8'h07 };	//	access end
				endcase
			endcase
		end
	endfunction

	wire	[13:0]	w_rom_step		= f_rom_step( ff_rom_command, ff_rom_step );
	wire			w_rom_step_last	= w_rom_step[13];
	wire			w_rom_step_read	= ~w_rom_step[12];
	reg		[7:0]	w_rom_step_wdata;

	always @(*) begin
		case( w_rom_step[10:8] )
		c_src_address_l:	w_rom_step_wdata = ff_address[ 7: 0];
		c_src_address_m:	w_rom_step_wdata = ff_address[15: 8];
		c_src_address_h:	w_rom_step_wdata = ff_address[23:16];
		c_src_data:			w_rom_step_wdata = ff_data;
		default:			w_rom_step_wdata = w_rom_step[7:0];
		endcase
	end

	//	Write and erase only issue the commands. Completion is checked by the MSX
	//	software (polling bit0 (BUSY) of the read status command).
	//	ip_spi_rom drops ready one clock after accepting a command,
	//	so every command is followed by a gap cycle before ready is checked again.
	always @( posedge clk ) begin
		if( !reset_n ) begin
			ff_rom_state		<= c_rs_idle;
			ff_rom_step			<= 4'd0;
			ff_rom_command		<= 3'd0;
			ff_rom_bus_address	<= 1'b0;
			ff_rom_bus_valid	<= 1'b0;
			ff_rom_bus_write	<= 1'b0;
			ff_rom_bus_wdata	<= 8'd0;
		end
		else begin
			ff_rom_bus_valid <= 1'b0;
			case( ff_rom_state )
			c_rs_idle: begin
				if( w_rom_selected && w_bus_accept && bus_write && bus_address == c_io_command && bus_wdata <= c_command_read_status ) begin
					ff_rom_command	<= bus_wdata[2:0];
					ff_rom_step		<= 4'd0;
					ff_rom_state	<= c_rs_issue;
				end
			end
			c_rs_issue: begin
				if( rom_bus_ready ) begin
					ff_rom_bus_address	<= w_rom_step[11];
					ff_rom_bus_write	<= w_rom_step[12];
					ff_rom_bus_wdata	<= w_rom_step_wdata;
					ff_rom_bus_valid	<= 1'b1;
					ff_rom_state		<= c_rs_gap;
				end
			end
			c_rs_gap: begin
				if( w_rom_step_read ) begin
					ff_rom_state	<= c_rs_read_wait;
				end
				else if( !w_rom_step_last ) begin
					ff_rom_step		<= ff_rom_step + 4'd1;
					ff_rom_state	<= c_rs_issue;
				end
				else begin
					ff_rom_state	<= c_rs_finish;
				end
			end
			c_rs_read_wait: begin
				if( rom_bus_rdata_en ) begin
					if( w_rom_step_last ) begin
						ff_rom_state	<= c_rs_finish;
					end
					else begin
						ff_rom_step		<= ff_rom_step + 4'd1;
						ff_rom_state	<= c_rs_issue;
					end
				end
			end
			c_rs_finish: begin
				if( rom_bus_ready ) begin
					ff_rom_state	<= c_rs_idle;
				end
			end
			default: begin
				ff_rom_state	<= c_rs_idle;
			end
			endcase
		end
	end
	//	Read response. Addresses that must not respond (to avoid bus contention
	//	with other devices) keep bus_rdata_en low.
	reg		[7:0]	w_rdata;
	reg				w_rdata_hit;

	always @(*) begin
		w_rdata		= 8'hFF;
		w_rdata_hit	= 1'b0;
		case( bus_address )
		c_io_enabler: begin
			w_rdata		= ~c_enable_key;
			w_rdata_hit	= ff_enable;
		end
		c_io_devsel: begin
			w_rdata		= ~device_id[7:0];
			w_rdata_hit	= w_selected;
		end
		c_io_function: begin
			w_rdata		= ff_func_rom ? ~c_function_rom : 8'hFF;
			w_rdata_hit	= w_selected;
		end
		c_io_address_l: begin
			w_rdata		= ff_address[ 7: 0];
			w_rdata_hit	= w_rom_selected;
		end
		c_io_address_m: begin
			w_rdata		= ff_address[15: 8];
			w_rdata_hit	= w_rom_selected;
		end
		c_io_address_h: begin
			w_rdata		= ff_address[23:16];
			w_rdata_hit	= w_rom_selected;
		end
		c_io_command: begin
			w_rdata		= 8'hFF;
			w_rdata_hit	= w_rom_selected;
		end
		c_io_data: begin
			w_rdata		= ff_data;
			w_rdata_hit	= w_rom_selected;
		end
		default: begin
			//	48h-4Fh: reserved
		end
		endcase
	end

	always @( posedge clk ) begin
		if( !reset_n ) begin
			ff_rdata	<= 8'hFF;
			ff_rdata_en	<= 1'b0;
		end
		else if( w_bus_accept && !bus_write && w_rdata_hit ) begin
			ff_rdata	<= w_rdata;
			ff_rdata_en	<= 1'b1;
		end
		else begin
			ff_rdata	<= 8'hFF;
			ff_rdata_en	<= 1'b0;
		end
	end

	assign bus_ready				= (ff_rom_state == c_rs_idle);
	assign bus_rdata				= ff_rdata;
	assign bus_rdata_en				= ff_rdata_en;

	assign rom_bus_address			= ff_rom_bus_address;
	assign rom_bus_valid			= ff_rom_bus_valid;
	assign rom_bus_write			= ff_rom_bus_write;
	assign rom_bus_wdata			= ff_rom_bus_wdata;

endmodule
