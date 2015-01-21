///////////////////////////////////////////////////////////////////////////////
//
// Module: ap_lookup.v
///////////////////////////////////////////////////////////////////////////////
`include "onet_defines.v"

  module ap_lookup
    #(parameter NUM_OUTPUT_QUEUES = 8,                  // obvious
      parameter DATA_WIDTH = 64,
      parameter F3_HEADER_WIDTH = 400,
      parameter F3_HEADER_WIDTH_BITS = log2(F3_HEADER_WIDTH),
      parameter OLD_HEADER_WIDTH = 432,
      parameter OLD_HEADER_WIDTH_BITS = log2(OLD_HEADER_WIDTH),
      parameter AP_WIDTH = 16,
      parameter ACTION_WIDTH_1 = `F3_ACTION_WIDTH,
      parameter APT_DEPTH_1 = `ACTION_TABLE_SIZE,
      //parameter ACTION_WIDTH_2 = `ACTION_WIDTH_2,
      //parameter APT_DEPTH_2 = `AP_TABLE_SIZE_2,
      //parameter ACTION_WIDTH_3 = `ACTION_WIDTH_3,
      //parameter APT_DEPTH_3 = `AP_TABLE_SIZE_3,
      //parameter ACTION_WIDTH_4 = `ACTION_WIDTH_4,
      //parameter APT_DEPTH_4 = `AP_TABLE_SIZE_4,
      //parameter ACTION_WIDTH_5 = `ACTION_WIDTH_5,
      //parameter APT_DEPTH_5 = `AP_TABLE_SIZE_5,
      parameter UDP_REG_SRC_WIDTH = 2,                  // identifies which module started this request
      parameter REG_ADDR_WIDTH = 10                      // Width of addresses in the same block
      )
   (
   // --- Interface to header_parser
   input                                     all_vld,
   input [DATA_WIDTH-1:0]                    module_hdr,
   input [AP_WIDTH-1:0]                      first_ap,
   input [F3_HEADER_WIDTH-1:0]               f3_header,
   input [F3_HEADER_WIDTH_BITS-1:0]          f3_header_len,
   input [OLD_HEADER_WIDTH-1:0]              old_header,
   input [OLD_HEADER_WIDTH_BITS-1:0]         old_header_len,
   input                                     is_ip,
   input                                     is_arp,
   input                                     is_icmp,
   input                                     is_tcp,
   input                                     is_udp,
   // --- Interface to combiner
   input                                     result_fifo_rd_en,
   output                                    result_fifo_empty,
   output [DATA_WIDTH-1:0]                   module_hdr_out,
   output [F3_HEADER_WIDTH-1:0]              f3_header_out,
   output [F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_out,
   output [OLD_HEADER_WIDTH-1:0]             old_header_out,
   output [OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_out,

   // --- Interface to registers
   input                                     reg_req_in,
   input                                     reg_ack_in,
   input                                     reg_rd_wr_L_in,
   input  [`UDP_REG_ADDR_WIDTH-1:0]          reg_addr_in,
   input  [`CPCI_NF2_DATA_WIDTH-1:0]         reg_data_in,
   input  [UDP_REG_SRC_WIDTH-1:0]            reg_src_in,
   
   output                                    reg_req_out,
   output                                    reg_ack_out,
   output                                    reg_rd_wr_L_out,
   output [`UDP_REG_ADDR_WIDTH-1:0]          reg_addr_out,
   output [`CPCI_NF2_DATA_WIDTH-1:0]         reg_data_out,
   output [UDP_REG_SRC_WIDTH-1:0]            reg_src_out,

   // --- Misc
   input                                  reset,
   input                                  clk
   );
   `LOG2_FUNC
   `CEILDIV_FUNC
   //------------------ Internal Parameter ---------------------------
   localparam RESET           = 0;
   localparam WAIT_FOR_INPUT  = 1;

   //---------------------- Wires/Regs -------------------------------
   wire                                   output_vld_1;
   wire [AP_WIDTH-1:0]                    ap_out_1;
   wire[DATA_WIDTH-1:0]                   module_hdr_1;
   wire[F3_HEADER_WIDTH-1:0]              f3_header_1;
   wire[F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_1;
   wire[OLD_HEADER_WIDTH-1:0]             old_header_1;
   wire[OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_1;

   /*
   wire                                   output_vld_2;
   wire[AP_WIDTH-1:0]                     ap_out_2;
   wire[DATA_WIDTH-1:0]                   module_hdr_2;
   wire[F3_HEADER_WIDTH-1:0]              f3_header_2;
   wire[F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_2;
   wire[OLD_HEADER_WIDTH-1:0]             old_header_2;
   wire[OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_2;

   wire                                   output_vld_3;
   wire[AP_WIDTH-1:0]                     ap_out_3;
   wire[DATA_WIDTH-1:0]                   module_hdr_3;
   wire[F3_HEADER_WIDTH-1:0]              f3_header_3;
   wire[F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_3;
   wire[OLD_HEADER_WIDTH-1:0]             old_header_3;
   wire[OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_3;

   wire                                   output_vld_4;
   wire [AP_WIDTH-1:0]                    ap_out_4;
   wire[DATA_WIDTH-1:0]                   module_hdr_4;
   wire[F3_HEADER_WIDTH-1:0]              f3_header_4;
   wire[F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_4;
   wire[OLD_HEADER_WIDTH-1:0]             old_header_4;
   wire[OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_4;

   wire                                   result_vld;
   //wire [AP_WIDTH-1:0]                    ap_out_5;
   wire[DATA_WIDTH-1:0]                   module_hdr_5;
   wire[F3_HEADER_WIDTH-1:0]              f3_header_5;
   wire[F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_5;
   wire[OLD_HEADER_WIDTH-1:0]             old_header_5;
   wire[OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_5;
   
      // --- For registers
   wire                                   reg_req_out_1;
   wire                                   reg_ack_out_1;
   wire                                   reg_rd_wr_L_out_1;
   wire [`UDP_REG_ADDR_WIDTH-1:0]         reg_addr_out_1;
   wire [`CPCI_NF2_DATA_WIDTH-1:0]        reg_data_out_1;
   wire [UDP_REG_SRC_WIDTH-1:0]           reg_src_out_1;

   wire                                   reg_req_out_2;
   wire                                   reg_ack_out_2;
   wire                                   reg_rd_wr_L_out_2;
   wire [`UDP_REG_ADDR_WIDTH-1:0]         reg_addr_out_2;
   wire [`CPCI_NF2_DATA_WIDTH-1:0]        reg_data_out_2;
   wire [UDP_REG_SRC_WIDTH-1:0]           reg_src_out_2;

   wire                                   reg_req_out_3;
   wire                                   reg_ack_out_3;
   wire                                   reg_rd_wr_L_out_3;
   wire [`UDP_REG_ADDR_WIDTH-1:0]         reg_addr_out_3;
   wire [`CPCI_NF2_DATA_WIDTH-1:0]        reg_data_out_3;
   wire [UDP_REG_SRC_WIDTH-1:0]           reg_src_out_3;

   wire                                   reg_req_out_4;
   wire                                   reg_ack_out_4;
   wire                                   reg_rd_wr_L_out_4;
   wire [`UDP_REG_ADDR_WIDTH-1:0]         reg_addr_out_4;
   wire [`CPCI_NF2_DATA_WIDTH-1:0]        reg_data_out_4;
   wire [UDP_REG_SRC_WIDTH-1:0]           reg_src_out_4;
*/
    //------------------------- Modules -------------------------------
   fallthrough_small_fifo #(.WIDTH(64+F3_HEADER_WIDTH+F3_HEADER_WIDTH_BITS+OLD_HEADER_WIDTH+OLD_HEADER_WIDTH_BITS), .MAX_DEPTH_BITS(3))
      ap_fifo
      (
      .din         ({module_hdr_1,f3_header_1,f3_header_len_1,old_header_1,old_header_len_1}),  // Data in
      .wr_en       (output_vld_1),          // Write enable
      .rd_en       (result_fifo_rd_en),   // Read the next word
      .dout        ({module_hdr_out,f3_header_out,f3_header_len_out,old_header_out,old_header_len_out}),
      .prog_full   (),
      .full        (),
      .nearly_full (),
      .empty       (result_fifo_empty),
      .reset       (reset),
      .clk         (clk)
      );

   ap_lookup_1
   #(
      .F3_HEADER_WIDTH(F3_HEADER_WIDTH),
      .OLD_HEADER_WIDTH (OLD_HEADER_WIDTH),
      .APT_DEPTH(APT_DEPTH_1),
      .OFFSET(0)
   ) ap_lookup_1
   (
      .ap_in                     (first_ap),
      .input_vld                 (all_vld),
      .module_hdr_in             (module_hdr),
      .f3_header_in              (f3_header),
      .f3_header_len_in          (f3_header_len),
      .old_header_in             (old_header),
      .old_header_len_in         (old_header_len),
      
      //.ap_out                    (ap_out_1),
      .output_vld                (output_vld_1),
      .module_hdr_out            (module_hdr_1),
      .f3_header_out             (f3_header_1),
      .f3_header_len_out         (f3_header_len_1),
      .old_header_out            (old_header_1),
      .old_header_len_out        (old_header_len_1),
      // --- Interface for registers
      .reg_req_in                (reg_req_in),
      .reg_ack_in                (reg_ack_in),
      .reg_rd_wr_L_in            (reg_rd_wr_L_in),
      .reg_addr_in               (reg_addr_in),
      .reg_data_in               (reg_data_in),
      .reg_src_in                (reg_src_in),
         
      .reg_req_out               (reg_req_out),
      .reg_ack_out               (reg_ack_out),
      .reg_rd_wr_L_out           (reg_rd_wr_L_out),
      .reg_addr_out              (reg_addr_out),
      .reg_data_out              (reg_data_out),
      .reg_src_out               (reg_src_out),
      
      // --- Misc
      .reset                     (reset),
      .clk                       (clk)
   );
/*
   ap_lookup_2
   #(
      .F3_HEADER_WIDTH(F3_HEADER_WIDTH),
      .OLD_HEADER_WIDTH (OLD_HEADER_WIDTH),
      .APT_DEPTH(APT_DEPTH_2),
      .OFFSET(APT_DEPTH_1)
   ) ap_lookup_2
   (
      .ap_in                     (ap_out_1),
      .input_vld                 (output_vld_1),
      .module_hdr_in             (module_hdr_1),
      .f3_header_in              (f3_header_1),
      .f3_header_len_in          (f3_header_len_1),
      .old_header_in             (old_header_1),
      .old_header_len_in         (old_header_len_1),
      
      .ap_out                    (ap_out_2),
      .output_vld                (output_vld_2),
      .module_hdr_out            (module_hdr_2),
      .f3_header_out             (f3_header_2),
      .f3_header_len_out         (f3_header_len_2),
      .old_header_out            (old_header_2),
      .old_header_len_out        (old_header_len_2),
      // --- Interface for registers
      .reg_req_in                (reg_req_out_1),
      .reg_ack_in                (reg_ack_out_1),
      .reg_rd_wr_L_in            (reg_rd_wr_L_out_1),
      .reg_addr_in               (reg_addr_out_1),
      .reg_data_in               (reg_data_out_1),
      .reg_src_in                (reg_src_out_1),
         
      .reg_req_out               (reg_req_out_2),
      .reg_ack_out               (reg_ack_out_2),
      .reg_rd_wr_L_out           (reg_rd_wr_L_out_2),
      .reg_addr_out              (reg_addr_out_2),
      .reg_data_out              (reg_data_out_2),
      .reg_src_out               (reg_src_out_2),
      
      // --- Misc
      .reset                     (reset),
      .clk                       (clk)
   );

   ap_lookup_3
   #(
      .F3_HEADER_WIDTH(F3_HEADER_WIDTH),
      .OLD_HEADER_WIDTH (OLD_HEADER_WIDTH),
      .APT_DEPTH(APT_DEPTH_3),
      .OFFSET(APT_DEPTH_1+APT_DEPTH_2)
   ) ap_lookup_3
   (
      .ap_in                     (ap_out_2),
      .input_vld                 (output_vld_2),
      .module_hdr_in             (module_hdr_2),
      .f3_header_in              (f3_header_2),
      .f3_header_len_in          (f3_header_len_2),
      .old_header_in             (old_header_2),
      .old_header_len_in         (old_header_len_2),
      
      .ap_out                    (ap_out_3),
      .output_vld                (output_vld_3),
      .module_hdr_out            (module_hdr_3),
      .f3_header_out             (f3_header_3),
      .f3_header_len_out         (f3_header_len_3),
      .old_header_out            (old_header_3),
      .old_header_len_out        (old_header_len_3),
      // --- Interface for registers
      .reg_req_in                (reg_req_out_2),
      .reg_ack_in                (reg_ack_out_2),
      .reg_rd_wr_L_in            (reg_rd_wr_L_out_2),
      .reg_addr_in               (reg_addr_out_2),
      .reg_data_in               (reg_data_out_2),
      .reg_src_in                (reg_src_out_2),
         
      .reg_req_out               (reg_req_out_3),
      .reg_ack_out               (reg_ack_out_3),
      .reg_rd_wr_L_out           (reg_rd_wr_L_out_3),
      .reg_addr_out              (reg_addr_out_3),
      .reg_data_out              (reg_data_out_3),
      .reg_src_out               (reg_src_out_3),
      
      // --- Misc
      .reset                     (reset),
      .clk                       (clk)
   );
   
   ap_lookup_4
   #(
      .F3_HEADER_WIDTH(F3_HEADER_WIDTH),
      .OLD_HEADER_WIDTH (OLD_HEADER_WIDTH),
      .APT_DEPTH(APT_DEPTH_4),
      .OFFSET(APT_DEPTH_1+APT_DEPTH_2+APT_DEPTH_3)
   ) ap_lookup_4
   (
      .ap_in                     (ap_out_3),
      .input_vld                 (output_vld_3),
      .module_hdr_in             (module_hdr_3),
      .f3_header_in              (f3_header_3),
      .f3_header_len_in          (f3_header_len_3),
      .old_header_in             (old_header_3),
      .old_header_len_in         (old_header_len_3),
      
      .ap_out                    (ap_out_4),
      .output_vld                (output_vld_4),
      .module_hdr_out            (module_hdr_4),
      .f3_header_out             (f3_header_4),
      .f3_header_len_out         (f3_header_len_4),
      .old_header_out            (old_header_4),
      .old_header_len_out        (old_header_len_4),
      // --- Interface for registers
      .reg_req_in                (reg_req_out_3),
      .reg_ack_in                (reg_ack_out_3),
      .reg_rd_wr_L_in            (reg_rd_wr_L_out_3),
      .reg_addr_in               (reg_addr_out_3),
      .reg_data_in               (reg_data_out_3),
      .reg_src_in                (reg_src_out_3),
         
      .reg_req_out               (reg_req_out_4),
      .reg_ack_out               (reg_ack_out_4),
      .reg_rd_wr_L_out           (reg_rd_wr_L_out_4),
      .reg_addr_out              (reg_addr_out_4),
      .reg_data_out              (reg_data_out_4),
      .reg_src_out               (reg_src_out_4),
      
      // --- Misc
      .reset                     (reset),
      .clk                       (clk)
   );

   ap_lookup_5
   #(
      .F3_HEADER_WIDTH(F3_HEADER_WIDTH),
      .OLD_HEADER_WIDTH (OLD_HEADER_WIDTH),
      .APT_DEPTH(APT_DEPTH_5),
      .OFFSET(APT_DEPTH_1+APT_DEPTH_2+APT_DEPTH_3+APT_DEPTH_3+APT_DEPTH_4)
   ) ap_lookup_5
   (
      .ap_in                     (ap_out_4),
      .input_vld                 (output_vld_4),
      .module_hdr_in             (module_hdr_4),
      .f3_header_in              (f3_header_4),
      .f3_header_len_in          (f3_header_len_4),
      .old_header_in             (old_header_4),
      .old_header_len_in         (old_header_len_4),
      
      //.ap_out                    (ap_out_5),
      .output_vld                (result_vld),
      .module_hdr_out            (module_hdr_5),
      .f3_header_out             (f3_header_5),
      .f3_header_len_out         (f3_header_len_5),
      .old_header_out            (old_header_5),
      .old_header_len_out        (old_header_len_5),
      // --- Interface for registers
      .reg_req_in                (reg_req_out_4),
      .reg_ack_in                (reg_ack_out_4),
      .reg_rd_wr_L_in            (reg_rd_wr_L_out_4),
      .reg_addr_in               (reg_addr_out_4),
      .reg_data_in               (reg_data_out_4),
      .reg_src_in                (reg_src_out_4),
         
      .reg_req_out               (reg_req_out),
      .reg_ack_out               (reg_ack_out),
      .reg_rd_wr_L_out           (reg_rd_wr_L_out),
      .reg_addr_out              (reg_addr_out),
      .reg_data_out              (reg_data_out),
      .reg_src_out               (reg_src_out),
      
      // --- Misc
      .reset                     (reset),
      .clk                       (clk)
   );
*/
endmodule // ap_lookup


