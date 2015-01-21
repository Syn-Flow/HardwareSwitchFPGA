///////////////////////////////////////////////////////////////////////////////
// Module: header_parser.v
///////////////////////////////////////////////////////////////////////////////
`include "onet_defines.v"
  module header_parser
    #(parameter DATA_WIDTH = 64,
      parameter CTRL_WIDTH = DATA_WIDTH/8,
      parameter F3_HEADER_WIDTH = 400,
      parameter F3_HEADER_WIDTH_BITS = log2(F3_HEADER_WIDTH),
      parameter OLD_HEADER_WIDTH = 432,
      parameter OLD_HEADER_WIDTH_BITS = log2(OLD_HEADER_WIDTH),
      parameter AP_WIDTH = `F3_AP_WIDTH
      )
   (// --- Interface to the previous stage
   input  [DATA_WIDTH-1:0]                   in_data,
   input  [CTRL_WIDTH-1:0]                   in_ctrl,
   input                                     in_wr,
   output reg                                in_rdy,

    // --- Interface to ap_lookup
   output reg                                all_vld,
   output reg [DATA_WIDTH-1:0]               module_hdr,
   output reg [AP_WIDTH-1:0]                 first_ap,
   output reg [F3_HEADER_WIDTH-1:0]          f3_header_out,
   output reg [F3_HEADER_WIDTH_BITS-1:0]     f3_header_len,
   output reg [OLD_HEADER_WIDTH-1:0]         old_header_out,
   output reg [OLD_HEADER_WIDTH_BITS-1:0]    old_header_len,
   output reg                                is_ip,
   output reg                                is_arp,
   output reg                                is_icmp,
   output reg                                is_tcp,
   output reg                                is_udp,

   // --- Interface to combiner
   output  [DATA_WIDTH-1:0]                  in_fifo_data,
   output  [CTRL_WIDTH-1:0]                  in_fifo_ctrl,
   output                                    in_fifo_empty,
   input                                     in_fifo_rd_en,

   // --- Misc
   input                                  reset,
   input                                  clk
   );

   `LOG2_FUNC

   //------------------ Internal Parameter ---------------------------
   localparam RESET_F3_HEADER                = 0;
   localparam MODULE_HDRS                    = 1;
   localparam F3_HEADER_WORDS                = 2;
   localparam PKT_WORDS_1                    = 3;
   localparam PKT_WORDS_2                    = 4;
   localparam PKT_WORDS_3                    = 5;
   localparam PKT_WORDS_4                    = 6;
   localparam PAYLOAD_0                      = 7;
   localparam PAYLOAD_1                      = 8;
   localparam PAYLOAD_2                      = 9;
   localparam PAYLOAD_3                      = 10;
   localparam END                            = 11;
   localparam END_1                          = 12;
   localparam END_3                          = 13;
   localparam DROP_WRONG_PKT                 = 14;

   // PKT_WORDS_3 & 4
   localparam  ETH_DST_SRC                   = 0,
               ETH_SRC_TYPE                  = 1,
               IP_PROT                       = 2,
               IP_SRC_DST                    = 3,
               TRANSP_PORT                   = 4,
               TRANSP_WIN                    = 5,
               TRANSP_CHK_SUM                = 6;
   //PKT_WORDS_1
   localparam  ETH_WORD_1                    = 0,
               IP_WORD_1                     = 1,
               IP_WORD_2                     = 2,
               IP_WORD_3                     = 3,
               TRANSP_WORD_1                 = 4,
               TRANSP_WORD_2                 = 5;
   // PKT_WORDS_2
   localparam  ETH_P2_1                      = 0,
               ETH_P2_2                      = 1,
               IP_P2_1                       = 2,
               IP_P2_2                       = 3,
               TRANSP_P2_1                   = 4,
               TRANSP_P2_2                   = 5,
               TRANSP_P2_3                   = 6;

   //---------------------- Wires/Regs -------------------------------
   reg [3:0]                              state;
   reg [2:0]                              counter;
   reg [15:0]                             pkt_size;
   reg [7:0]                              aps;

   reg [F3_HEADER_WIDTH-1:0]              f3_header;
   reg [OLD_HEADER_WIDTH-1:0]             old_header;
   reg                                    hd_done;

   reg [CTRL_WIDTH-1:0]                   in_hp_fifo_ctrl;
   reg [DATA_WIDTH-1:0]                   in_hp_fifo_data;
   reg                                    in_hp_fifo_wr;

   reg [DATA_WIDTH-1:0]                   module_hdr_held;
   reg [15:0]                             pkt_size_held;
   reg [CTRL_WIDTH-1:0]                   in_hp_fifo_ctrl_held;
   reg [DATA_WIDTH-1:0]                   in_hp_fifo_data_held;
   reg                                    start_from_second;
   
   reg [31:0]                             payload_temp;
   reg [15:0]                             payload_temp_3;
   reg [47:0]                             payload_temp_1;
   reg [CTRL_WIDTH-1:0]                   in_ctrl_end;
   //------------------------- Modules -------------------------------
   fallthrough_small_fifo #(.WIDTH(CTRL_WIDTH+DATA_WIDTH), .MAX_DEPTH_BITS(5))
      input_fifo
      (
      .din         ({in_hp_fifo_ctrl, in_hp_fifo_data}),  // Data in
      .wr_en       (in_hp_fifo_wr),          // Write enable
      .rd_en       (in_fifo_rd_en),   // Read the next word
      .dout        ({in_fifo_ctrl, in_fifo_data}),
      .prog_full   (),
      .full        (),
      .nearly_full (),
      .empty       (in_fifo_empty),
      .reset       (reset),
      .clk         (clk)
      );

   //always @(*) begin
   //   in_rdy = !(((state==PAYLOAD_1) && (in_ctrl < 8'b01000000))
   //               ||((state==PAYLOAD_2) && (in_ctrl < 8'h10))
   //               ||((state==PAYLOAD_3) && (in_ctrl < 8'b00000100)));
   //end

   /* This state machine parses the header */
   always @(posedge clk) begin
      if(reset) begin
         counter           <= 0;
         hd_done           <= 0;
         all_vld           <= 0;
         f3_header         <= 0;
         old_header        <= 0;
         state             <= MODULE_HDRS;
         is_ip             <= 0;
         is_arp            <= 0;
         is_tcp            <= 0;
         is_udp            <= 0;
         is_icmp           <= 0;
         in_hp_fifo_wr     <= 0;
      end
      
      else begin
         in_hp_fifo_wr  <= 0;
         hd_done        <= 0;
         all_vld        <= 0;
         in_rdy         <= 1;
         case (state)
            RESET_F3_HEADER: begin
               f3_header      <= 0;
               old_header     <= 0;
               state          <= MODULE_HDRS;
               if(in_wr) begin
                  if(in_ctrl==`IO_QUEUE_STAGE_NUM) begin
                     module_hdr        <= in_data;
                     pkt_size          <= in_data[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS];
                     in_hp_fifo_ctrl   <= in_ctrl;
                     in_hp_fifo_data   <= in_data;
                     start_from_second <= 0;
                     //in_hp_fifo_wr     <= 1;
                  end
                  // pkt should not be started
                  // synthesis translate_off
                  else if(in_ctrl==0) begin
                     $display("%t %m ERROR: found ctrl=0 as first word of pkt.", $time);
                     $stop;
                  end
                  // synthesis translate_on
               end // if (in_wr)
            end // case: RESET_FLOW_ENTRY

            MODULE_HDRS: begin
               is_ip             <= 0;
               is_arp            <= 0;
               is_tcp            <= 0;
               is_udp            <= 0;
               is_icmp           <= 0;
               if(in_wr) begin
                  // 
                  if(in_ctrl==`IO_QUEUE_STAGE_NUM) begin
                     module_hdr        <= in_data;
                     pkt_size          <= in_data[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS];
                     in_hp_fifo_ctrl   <= in_ctrl;
                     in_hp_fifo_data   <= in_data;
                     //in_hp_fifo_wr     <= 1;
                     start_from_second <= 0;
                     f3_header         <= 0;
                     old_header        <= 0;
                     f3_header_len     <= 0;
                     old_header_len    <= 0;
                  end
                  // 
                  else if(in_ctrl==0) begin
                     counter           <= 0;
                     f3_header         <= 0;
                     old_header        <= 0;
                     f3_header_len     <= 0;
                     old_header_len    <= 0;
                     if (start_from_second) begin
                        module_hdr           <= module_hdr_held;
                        pkt_size             <= pkt_size_held;
                        in_hp_fifo_ctrl      <= in_hp_fifo_ctrl_held;
                        in_hp_fifo_data      <= in_hp_fifo_data_held;
                        start_from_second    <= 0;
                     end
                     if(in_data[57:56]==2'b10)begin
                        if(in_data[63:58]==1 || in_data[63:58]==0 || in_data[55:48]==0) begin
                           first_ap  <= 16'hffff;
                        end
                        else begin
                           first_ap  <= in_data[47:32];
                        end
                        
                        if (in_data[55:48] > (pkt_size>>1) || in_data[63:58]==0) begin
                           state             <= DROP_WRONG_PKT;
                        end
                        else if (in_data[55:48] == 1) begin
                           in_hp_fifo_wr     <= 1;
                           f3_header[15:0]   <= in_data[63:48] - 16'h0401;
                           f3_header_len     <= 16;
                           old_header[31:0]  <= in_data[31:0];
                           old_header_len    <= 32;
                           state             <= PKT_WORDS_2;
                        end
                        else if(in_data[55:48] == 2) begin
                           in_hp_fifo_wr     <= 1;
                           f3_header[31:0]   <= {in_data[63:48] - 16'h0401,in_data[31:16]};
                           f3_header_len     <= 32;
                           old_header[15:0]  <= in_data[15:0];
                           old_header_len    <= 16;
                           state             <= PKT_WORDS_3;
                        end
                        else if(in_data[55:48] == 3) begin
                           in_hp_fifo_wr     <= 1;
                           f3_header[47:0]   <= {in_data[63:48] - 16'h0401,in_data[31:0]};
                           f3_header_len     <= 48;
                           //old_header[15:0]  <= in_data[15:0];
                           //old_header_len    <= 16;
                           state             <= PKT_WORDS_4;
                        end
                        else begin
                           in_hp_fifo_wr     <= 1;
                           f3_header[47:0]   <= {in_data[63:48] - 16'h0401,in_data[31:0]};
                           f3_header_len     <= 48;
                           aps               <= in_data[55:48]-3;
                           state             <= F3_HEADER_WORDS;
                        end
                     end
                     else begin  //!if(in_data[57:56]==2'b10)
                        state             <= DROP_WRONG_PKT;
                     end
                  end
               end // if (in_wr)
            end // case: MODULE_HDRS

            F3_HEADER_WORDS:begin
               if(in_wr) begin
                  aps <= aps - 4;
                  if (aps == 1) begin
                     f3_header         <= {f3_header<<16} | in_data[63:48];
                     f3_header_len     <= f3_header_len + 16;
                     old_header[47:0]  <= in_data[47:0];
                     old_header_len    <= 48;
                     state             <= PKT_WORDS_1;
                  end
                  else if (aps == 2) begin
                     f3_header         <= {f3_header<<32} | in_data[63:32];
                     f3_header_len     <= f3_header_len + 32;
                     old_header[31:0]  <= in_data[31:0];
                     old_header_len    <= 32;
                     state             <= PKT_WORDS_2;
                  end
                  else if(aps == 3)begin
                     //f3_header[F3_HEADER_WIDTH - f3_header_len - 1 : F3_HEADER_WIDTH-f3_header_len-48] <= in_data[63:16];
                     f3_header         <= {f3_header<<48} | in_data[63:16];
                     f3_header_len     <= f3_header_len + 48;
                     old_header[15:0]  <= in_data[15:0];
                     old_header_len    <= 16;
                     state             <= PKT_WORDS_3;
                  end
                  else if(aps == 4)begin
                     //f3_header[F3_HEADER_WIDTH - f3_header_len - 1 : F3_HEADER_WIDTH-f3_header_len-16] <= in_data[63:48];
                     f3_header         <= {f3_header<<64} | in_data;
                     f3_header_len     <= f3_header_len + 64;
                     //old_header[47:0]  <= in_data[47:0];
                     //old_header_len    <= 48;
                     state             <= PKT_WORDS_4;
                  end
                  else begin
                     //f3_header[F3_HEADER_WIDTH - f3_header_len - 1 : F3_HEADER_WIDTH-f3_header_len-64] <= in_data;
                     f3_header         <= {f3_header<<64} | in_data;
                     f3_header_len     <= f3_header_len + 64;
                  end
                  counter  <= 0;
               end
            end

            PKT_WORDS_1: begin
               if(in_wr) begin
                  counter <= counter + 1;
                  case(counter)

                     ETH_WORD_1:begin
                        if(in_data[15:0] != `ETH_TYPE_IP) begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                           old_header     <= {old_header<<32} | in_data[63:32];
                           old_header_len <= old_header_len + 32;
                           state    <= PAYLOAD_2;
                           payload_temp <= in_data[31:0];
                           hd_done  <= 1;
                        end
                        else begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                           old_header     <= {old_header<<64} | in_data;
                           old_header_len <= old_header_len + 64;
                        end
                        is_ip       <= in_data[15:0] == `ETH_TYPE_IP;
                        is_arp      <= in_data[15:0] == `ETH_TYPE_ARP;
                     end
                     
                     IP_WORD_1: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end
                     
                     IP_WORD_2: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        is_tcp      <= is_ip && (in_data[55:48] == `IP_PROTO_TCP);
                        is_udp      <= is_ip && (in_data[55:48] == `IP_PROTO_UDP);
                        is_icmp     <= is_ip && (in_data[55:48] == `IP_PROTO_ICMP);
                     end

                     IP_WORD_3:begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end

                     TRANSP_WORD_1: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;

                        if(is_udp ||is_icmp) begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                           old_header     <= {old_header<<32} | in_data[63:32];
                           old_header_len <= old_header_len + 32;
                           hd_done        <= 1;
                           if(in_ctrl != 0) begin
                              if(in_ctrl == 8'h10) begin
                                 state    <= MODULE_HDRS;
                              end
                              else if(in_ctrl > 8'h10)begin
                                 state    <= RESET_F3_HEADER;
                              end
                              else begin
                                 state             <= MODULE_HDRS;
                                 in_hp_fifo_ctrl   <= in_ctrl<<4;
                                 in_hp_fifo_data   <= {in_data[31:0],32'h0};
                                 in_hp_fifo_wr     <= 1;
                              end
                           end
                           else begin
                              state                <= PAYLOAD_2;
                              payload_temp         <= in_data[31:0];
                           end
                        end
                     end
                     /*
                     TRANSP_WORD_2: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        if(in_ctrl != 0) begin
                           state    <= RESET_F3_HEADER;
                        end
                     end*/
                     
                     TRANSP_WORD_2: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        hd_done        <= 1;
                        if(in_ctrl != 0) begin
                           if(in_ctrl == 8'h01) begin
                              state    <= MODULE_HDRS;
                           end
                           else begin
                              state    <= RESET_F3_HEADER;
                           end
                        end
                        else begin
                           state       <= PAYLOAD_0;
                        end
                     end
                  endcase // case(counter)
               end // if (in_wr)
            end // case: PKT_WORDS_1

            PKT_WORDS_2: begin
               if(in_wr) begin
                  counter <= counter + 1;
                  case(counter)

                     ETH_P2_1:begin
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end
                     
                     ETH_P2_2:begin
                        if(in_data[63:48] != `ETH_TYPE_IP) begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                           old_header     <= {old_header<<16} | in_data[63:48];
                           old_header_len <= old_header_len + 16;
                           state    <= PAYLOAD_1;
                           payload_temp_1 <= in_data[47:0];
                           hd_done  <= 1;
                        end
                        else begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                           old_header     <= {old_header<<64} | in_data;
                           old_header_len <= old_header_len + 64;
                        end
                        is_ip       <= in_data[63:47] == `ETH_TYPE_IP;
                        is_arp      <= in_data[63:47] == `ETH_TYPE_ARP;
                     end
                     
                     IP_P2_1: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        is_tcp      <= is_ip && (in_data[39:32] == `IP_PROTO_TCP);
                        is_udp      <= is_ip && (in_data[39:32] == `IP_PROTO_UDP);
                        is_icmp     <= is_ip && (in_data[39:32] == `IP_PROTO_ICMP);
                     end
                     
                     IP_P2_2: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end

                     TRANSP_P2_1: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;

                        if(is_udp ||is_icmp) begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                           old_header     <= {old_header<<48} | in_data[63:16];
                           old_header_len <= old_header_len + 48;
                           hd_done        <= 1;
                           if(in_ctrl != 0) begin
                              if(in_ctrl == 8'b00000100) begin
                                 state    <= MODULE_HDRS;
                              end
                              else if(in_ctrl > 8'b00000100)begin
                                 state    <= RESET_F3_HEADER;
                              end
                              else begin
                                 state             <= MODULE_HDRS;
                                 in_hp_fifo_ctrl   <= in_ctrl<<6;
                                 in_hp_fifo_data   <= {in_data[15:0],48'h0};
                                 in_hp_fifo_wr     <= 1;
                              end
                           end
                           else begin
                              state                <= PAYLOAD_3;
                              payload_temp_3       <= in_data[15:0];
                           end
                        end
                     end
                     /*
                     TRANSP_WORD_2: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        if(in_ctrl != 0) begin
                           state    <= RESET_F3_HEADER;
                        end
                     end*/
                     TRANSP_P2_2: begin
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end
                     TRANSP_P2_3: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                        old_header     <= {old_header<<16} | in_data[63:47];
                        old_header_len <= old_header_len + 16;
                        hd_done        <= 1;
                        if(in_ctrl != 0) begin
                           if(in_ctrl == 8'b01000000) begin
                              state    <= MODULE_HDRS;
                           end
                           else if (in_ctrl > 8'b01000000)begin
                              state    <= RESET_F3_HEADER;
                           end
                           else begin
                              state             <= MODULE_HDRS;
                              in_hp_fifo_ctrl   <= in_ctrl<<2;
                              in_hp_fifo_data   <= {in_data[47:0],16'h0};
                              in_hp_fifo_wr     <= 1;
                           end
                        end
                        else begin
                           state       <= PAYLOAD_1;
                           payload_temp_1 <= in_data[47:0];
                        end
                     end
                  endcase // case(counter)
               end // if (in_wr)
            end // case: PKT_WORDS_2
            
            PKT_WORDS_3: begin
               if(in_wr) begin
                  counter <= counter + 1;
                  case(counter)
                     ETH_DST_SRC: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end
                     
                     ETH_SRC_TYPE:begin
                        if(in_data[47:32] != `ETH_TYPE_IP) begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                           old_header     <= {old_header<<32} | in_data[63:32];
                           old_header_len <= old_header_len + 32;
                           state          <= PAYLOAD_2;
                           payload_temp   <= in_data[31:0];
                           hd_done        <= 1;
                        end
                        else begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                           old_header     <= {old_header<<64} | in_data;
                           old_header_len <= old_header_len + 64;
                        end
                        is_ip       <= in_data[47:32] == `ETH_TYPE_IP;
                        is_arp      <= in_data[47:32] == `ETH_TYPE_ARP;
                     end
                     
                     IP_PROT: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        is_tcp      <= is_ip && (in_data[23:16] == `IP_PROTO_TCP);
                        is_udp      <= is_ip && (in_data[23:16] == `IP_PROTO_UDP);
                        is_icmp     <= is_ip && (in_data[23:16] == `IP_PROTO_ICMP);
                     end
                     
                     IP_SRC_DST: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end

                     TRANSP_PORT: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;

                        if(is_udp ||is_icmp) begin
                           hd_done  <= 1;
                           if(in_ctrl != 0) begin
                              if(in_ctrl == 8'h01) begin
                                 state    <= MODULE_HDRS;
                              end
                              else begin
                                 state    <= RESET_F3_HEADER;
                              end
                           end
                           else begin
                              state       <= PAYLOAD_0;
                           end
                        end
                     end
                     
                     TRANSP_WIN: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        if(in_ctrl != 0) begin
                           state    <= RESET_F3_HEADER;
                        end
                     end
                     
                     TRANSP_CHK_SUM: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                        old_header     <= {old_header<<32} | in_data[63:32];
                        old_header_len <= old_header_len + 32;
                        hd_done  <= 1;
                        if(in_ctrl != 0) begin
                           if(in_ctrl == 8'h10) begin
                              state    <= MODULE_HDRS;
                           end
                           else if(in_ctrl > 8'h10) begin
                              state    <= RESET_F3_HEADER;
                           end
                           else begin
                              state             <= MODULE_HDRS;
                              in_hp_fifo_ctrl   <= in_ctrl<<4;
                              in_hp_fifo_data   <= {in_data[31:0],32'h0};
                              in_hp_fifo_wr     <= 1;
                           end
                        end
                        else begin
                           state             <= PAYLOAD_2;
                           payload_temp      <= in_data[31:0];
                        end
                     end
                  endcase // case(counter)
               end // if (in_wr)
            end // case: PKT_WORDS_3

            PKT_WORDS_4: begin
               if(in_wr) begin
                  counter <= counter + 1;
                  case(counter)
                     ETH_DST_SRC: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end
                     
                     ETH_SRC_TYPE:begin
                        if(in_data[31:16] != `ETH_TYPE_IP) begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                           old_header     <= {old_header<<48} | in_data[63:16];
                           old_header_len <= old_header_len + 32;
                           state          <= PAYLOAD_3;
                           hd_done        <= 1;
                        end
                        else begin
                           //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                           old_header     <= {old_header<<64} | in_data;
                           old_header_len <= old_header_len + 64;
                        end
                        is_ip       <= in_data[31:16] == `ETH_TYPE_IP;
                        is_arp      <= in_data[31:16] == `ETH_TYPE_ARP;
                     end
                     
                     IP_PROT: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        is_tcp      <= is_ip && (in_data[7:0] == `IP_PROTO_TCP);
                        is_udp      <= is_ip && (in_data[7:0] == `IP_PROTO_UDP);
                        is_icmp     <= is_ip && (in_data[7:0] == `IP_PROTO_ICMP);
                     end
                     
                     IP_SRC_DST: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end

                     TRANSP_PORT: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                     end
                     
                     TRANSP_WIN:begin
                        old_header     <= {old_header<<64} | in_data;
                        old_header_len <= old_header_len + 64;
                        if(is_udp ||is_icmp) begin
                           hd_done  <= 1;
                           if(in_ctrl != 0) begin
                              if(in_ctrl == 8'b01000000) begin
                                 state    <= MODULE_HDRS;
                              end
                              else if (in_ctrl > 8'b01000000)begin
                                 state    <= RESET_F3_HEADER;
                              end
                              else begin
                                 state             <= MODULE_HDRS;
                                 in_hp_fifo_ctrl   <= in_ctrl<<2;
                                 in_hp_fifo_data   <= {in_data[47:0],16'h0};
                                 in_hp_fifo_wr     <= 1;
                              end
                           end
                           else begin
                              state          <= PAYLOAD_1;
                              payload_temp_1 <= in_data[47:0];
                           end
                        end
                        else if (in_ctrl != 0) begin
                           state    <= RESET_F3_HEADER;
                        end
                     end
                     
                     //TRANSP_WIN: begin
                     //   //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-64]   <= in_data;
                     //   old_header     <= {old_header<<64} | in_data;
                     //   old_header_len <= old_header_len + 64;
                     //   if(in_ctrl != 0) begin
                     //      state    <= RESET_F3_HEADER;
                     //   end
                     //end
                     
                     TRANSP_CHK_SUM: begin
                        //old_header[OLD_HEADER_WIDTH-old_header_len-1:OLD_HEADER_WIDTH-old_header_len-32]   <= in_data[63:32];
                        old_header     <= {old_header<<48} | in_data[63:16];
                        old_header_len <= old_header_len + 48;
                        hd_done  <= 1;
                        if(in_ctrl != 0) begin
                           if(in_ctrl == 8'b00000100) begin
                              state    <= MODULE_HDRS;
                           end
                           else if(in_ctrl > 8'b00000100) begin
                              state    <= RESET_F3_HEADER;
                           end
                           else begin
                              state             <= MODULE_HDRS;
                              in_hp_fifo_ctrl   <= in_ctrl<<6;
                              in_hp_fifo_data   <= {in_data[15:0],48'h0};
                              in_hp_fifo_wr     <= 1;
                           end
                        end
                        else begin
                           state             <= PAYLOAD_3;
                           payload_temp_3    <= in_data[15:0];
                        end
                     end
                  endcase // case(counter)
               end // if (in_wr)
            end // case: PKT_WORDS_3
            
            PAYLOAD_0:begin
               if(in_wr) begin
                  in_hp_fifo_ctrl   <= in_ctrl;
                  in_hp_fifo_data   <= in_data;
                  in_hp_fifo_wr     <= 1;
                  if(in_ctrl != 0) begin
                     state    <= MODULE_HDRS;
                  end
               end
            end
            
            PAYLOAD_1:begin
               if(in_wr) begin
                  if(in_ctrl >= 8'b01000000)begin
                     in_hp_fifo_ctrl   <= in_ctrl>>6;
                     in_hp_fifo_data   <= {payload_temp_1,in_data[63:48]};
                     in_hp_fifo_wr     <= 1;
                     state             <= MODULE_HDRS;
                  end
                  else begin
                     in_hp_fifo_ctrl   <= 8'h00;
                     in_hp_fifo_data   <= {payload_temp_1,in_data[63:48]};
                     payload_temp_1    <= in_data[47:0];
                     in_hp_fifo_wr     <= 1;
                     if(in_ctrl < 8'b01000000 && in_ctrl != 0) begin
                        state          <= END_1;
//                        in_rdy         <= 0;
                        in_ctrl_end    <= in_ctrl<<2;
                     end
                  end
               end
            end
            
            PAYLOAD_2:begin
               if(in_wr) begin
                  if(in_ctrl > 8'h0f)begin
                     in_hp_fifo_ctrl   <= in_ctrl>>4;
                     in_hp_fifo_data   <= {payload_temp,in_data[63:32]};
                     in_hp_fifo_wr     <= 1;
                     state             <= MODULE_HDRS;
                  end
                  else begin
                     in_hp_fifo_ctrl   <= 8'h00;
                     in_hp_fifo_data   <= {payload_temp,in_data[63:32]};
                     payload_temp      <= in_data[31:0];
                     in_hp_fifo_wr     <= 1;
                     if(in_ctrl < 8'h10 && in_ctrl != 0) begin
                        state          <= END;
//                        in_rdy         <= 0;
                        in_ctrl_end    <= in_ctrl<<4;
                     end
                  end
               end
            end
            
            PAYLOAD_3:begin
               if(in_wr) begin
                  if(in_ctrl >= 8'b00000100)begin
                     in_hp_fifo_ctrl   <= in_ctrl>>2;
                     in_hp_fifo_data   <= {payload_temp_3,in_data[63:16]};
                     in_hp_fifo_wr     <= 1;
                     state             <= MODULE_HDRS;
                  end
                  else begin
                     in_hp_fifo_ctrl   <= 8'h00;
                     in_hp_fifo_data   <= {payload_temp_3,in_data[63:16]};
                     payload_temp_1    <= in_data[15:0];
                     in_hp_fifo_wr     <= 1;
                     if(in_ctrl < 8'b00000100 && in_ctrl != 0) begin
                        state          <= END_3;
//                        in_rdy         <= 0;
                        in_ctrl_end    <= in_ctrl<<6;
                     end
                  end
               end
            end
            
            END: begin
               in_hp_fifo_ctrl   <= in_ctrl_end;
               in_hp_fifo_data   <= {payload_temp,32'h0};
               in_hp_fifo_wr     <= 1'b1;
               state             <= MODULE_HDRS;
               if(in_wr) begin
                  if(in_ctrl==`IO_QUEUE_STAGE_NUM) begin
                     module_hdr_held         <= in_data;
                     pkt_size_held           <= in_data[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS];
                     in_hp_fifo_ctrl_held    <= in_ctrl;
                     in_hp_fifo_data_held    <= in_data;
                     start_from_second       <= 1;
                  end
               end
            end
            
            END_1: begin
               in_hp_fifo_ctrl   <= in_ctrl_end;
               in_hp_fifo_data   <= {payload_temp_1,16'h0};
               in_hp_fifo_wr     <= 1'b1;
               state             <= MODULE_HDRS;
               if(in_wr) begin
                  if(in_ctrl==`IO_QUEUE_STAGE_NUM) begin
                     module_hdr_held         <= in_data;
                     pkt_size_held           <= in_data[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS];
                     in_hp_fifo_ctrl_held    <= in_ctrl;
                     in_hp_fifo_data_held    <= in_data;
                     start_from_second       <= 1;
                  end
               end
            end
            
            END_3: begin
               in_hp_fifo_ctrl   <= in_ctrl_end;
               in_hp_fifo_data   <= {payload_temp_3,48'h0};
               in_hp_fifo_wr     <= 1'b1;
               state             <= MODULE_HDRS;
               if(in_wr) begin
                  if(in_ctrl==`IO_QUEUE_STAGE_NUM) begin
                     module_hdr_held         <= in_data;
                     pkt_size_held           <= in_data[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS];
                     in_hp_fifo_ctrl_held    <= in_ctrl;
                     in_hp_fifo_data_held    <= in_data;
                     start_from_second       <= 1;
                  end
               end
            end
            
            DROP_WRONG_PKT:begin
               if(in_wr & in_ctrl != 0) begin
                  state          <= MODULE_HDRS;
               end
            end
         endcase // case(state)

         if(hd_done) begin
            module_hdr[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS] <= pkt_size - f3_header_len/8 - old_header_len/8; //payload length
            f3_header_out     <= f3_header << (F3_HEADER_WIDTH-f3_header_len);
            old_header_out    <= old_header << (OLD_HEADER_WIDTH-old_header_len);
            all_vld           <= 1;
         end
      end // else: !if(reset)
   end // always @ (posedge clk)

endmodule // header_parser

