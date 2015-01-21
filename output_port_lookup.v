///////////////////////////////////////////////////////////////////////////////
// Module: output_port_lookup.v
// Project: F3
// Author: wuch
///////////////////////////////////////////////////////////////////////////////
`include "onet_defines.v"
`timescale 1ns/1ps
  module output_port_lookup
   #(parameter DATA_WIDTH = 64,
     parameter CTRL_WIDTH=DATA_WIDTH/8,
     parameter F3_HEADER_WIDTH = 400,
     parameter F3_HEADER_WIDTH_BITS = log2(F3_HEADER_WIDTH),
     parameter OLD_HEADER_WIDTH = 432,
     parameter OLD_HEADER_WIDTH_BITS = log2(OLD_HEADER_WIDTH),
     parameter AP_WIDTH=`F3_AP_WIDTH,
     parameter UDP_REG_SRC_WIDTH = 2,
     parameter IO_QUEUE_STAGE_NUM = `IO_QUEUE_STAGE_NUM,
     parameter NUM_OUTPUT_QUEUES = 8,
     parameter NUM_IQ_BITS = 3,
     parameter STAGE_NUM = 4,
     parameter SRAM_ADDR_WIDTH = 19,
     parameter CPU_QUEUE_NUM = 0,
     parameter F3_LOOKUP_REG_ADDR_WIDTH = 6,
     parameter F3_LOOKUP_BLOCK_ADDR = 13'h9,
     parameter F3_WILDCARD_LOOKUP_REG_ADDR_WIDTH = 10,
     parameter F3_WILDCARD_LOOKUP_BLOCK_ADDR = 13'h1
   )

   (// --- data path interface
   output    [DATA_WIDTH-1:0]       out_data,
   output    [CTRL_WIDTH-1:0]       out_ctrl,
   output                           out_wr,
   input                            out_rdy,

   input  [DATA_WIDTH-1:0]          in_data,
   input  [CTRL_WIDTH-1:0]          in_ctrl,
   input                            in_wr,
   output                           in_rdy,

   // --- Register interface
   input                               reg_req_in,
   input                               reg_ack_in,
   input                               reg_rd_wr_L_in,
   input  [`UDP_REG_ADDR_WIDTH-1:0]    reg_addr_in,
   input  [`CPCI_NF2_DATA_WIDTH-1:0]   reg_data_in,
   input  [UDP_REG_SRC_WIDTH-1:0]      reg_src_in,

   output                              reg_req_out,
   output                              reg_ack_out,
   output                              reg_rd_wr_L_out,
   output  [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
   output  [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
   output  [UDP_REG_SRC_WIDTH-1:0]     reg_src_out,
   
   // --- Watchdog Timer Interface
   input                               table_flush,

   // --- Misc
   input                               clk,
   input                               reset);

   `LOG2_FUNC
   `CEILDIV_FUNC

   //-------------------- Internal Parameters ------------------------
   localparam PKT_SIZE_WIDTH = 12;

   //------------------------ Wires/Regs -----------------------------
   // size is the action + input port
   wire [CTRL_WIDTH-1:0]                           in_fifo_ctrl;
   wire [DATA_WIDTH-1:0]                           in_fifo_data;
   
   wire                                            all_vld;
   wire [DATA_WIDTH-1:0]                           module_hdr_hp_out;
   wire [AP_WIDTH-1:0]                             first_ap;
   wire [F3_HEADER_WIDTH-1:0]                      f3_header_hp_out;
   wire [F3_HEADER_WIDTH_BITS-1:0]                 f3_header_len_hp_out;
   wire [OLD_HEADER_WIDTH-1:0]                     old_header_hp_out;
   wire [OLD_HEADER_WIDTH_BITS-1:0]                old_header_len_hp_out;
   wire                                            is_ip;
   wire                                            is_arp;
   wire                                            is_icmp;
   wire                                            is_tcp;
   wire                                            is_udp;
   
   wire                                            result_fifo_rd_en;
   wire                                            result_fifo_empty;
   wire [DATA_WIDTH-1:0]                           module_hdr_ap_out;
   wire [F3_HEADER_WIDTH-1:0]                      f3_header_ap_out;
   wire [F3_HEADER_WIDTH_BITS-1:0]                 f3_header_len_ap_out;
   wire [OLD_HEADER_WIDTH-1:0]                     old_header_ap_out;
   wire [OLD_HEADER_WIDTH_BITS-1:0]                old_header_len_ap_out;

   reg [31:0]                                      s_counter;
   reg [27:0]                                      ns_counter;
   
   wire                                            ap_reg_req_out;
   wire                                            ap_reg_ack_out;
   wire                                            ap_reg_rd_wr_L_out;
   wire [`UDP_REG_ADDR_WIDTH-1:0]                  ap_reg_addr_out;
   wire [`CPCI_NF2_DATA_WIDTH-1:0]                 ap_reg_data_out;
   wire [UDP_REG_SRC_WIDTH-1:0]                    ap_reg_src_out;
   //------------------------- Modules -------------------------------

   /* each pkt can have up to:
   * - 18 bytes of Eth header including VLAN
   * - 15*4 = 60 bytes IP header including max number of options
   * - at least 4 bytes of tcp/udp header
   * total = 82 bytes approx 4 bits (8 bytes x 2^4 = 128 bytes)
   */
   /*
   fallthrough_small_fifo #(.WIDTH(CTRL_WIDTH+DATA_WIDTH), .MAX_DEPTH_BITS(5))
      input_fifo
      (
      .din         ({in_ctrl, in_data}),  // Data in
      .wr_en       (in_wr),          // Write enable
      .rd_en       (in_fifo_rd_en),   // Read the next word
      .dout        ({in_fifo_ctrl, in_fifo_data}),
      .prog_full    (),
      .full        (),
      .nearly_full   (in_fifo_nearly_full),
      .empty       (in_fifo_empty),
      .reset       (reset),
      .clk         (clk)
      );
   */
   header_parser #(
      .DATA_WIDTH             (DATA_WIDTH),
      .CTRL_WIDTH             (CTRL_WIDTH),
      .AP_WIDTH               (AP_WIDTH)
      ) header_parser
      ( // --- Interface to the previous stage
         .in_data                (in_data),
         .in_ctrl                (in_ctrl),
         .in_wr                  (in_wr),
         .in_rdy                 (in_rdy),

         // --- Interface to ap_lookup
         .all_vld                (all_vld),
         .module_hdr             (module_hdr_hp_out),
         .first_ap               (first_ap),
         .f3_header_out          (f3_header_hp_out),
         .f3_header_len          (f3_header_len_hp_out),
         .old_header_out         (old_header_hp_out),
         .old_header_len         (old_header_len_hp_out),
         .is_ip                  (is_ip),
         .is_arp                 (is_arp),
         .is_icmp                (is_icmp),
         .is_tcp                 (is_tcp),
         .is_udp                 (is_udp),
         
         // --- Interface to combiner
         .in_fifo_ctrl           (in_fifo_ctrl),
         .in_fifo_data           (in_fifo_data),
         .in_fifo_rd_en          (in_fifo_rd_en),
         .in_fifo_empty          (in_fifo_empty),
         
         // --- Misc
         .reset                    (reset),
         .clk                      (clk));

   ap_lookup #(
     .NUM_OUTPUT_QUEUES(NUM_OUTPUT_QUEUES),
     .AP_WIDTH(AP_WIDTH)
     ) ap_lookup
     (
      // --- Interface to header_parser
      .all_vld                      (all_vld),
      .module_hdr                   (module_hdr_hp_out),
      .first_ap                     (first_ap),
      .f3_header                    (f3_header_hp_out),
      .f3_header_len                (f3_header_len_hp_out),
      .old_header                   (old_header_hp_out),
      .old_header_len               (old_header_len_hp_out),
      .is_ip                        (is_ip),
      .is_arp                       (is_arp),
      .is_icmp                      (is_icmp),
      .is_tcp                       (is_tcp),
      .is_udp                       (is_udp),
      
      // --- Interface to combiner
      .result_fifo_rd_en            (result_fifo_rd_en),
      .result_fifo_empty            (result_fifo_empty),
      .module_hdr_out               (module_hdr_ap_out),
      .f3_header_out                (f3_header_ap_out),
      .f3_header_len_out            (f3_header_len_ap_out),
      .old_header_out               (old_header_ap_out),
      .old_header_len_out           (old_header_len_ap_out),

      // --- Interface to register bus
      .reg_req_in                   (reg_req_in),
      .reg_ack_in                   (reg_ack_in),
      .reg_rd_wr_L_in               (reg_rd_wr_L_in),
      .reg_addr_in                  (reg_addr_in),
      .reg_data_in                  (reg_data_in),
      .reg_src_in                   (reg_src_in),

      .reg_req_out                  (ap_reg_req_out),
      .reg_ack_out                  (ap_reg_ack_out),
      .reg_rd_wr_L_out              (ap_reg_rd_wr_L_out),
      .reg_addr_out                 (ap_reg_addr_out),
      .reg_data_out                 (ap_reg_data_out),
      .reg_src_out                  (ap_reg_src_out),

      .clk                          (clk),
      .reset                        (reset)
     );

   combiner #(
    .F3_HEADER_WIDTH(`F3_HEADER_WIDTH),
    .OLD_HEADER_WIDTH(`OLD_HEADER_WIDTH)
    )
   combiner
      (// --- interface to ap_lookup
      .result_fifo_rd_en            (result_fifo_rd_en),
      .result_fifo_empty            (result_fifo_empty),
      .module_hdr                   (module_hdr_ap_out),
      .f3_header_in                 (f3_header_ap_out),
      .f3_header_len                (f3_header_len_ap_out),
      .old_header_in                (old_header_ap_out),
      .old_header_len               (old_header_len_ap_out),

     // --- interface to input fifo
     .in_fifo_ctrl     (in_fifo_ctrl),
     .in_fifo_data     (in_fifo_data),
     .in_fifo_rd_en     (in_fifo_rd_en),
     .in_fifo_empty     (in_fifo_empty),

     // --- interface to output
     .out_wr         (out_wr),
     .out_rdy        (out_rdy),
     .out_data       (out_data),
     .out_ctrl       (out_ctrl),

     // --- Misc
     .clk          (clk),
     .reset         (reset));

   generic_regs
   #(.UDP_REG_SRC_WIDTH (UDP_REG_SRC_WIDTH),
     .TAG (F3_LOOKUP_BLOCK_ADDR),
     .REG_ADDR_WIDTH (F3_LOOKUP_REG_ADDR_WIDTH),
     .NUM_COUNTERS (2*2                  // hits and misses for both tables
             + NUM_OUTPUT_QUEUES         // num dropped per port
             ),
     .NUM_SOFTWARE_REGS (2),
     .NUM_HARDWARE_REGS (2),
     .COUNTER_INPUT_WIDTH (1)
     )
   generic_regs
   (
   .reg_req_in        (ap_reg_req_out),
   .reg_ack_in        (ap_reg_ack_out),
   .reg_rd_wr_L_in    (ap_reg_rd_wr_L_out),
   .reg_addr_in       (ap_reg_addr_out),
   .reg_data_in       (ap_reg_data_out),
   .reg_src_in        (ap_reg_src_out),

    .reg_req_out     (reg_req_out),
    .reg_ack_out     (reg_ack_out),
    .reg_rd_wr_L_out   (reg_rd_wr_L_out),
    .reg_addr_out    (reg_addr_out),
    .reg_data_out    (reg_data_out),
    .reg_src_out     (reg_src_out),

    // --- counters interface
    .counter_updates   ({1'b0,
                1'b0,//exact_wins,
                1'b0,//exact_miss,
                1'b0,
                1'b0}
               ),
    .counter_decrement ({(4+NUM_OUTPUT_QUEUES){1'b0}}),

    // --- SW regs interface
    .software_regs   (),

    // --- HW regs interface
    .hardware_regs   ({32'h0,
                s_counter}),

    .clk         (clk),
    .reset        (reset));

   //--------------------------- Logic ------------------------------

   // timer
   always @(posedge clk) begin
    if(reset) begin
      ns_counter <= 0;
      s_counter  <= 0;
    end
    else begin
      if(ns_counter == (1_000_000_000/`FAST_CLOCK_PERIOD - 1'b1)) begin
       s_counter  <= s_counter + 1'b1;
       ns_counter <= 0;
      end
      else begin
       ns_counter <= ns_counter + 1'b1;
      end
    end // else: !if(reset)
   end // always @ (posedge clk)


endmodule // router_output_port
