///////////////////////////////////////////////////////////////////////////////
//
// Module: ap_lookup_1.v
///////////////////////////////////////////////////////////////////////////////
`include "onet_defines.v"

  module ap_lookup_1
    #(parameter NUM_OUTPUT_QUEUES = 8,                  // obvious
      parameter DATA_WIDTH = 64,
      parameter F3_HEADER_WIDTH = 400,
      parameter F3_HEADER_WIDTH_BITS = log2(F3_HEADER_WIDTH),
      parameter OLD_HEADER_WIDTH = 432,
      parameter OLD_HEADER_WIDTH_BITS = log2(OLD_HEADER_WIDTH),
      parameter AP_WIDTH = 16,
      parameter ACTION_WIDTH = `F3_ACTION_WIDTH,
      parameter APT_DEPTH = `ACTION_TABLE_SIZE,
      parameter OFFSET = 0,
      parameter UDP_REG_SRC_WIDTH = 2,                  // identifies which module started this request
      parameter REG_ADDR_WIDTH = 10                      // Width of addresses in the same block
      )
   (
   // --- Interface to ap_lookup
   input                                     input_vld,
   input [AP_WIDTH-1:0]                      ap_in,
   input [DATA_WIDTH-1:0]                    module_hdr_in,
   input [F3_HEADER_WIDTH-1:0]               f3_header_in,
   input [F3_HEADER_WIDTH_BITS-1:0]          f3_header_len_in,
   input [OLD_HEADER_WIDTH-1:0]              old_header_in,
   input [OLD_HEADER_WIDTH_BITS-1:0]         old_header_len_in,

   output reg                                output_vld,
   //output reg [AP_WIDTH-1:0]                 ap_out,
   output reg [DATA_WIDTH-1:0]               module_hdr_out,
   output reg [F3_HEADER_WIDTH-1:0]          f3_header_out,
   output reg [F3_HEADER_WIDTH_BITS-1:0]     f3_header_len_out,
   output reg [OLD_HEADER_WIDTH-1:0]         old_header_out,
   output reg [OLD_HEADER_WIDTH_BITS-1:0]    old_header_len_out,

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
   localparam WAIT_FOR_INPUT  = 1;
   localparam EXCUTE_ACTIONS  = 2;
   
   //---------------------- Wires/Regs -------------------------------
   reg [1:0]                              state;
   reg [1:0]                              state_nxt;
   
   reg                                    pass;
   reg                                    pass_nxt;
   reg                                    output_to_cpu;
   reg                                    output_to_cpu_nxt;
   
   reg [AP_WIDTH-1:0]                     ap_held;
   
   reg                                    ap_vld_in;
   reg [AP_WIDTH-1:0]                     apt_ap_in;
   wire                                   action_vld;
   wire [ACTION_WIDTH-1:0]                action_out;
   wire [AP_WIDTH-1:0]                    next_ap_out;

   reg [DATA_WIDTH-1:0]                   module_hdr_held;
   reg [F3_HEADER_WIDTH-1:0]              f3_header_held;
   reg [F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_held;
   reg [OLD_HEADER_WIDTH-1:0]             old_header_held;
   reg [OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_held;
   
   reg                                    output_vld_nxt;
   reg [AP_WIDTH-1:0]                     ap_out_nxt;
   reg [DATA_WIDTH-1:0]                   module_hdr_out_nxt;
   reg [F3_HEADER_WIDTH-1:0]              f3_header_out_nxt;
   reg [F3_HEADER_WIDTH_BITS-1:0]         f3_header_len_out_nxt;
   reg [OLD_HEADER_WIDTH-1:0]             old_header_out_nxt;
   reg [OLD_HEADER_WIDTH_BITS-1:0]        old_header_len_out_nxt;

   reg [17:0]                             ip_new_checksum;
   reg [17:0]                             data_diff;
   reg [17:0]                             tp_new_checksum;
    //------------------------- Modules -------------------------------
   ap_lookup_table
   #(
      .ACTION_WIDTH(ACTION_WIDTH),
      .APT_DEPTH (APT_DEPTH),
      .DEFAULT_APT(232'h10004),
      .TAG(13'h1)
   ) ap_lookup_table_1
   (
      .ap                  (apt_ap_in),
      .ap_vld              (ap_vld_in),
      //.next_ap             (next_ap_out),
      .action              (action_out),
      .action_vld          (action_vld),
      
      // --- Interface for registers
      .reg_req_in          (reg_req_in),
      .reg_ack_in          (reg_ack_in),
      .reg_rd_wr_L_in      (reg_rd_wr_L_in),
      .reg_addr_in         (reg_addr_in),
      .reg_data_in         (reg_data_in),
      .reg_src_in          (reg_src_in),
   
      .reg_req_out         (reg_req_out),
      .reg_ack_out         (reg_ack_out),
      .reg_rd_wr_L_out     (reg_rd_wr_L_out),
      .reg_addr_out        (reg_addr_out),
      .reg_data_out        (reg_data_out),
      .reg_src_out         (reg_src_out),
      
      // --- Misc
      .reset               (reset),
      .clk                 (clk)
   );

   //-------------------------- Logic --------------------------------
   always @(*) begin
      state_nxt         = state;
      output_vld_nxt    = 0;
      pass_nxt          = 0;
      output_to_cpu_nxt = 0;
      ap_vld_in         = 0;
      case(state)
         WAIT_FOR_INPUT: begin
            if(input_vld) begin
               module_hdr_held            = module_hdr_in;
               f3_header_held             = f3_header_in;
               f3_header_len_held         = f3_header_len_in;
               old_header_held            = old_header_in;
               old_header_len_held        = old_header_len_in;
               ap_held                    = ap_in;
               if (ap_in == 16'hffff) begin
                  output_to_cpu_nxt       = 1;
               end
               else if (ap_in >= APT_DEPTH + OFFSET) begin
                  pass_nxt                = 1;
               end
               else begin
                  apt_ap_in   = ap_in - OFFSET;
                  ap_vld_in   = 1'b1;
               end
               state_nxt   = EXCUTE_ACTIONS;
            end
         end

         EXCUTE_ACTIONS: begin
            //pass_held_nxt                 = pass;
            state_nxt                     = WAIT_FOR_INPUT;
            pass_nxt                      = 0;
            output_to_cpu_nxt          = 0;
            if(action_vld || pass ||output_to_cpu) begin
               output_vld_nxt             = 1;
               module_hdr_out_nxt         = module_hdr_held;
               f3_header_out_nxt          = f3_header_held;
               f3_header_len_out_nxt      = f3_header_len_held;
               old_header_out_nxt         = old_header_held;
               old_header_len_out_nxt     = old_header_len_held;
               
               if (action_vld) begin
                  // set output port
                  if (action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_OUTPUT) begin
                     module_hdr_out_nxt[`IOQ_DST_PORT_POS+15:`IOQ_DST_PORT_POS] = action_out[`F3AT_FORWARD_BITMASK_POS +: `F3AT_FORWARD_BITMASK_WIDTH];
                  end

                  //modify src mac
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_SET_MAC_SRC)begin
                     old_header_out_nxt[`MAC_SRC_POS +: `MAC_SRC_WIDTH] = action_out[`F3AT_SET_MAC_SRC_POS +: `F3AT_SET_MAC_SRC_WIDTH];
                  end
                  //modify dst mac
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_SET_MAC_DST)begin
                     old_header_out_nxt[`MAC_DST_POS +: `MAC_DST_WIDTH] = action_out[`F3AT_SET_MAC_DST_POS +: `F3AT_SET_MAC_DST_WIDTH];
                  end

                  //modify src ip
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_SET_IP_SRC)begin
                     old_header_out_nxt[`IP_SRC_POS +: `IP_SRC_WIDTH] = action_out[`F3AT_SET_IP_SRC_POS +: `F3AT_SET_IP_SRC_WIDTH];
                     data_diff         = {2'b00, ~old_header_held[`IP_SRC_POS +: 16]} + {2'b0, action_out[`F3AT_SET_IP_SRC_POS +: 16]};
                     data_diff         = data_diff + {2'b00, ~old_header_held[`IP_SRC_POS+16 +: 16]} + {2'b0, action_out[`F3AT_SET_IP_SRC_POS+16 +: 16]};
                     ip_new_checksum   = ip_new_checksum + data_diff;
                     ip_new_checksum   = {2'b00, ip_new_checksum[15:0]} + {16'h0, ip_new_checksum[17:16]};
                  end
                  //modify dst ip
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_SET_IP_DST)begin
                     old_header_out_nxt[`IP_DST_POS +: `IP_DST_WIDTH] = action_out[`F3AT_SET_IP_DST_POS +: `F3AT_SET_IP_DST_WIDTH];
                     data_diff         = {2'b00, ~old_header_held[`IP_DST_POS +: 16]} + {2'b0, action_out[`F3AT_SET_IP_DST_POS +: 16]};
                     data_diff         = data_diff + {2'b00, ~old_header_held[`IP_DST_POS+16 +: 16]} + {2'b0, action_out[`F3AT_SET_IP_DST_POS+16 +: 16]};
                     ip_new_checksum   = ip_new_checksum + data_diff;
                     ip_new_checksum   = {2'b00, ip_new_checksum[15:0]} + {16'h0, ip_new_checksum[17:16]};
                  end
                  //modify ip tos
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_SET_IP_TOS)begin
                     old_header_out_nxt[`IP_TOS_POS +: `IP_TOS_WIDTH] = action_out[`F3AT_SET_IP_TOS_POS +: `F3AT_SET_IP_TOS_WIDTH];
                     data_diff         = {10'h0, ~old_header_held[`IP_TOS_POS +: `IP_TOS_WIDTH]} + {10'h0, action_out[`F3AT_SET_IP_TOS_POS +: `F3AT_SET_IP_TOS_WIDTH]};
                     ip_new_checksum   = ip_new_checksum + data_diff;
                     ip_new_checksum   = {2'b00, ip_new_checksum[15:0]} + {16'h0, ip_new_checksum[17:16]};
                  end
                  //decrease ttl
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_DEC_IP_TTL)begin
                     old_header_out_nxt[`IP_TTL_POS +: `IP_TTL_WIDTH] = old_header_held[`IP_TTL_POS +: `IP_TTL_WIDTH] - 1'b1;
                     ip_new_checksum   = ip_new_checksum + {2'h0, 16'hfeff};
                     ip_new_checksum   = {2'b00, ip_new_checksum[15:0]} + {16'h0, ip_new_checksum[17:16]};
                  end

                  //modify src tcp/udp port
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_SET_TP_SRC)begin
                     old_header_out_nxt[`TP_SRC_POS +: `TP_SRC_WIDTH] = action_out[`F3AT_SET_TP_SRC_POS +: `F3AT_SET_TP_SRC_WIDTH];
                     data_diff         = {2'b00, ~old_header_held[`TP_SRC_POS +: 16]} + {2'b0, action_out[`F3AT_SET_TP_SRC_POS +: 16]};
                     tp_new_checksum   = tp_new_checksum + data_diff;
                     tp_new_checksum   = {2'b00, tp_new_checksum[15:0]} + {16'h0, tp_new_checksum[17:16]};
                  end
                  //modify dst tcp/udp port
                  if(action_out[`F3AT_FLAG_POS +: `F3AT_FLAG_WIDTH] & `F3AT_SET_TP_DST)begin
                     old_header_out_nxt[`TP_DST_POS +: `TP_DST_WIDTH] = action_out[`F3AT_SET_TP_DST_POS +: `F3AT_SET_TP_DST_WIDTH];
                     data_diff         = {2'b00, ~old_header_held[`TP_DST_POS +: 16]} + {2'b0, action_out[`F3AT_SET_TP_DST_POS +: 16]};
                     tp_new_checksum   = tp_new_checksum + data_diff;
                     tp_new_checksum   = {2'b00, tp_new_checksum[15:0]} + {16'h0, tp_new_checksum[17:16]};
                  end
               end
               else if(output_to_cpu) begin
                  if (module_hdr_held[`IOQ_SRC_PORT_POS+15:`IOQ_SRC_PORT_POS] == 16'h0000) begin
                     module_hdr_out_nxt[`IOQ_DST_PORT_POS+15:`IOQ_DST_PORT_POS] = 16'h0002;
                  end
                  else if (module_hdr_held[`IOQ_SRC_PORT_POS+15:`IOQ_SRC_PORT_POS] == 16'h0002) begin
                     module_hdr_out_nxt[`IOQ_DST_PORT_POS+15:`IOQ_DST_PORT_POS] = 16'h0008;
                  end
                  else if (module_hdr_held[`IOQ_SRC_PORT_POS+15:`IOQ_SRC_PORT_POS] == 16'h0004) begin
                     module_hdr_out_nxt[`IOQ_DST_PORT_POS+15:`IOQ_DST_PORT_POS] = 16'h0020;
                  end
                  else if (module_hdr_held[`IOQ_SRC_PORT_POS+15:`IOQ_SRC_PORT_POS] == 16'h0006) begin
                     module_hdr_out_nxt[`IOQ_DST_PORT_POS+15:`IOQ_DST_PORT_POS] = 16'h0080;
                  end
               end
            end
         end
      endcase
   end

   always @(posedge clk) begin
      if(reset) begin
         output_vld           <= 0;
         pass                 <= 0;
         state                <= WAIT_FOR_INPUT;
      end
      else begin
         state                <= state_nxt;
         
         output_vld           <= output_vld_nxt;
         //ap_out               <= ap_out_nxt;
         module_hdr_out       <= module_hdr_out_nxt;
         f3_header_out        <= f3_header_out_nxt;
         f3_header_len_out    <= f3_header_len_out_nxt;
         old_header_out       <= old_header_out_nxt;
         old_header_len_out   <= old_header_len_out_nxt;
         
         pass                 <= pass_nxt;
         output_to_cpu        <= output_to_cpu_nxt;
         //pass_held            <= pass_held_nxt;
      end
   end // always @ (posedge clk)

endmodule // ap_lookup


