////////////////////////////////////////////////////////////////////////////////
//
// Filename: ddr3_top_wukong.v
// Project:  UberDDR3 - An Open Source DDR3 Controller (Wukong board adaptation)
//
// Purpose: Top-level DDR3 controller integration for the Wukong FPGA board.
//          Substantially rewritten from ddr3_top.v from the UberDDR3 project.
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2023-2024  Angelo Jacobo (original ddr3_top.v)
//
//     This program is free software: you can redistribute it and/or modify
//     it under the terms of the GNU General Public License as published by
//     the Free Software Foundation, either version 3 of the License, or
//     (at your option) any later version.
//
//     This program is distributed in the hope that it will be useful,
//     but WITHOUT ANY WARRANTY; without even the implied warranty of
//     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//     GNU General Public License for more details.
//
//     You should have received a copy of the GNU General Public License
//     along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ps / 1ps

module ddr3_top_wukong #(
        // ps, clock period of the controller interface
        parameter CONTROLLER_CLK_PERIOD = 12_000,
        // ps, clock period of the DDR3 RAM device (must be 1/4 of the CONTROLLER_CLK_PERIOD)
        parameter DDR3_CLK_PERIOD = 3_000
    )
    (
        //i_controller_clk = CONTROLLER_CLK_PERIOD, i_ddr3_clk = DDR3_CLK_PERIOD, i_ref_clk = 200MHz
        input wire i_controller_clk,
        input wire i_ddr3_clk,
        input wire i_ref_clk,
        input wire i_ddr3_clk_90, //required only when ODELAY_SUPPORTED is zero
        input wire i_rst_n,
        //
        // Wishbone inputs
        input wire i_wb_cyc, //bus cycle active (1 = normal operation, 0 = all ongoing transaction are to be cancelled)
        input wire i_wb_stb, //request a transfer
        input wire i_wb_we, //write-enable (1 = write, 0 = read)
        input wire[24 - 1:0] i_wb_addr, //burst-addressable {row,bank,col}
        input wire[128 - 1:0] i_wb_data, //write data, for a 4:1 controller data width is 8 times the number of pins on the device
        input wire[16 - 1:0] i_wb_sel, //byte strobe for write (1 = write the byte)
        // Wishbone outputs
        output wire o_wb_stall, //1 = busy, cannot accept requests
        output wire o_wb_ack, //1 = read/write request has completed
        output wire o_wb_err, //1 = Error due to ECC double bit error (fixed to 0 if WB_ERROR = 0)
        output wire[128 - 1:0] o_wb_data, //read data, for a 4:1 controller data width is 8 times the number of pins on the device
        //
        // DDR3 I/O Interface
        output wire o_ddr3_clk_p, o_ddr3_clk_n,
        output wire o_ddr3_reset_n,
        output wire o_ddr3_cke, // CKE
        output wire o_ddr3_cs_n, // chip select signal
        output wire o_ddr3_ras_n, // RAS#
        output wire o_ddr3_cas_n, // CAS#
        output wire o_ddr3_we_n, // WE#
        output wire[14-1:0] o_ddr3_addr,
        output wire[3-1:0] o_ddr3_ba_addr,
        inout wire[(8*2)-1:0] io_ddr3_dq,
        inout wire[2-1:0] io_ddr3_dqs, io_ddr3_dqs_n,
        output wire[2-1:0] o_ddr3_dm,
        output wire o_ddr3_odt, // on-die termination
        //
        // Done Calibration pin
        output wire o_calib_complete,
        // Debug outputs
        output wire[31:0] o_debug1
    );
    
    localparam ROW_BITS = 14; //width of row address
    localparam COL_BITS = 10; //width of column address
    localparam BA_BITS = 3; //width of bank address
    localparam DQ_BITS = 8; //width of bank address
    localparam LANES = 2; //number of byte lanes of DDR3 RAM
    localparam AUX_WIDTH = 4; //width of aux line (must be >= 4)
    localparam ODELAY_SUPPORTED = 0; //set to 1 when ODELAYE2 is supported

    // Wire connections between controller and phy
    wire[96-1:0] cmd;
    wire dqs_tri_control, dq_tri_control;
    wire toggle_dqs;
    wire[128-1:0] data;
    wire[16-1:0] dm;
    wire[LANES-1:0] bitslip;
    wire[DQ_BITS*LANES*8-1:0] iserdes_data;
    wire[LANES*8-1:0] iserdes_dqs;
    wire[LANES*8-1:0] iserdes_bitslip_reference;
    wire idelayctrl_rdy;
    wire[4:0] odelay_data_cntvaluein, odelay_dqs_cntvaluein;
    wire[4:0] idelay_data_cntvaluein, idelay_dqs_cntvaluein;
    wire[LANES-1:0] odelay_data_ld, odelay_dqs_ld;
    wire[LANES-1:0] idelay_data_ld, idelay_dqs_ld;
    wire write_leveling_calib;
    wire reset;
    
    //module instantiations
    ddr3_controller #(
            .CONTROLLER_CLK_PERIOD(CONTROLLER_CLK_PERIOD), //ps, clock period of the controller interface
            .DDR3_CLK_PERIOD(DDR3_CLK_PERIOD), //ps, clock period of the DDR3 RAM device (must be 1/4 of the CONTROLLER_CLK_PERIOD) 
            .ROW_BITS(ROW_BITS), //width of row address
            .COL_BITS(COL_BITS), //width of column address
            .BA_BITS(BA_BITS), //width of bank address
            .DQ_BITS(DQ_BITS),  //width of DQ
            .LANES(LANES), // byte lanes
            .AUX_WIDTH(AUX_WIDTH), //width of aux line (must be >= 4) 
            .MICRON_SIM(0), //simulation for micron ddr3 model (shorten POWER_ON_RESET_HIGH and INITIAL_CKE_LOW)
            .ODELAY_SUPPORTED(ODELAY_SUPPORTED),  //set to 1 when ODELAYE2 is supported
            .SECOND_WISHBONE(0), //set to 1 if 2nd wishbone is needed
            .ECC_ENABLE(0), // set to 1 or 2 to add ECC (1 = Side-band ECC per burst, 2 = Side-band ECC per 8 bursts , 3 = Inline ECC )
            .WB_ERROR(0), // set to 1 to support Wishbone error (asserts at ECC double bit error)
            .SKIP_INTERNAL_TEST(0)
        ) ddr3_controller_inst (
            .i_controller_clk(i_controller_clk), //i_controller_clk has period of CONTROLLER_CLK_PERIOD 
            .i_rst_n(i_rst_n), //200MHz input clock
            // Wishbone inputs
            .i_wb_cyc(i_wb_cyc), //bus cycle active (1 = normal operation, 0 = all ongoing transaction are to be cancelled)
            .i_wb_stb(i_wb_stb), //request a transfer
            .i_wb_we(i_wb_we), //write-enable (1 = write, 0 = read)
            .i_wb_addr(i_wb_addr), //burst-addressable {row,bank,col} 
            .i_wb_data(i_wb_data), //write data, for a 4:1 controller data width is 8 times the number of pins on the device
            .i_wb_sel(i_wb_sel), //byte strobe for write (1 = write the byte)
            .i_aux(i_wb_we), //for AXI-interface compatibility (given upon strobe)
            // Wishbone outputs
            .o_wb_stall(o_wb_stall), //1 = busy, cannot accept requests
            .o_wb_ack(o_wb_ack), //1 = read/write request has completed
            .o_wb_err(o_wb_err), //1 = Error due to ECC double bit error (fixed to 0 if WB_ERROR = 0)
            .o_wb_data(o_wb_data), //read data, for a 4:1 controller data width is 8 times the number of pins on the device
            .o_aux(), //for AXI-interface compatibility (returned upon ack)
            // Wishbone 2 (PHY) inputs
            .i_wb2_cyc(1'd0), //bus cycle active (1 = normal operation, 0 = all ongoing transaction are to be cancelled)
            .i_wb2_stb(1'd0), //request a transfer
            .i_wb2_we(1'd0), //write-enable (1 = write, 0 = read)
            .i_wb2_addr(24'd0), // memory-mapped register to be accessed
            .i_wb2_data(128'd0), //write data
            .i_wb2_sel(16'd0), //byte strobe for write (1 = write the byte)
            // Wishbone 2 (Controller) outputs
            .o_wb2_stall(), //1 = busy, cannot accept requests
            .o_wb2_ack(), //1 = read/write request has completed
            .o_wb2_data(), //read data
            //
            // PHY interface
            .i_phy_iserdes_data(iserdes_data),
            .i_phy_iserdes_dqs(iserdes_dqs),
            .i_phy_iserdes_bitslip_reference(iserdes_bitslip_reference),
            .i_phy_idelayctrl_rdy(idelayctrl_rdy),
            .o_phy_cmd(cmd),
            .o_phy_dqs_tri_control(dqs_tri_control), 
            .o_phy_dq_tri_control(dq_tri_control),
            .o_phy_toggle_dqs(toggle_dqs),
            .o_phy_data(data),
            .o_phy_dm(dm),
            .o_phy_odelay_data_cntvaluein(odelay_data_cntvaluein),
            .o_phy_odelay_dqs_cntvaluein(odelay_dqs_cntvaluein),
            .o_phy_idelay_data_cntvaluein(idelay_data_cntvaluein), 
            .o_phy_idelay_dqs_cntvaluein(idelay_dqs_cntvaluein),
            .o_phy_odelay_data_ld(odelay_data_ld),
            .o_phy_odelay_dqs_ld(odelay_dqs_ld),
            .o_phy_idelay_data_ld(idelay_data_ld), 
            .o_phy_idelay_dqs_ld(idelay_dqs_ld),
            .o_phy_bitslip(bitslip),
            .o_phy_write_leveling_calib(write_leveling_calib),
            .o_phy_reset(reset),
            // Done Calibration pin
            .o_calib_complete(o_calib_complete),
            // Debug outputs
            .o_debug1(o_debug1)
        );
        
    ddr3_phy #(
            .ROW_BITS(ROW_BITS), //width of row address
            .BA_BITS(BA_BITS), //width of bank address
            .DQ_BITS(DQ_BITS),  //width of DQ
            .LANES(LANES), //8 lanes of DQ
            .CONTROLLER_CLK_PERIOD(CONTROLLER_CLK_PERIOD), //ps, period of clock input to this DDR3 controller module
            .DDR3_CLK_PERIOD(DDR3_CLK_PERIOD), //ps, period of clock input to DDR3 RAM device 
            .ODELAY_SUPPORTED(ODELAY_SUPPORTED)
        ) ddr3_phy_inst (
            .i_controller_clk(i_controller_clk), 
            .i_ddr3_clk(i_ddr3_clk),
            .i_ref_clk(i_ref_clk),
            .i_ddr3_clk_90(i_ddr3_clk_90), 
            .i_rst_n(i_rst_n),
            // Controller Interface
            .i_controller_reset(reset),
            .i_controller_cmd(cmd),
            .i_controller_dqs_tri_control(dqs_tri_control), 
            .i_controller_dq_tri_control(dq_tri_control),
            .i_controller_toggle_dqs(toggle_dqs),
            .i_controller_data(data),
            .i_controller_dm(dm),
            .i_controller_odelay_data_cntvaluein(odelay_data_cntvaluein),
            .i_controller_odelay_dqs_cntvaluein(odelay_dqs_cntvaluein),
            .i_controller_idelay_data_cntvaluein(idelay_data_cntvaluein),
            .i_controller_idelay_dqs_cntvaluein(idelay_dqs_cntvaluein),
            .i_controller_odelay_data_ld(odelay_data_ld), 
            .i_controller_odelay_dqs_ld(odelay_dqs_ld),
            .i_controller_idelay_data_ld(idelay_data_ld), 
            .i_controller_idelay_dqs_ld(idelay_dqs_ld),
            .i_controller_bitslip(bitslip),
            .i_controller_write_leveling_calib(write_leveling_calib),
            .o_controller_iserdes_data(iserdes_data),
            .o_controller_iserdes_dqs(iserdes_dqs),
            .o_controller_iserdes_bitslip_reference(iserdes_bitslip_reference),
            .o_controller_idelayctrl_rdy(idelayctrl_rdy),
            // DDR3 I/O Interface
            .o_ddr3_clk_p(o_ddr3_clk_p),
            .o_ddr3_clk_n(o_ddr3_clk_n),
            .o_ddr3_reset_n(o_ddr3_reset_n),
            .o_ddr3_cke(o_ddr3_cke), // CKE
            .o_ddr3_cs_n(o_ddr3_cs_n), // chip select signal
            .o_ddr3_ras_n(o_ddr3_ras_n), // RAS#
            .o_ddr3_cas_n(o_ddr3_cas_n), // CAS#
            .o_ddr3_we_n(o_ddr3_we_n), // WE#
            .o_ddr3_addr(o_ddr3_addr),
            .o_ddr3_ba_addr(o_ddr3_ba_addr),
            .io_ddr3_dq(io_ddr3_dq),
            .io_ddr3_dqs(io_ddr3_dqs),
            .io_ddr3_dqs_n(io_ddr3_dqs_n),
            .o_ddr3_dm(o_ddr3_dm),
            .o_ddr3_odt(o_ddr3_odt), // on-die termination
            .o_ddr3_debug_read_dqs_p(/*o_ddr3_debug_read_dqs_p*/),
            .o_ddr3_debug_read_dqs_n(/*o_ddr3_debug_read_dqs_n*/)
        );
        
endmodule
