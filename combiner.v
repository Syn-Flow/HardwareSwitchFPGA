///////////////////////////////////////////////////////////////////////////////
// Module: combiner.v
// Project: F3
// Author: wuch
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`include "onet_defines.v"
module combiner
  #(parameter NUM_OUTPUT_QUEUES = 8,
    parameter DATA_WIDTH = 64,
    parameter CTRL_WIDTH = DATA_WIDTH/8,
    parameter F3_HEADER_WIDTH = 400,
    parameter F3_HEADER_WIDTH_BITS = log2(F3_HEADER_WIDTH),
    parameter OLD_HEADER_WIDTH = 432,
    parameter OLD_HEADER_WIDTH_BITS = log2(OLD_HEADER_WIDTH))
  (// --- interface to ap_lookup
   output reg                              result_fifo_rd_en,
   input                                   result_fifo_empty,
   input [DATA_WIDTH-1:0]                  module_hdr,
   input [F3_HEADER_WIDTH-1:0]             f3_header_in,
   input [F3_HEADER_WIDTH_BITS-1:0]        f3_header_len,
   input [OLD_HEADER_WIDTH-1:0]            old_header_in,
   input [OLD_HEADER_WIDTH_BITS-1:0]       old_header_len,
   
   // --- interface to head_parser
   input [CTRL_WIDTH-1:0]                  in_fifo_ctrl,
   input [DATA_WIDTH-1:0]                  in_fifo_data,
   output reg                              in_fifo_rd_en,
   input                                   in_fifo_empty,

   // --- interface to output
   output reg [DATA_WIDTH-1:0]             out_data,
   output reg [CTRL_WIDTH-1:0]             out_ctrl,
   output reg                              out_wr,
   input                                   out_rdy,

   // --- Misc
   input                                   clk,
   input                                   reset);

   `LOG2_FUNC
   `CEILDIV_FUNC

   //-------------------- Internal Parameters ------------------------
   localparam NUM_STATES = 13;
   localparam WAIT_FOR_INPUT              = 1,
              CHECK_OUTPUT_PORT           = 2,
              WRITE_OUTPUT_PORT           = 4,
              WRITE_F3_HEADER             = 8,
              WRITE_OLD_HEADER            = 16,
              WRITE_PAYLOAD_0             = 32,
              WRITE_PAYLOAD_1             = 64,
              WRITE_PAYLOAD_2             = 128,
              WRITE_PAYLOAD_3             = 256,
              EOP_1                       = 512,
              EOP_2                       = 1024,
              EOP_3                       = 2048,
              DROP_PKT                    = 4096;

    //------------------------ Wires/Regs -----------------------------
    
   wire [15:0]                                  pkt_bytes;
   wire [15:0]                                  pkt_words;
   wire [15:0]                                  forward_bitmask;
   
   reg [F3_HEADER_WIDTH-1:0]                    f3_header;
   reg [OLD_HEADER_WIDTH-1:0]                   old_header;
   
    reg [F3_HEADER_WIDTH_BITS-1:0]              f3_counter;
    reg [OLD_HEADER_WIDTH_BITS-1:0]             old_counter;

    reg [NUM_STATES-1:0]                        state;

    reg [31:0]                                  out_data_hi_2;
    reg [15:0]                                  out_data_hi_1;
    reg [47:0]                                  out_data_hi_3;
    reg [CTRL_WIDTH-1:0]                        out_ctrl_temp;

    //-------------------------- Logic --------------------------------
   assign pkt_bytes  = module_hdr[15:0] + f3_header_len/8 + old_header_len/8;
   assign pkt_words  = ceildiv(pkt_bytes, 8);
   assign forward_bitmask  = module_hdr[`IOQ_DST_PORT_POS+15:`IOQ_DST_PORT_POS];

   always @(posedge clk) begin
      if (reset) begin
         state               <= WAIT_FOR_INPUT;
         out_wr              <= 0;
         out_ctrl            <= 0;
         out_data            <= 0;
         result_fifo_rd_en   <= 0;
         in_fifo_rd_en       <= 0;
      end
      else begin
         result_fifo_rd_en          <= 0;
         in_fifo_rd_en              <= 0;
         out_wr                     <= 0;
         out_ctrl                   <= 0;
         out_data                   <= in_fifo_data;

         case (state)
         /* wait until the lookup is done and we have the actions we
          * need to do
          */
            WAIT_FOR_INPUT: begin
               if (!result_fifo_empty) begin
                  result_fifo_rd_en  <= 1;
                  state              <= CHECK_OUTPUT_PORT;
               end
            end

            /* check if an output is specified
             */
            CHECK_OUTPUT_PORT: begin
               //if (|nf2_action_flag) wildcard_wins = 1;
               //else wildcard_lose = 1;
               f3_header   <= f3_header_in;
               old_header  <= old_header_in;
               if (forward_bitmask == 0) begin
                  state    <= DROP_PKT;
               end
               else begin
                  state             <= WRITE_OUTPUT_PORT;
               end
            end // case: CHECK_OUTPUT_PORT
    
            /* write out all the module headers and search for the
             * I/O queue header to insert the destination output queues
             */
            WRITE_OUTPUT_PORT: begin
               if (out_rdy & !in_fifo_empty) begin
                  in_fifo_rd_en  <= 1'b1;
                  if (in_fifo_ctrl == `IO_QUEUE_STAGE_NUM) begin
                     out_data    <= {module_hdr[63:48],pkt_words,module_hdr[31:16],pkt_bytes};
                     out_ctrl    <= 8'hff;
                     state       <= WRITE_F3_HEADER;
                     f3_counter  <= 0;
                     out_wr      <= 1'b1;
                  end
                  // synthesis translate_off
                  else if (in_fifo_ctrl==0 || in_fifo_empty) begin
                     $display ("%t %m ERROR: Could not find IOQ module header", $time);
                     $stop;
                  end
                  // synthesis translate_on
               end // if (out_rdy && !in_fifo_empty)
            end // case: WRITE_OUTPUT_PORT
    
            WRITE_F3_HEADER:begin
               if (out_rdy) begin
                  
                  if (f3_header_len - f3_counter > 64) begin
                     out_data             <= f3_header[F3_HEADER_WIDTH-1:F3_HEADER_WIDTH-64];
                     f3_header            <= f3_header << 64;
                     out_wr               <= 1'b1;
                  end
                  else if(f3_header_len - f3_counter == 16) begin
                     out_data             <= {f3_header[F3_HEADER_WIDTH-1:F3_HEADER_WIDTH-16],
                                             old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-48]};
                     out_wr               <= 1'b1;
                     old_counter          <= 48;
                     old_header           <= old_header << 48;
                     state                <= WRITE_OLD_HEADER;
                  end
                  else if (f3_header_len - f3_counter == 32) begin
                     out_data             <= {f3_header[F3_HEADER_WIDTH-1:F3_HEADER_WIDTH-32],
                                             old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-32]};
                     out_wr               <= 1'b1;
                     old_counter          <= 32;
                     old_header           <= old_header << 32;
                     state                <= WRITE_OLD_HEADER;
                  end
                  else if(f3_header_len - f3_counter == 48) begin
                     out_data             <= {f3_header[F3_HEADER_WIDTH-1:F3_HEADER_WIDTH-48],
                                             old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-16]};
                     out_wr               <= 1'b1;
                     old_counter          <= 16;
                     old_header           <= old_header << 16;
                     state                <= WRITE_OLD_HEADER;
                  end
                  else if(f3_header_len - f3_counter == 64) begin
                     out_data             <= f3_header[F3_HEADER_WIDTH-1:F3_HEADER_WIDTH-64];
                     out_wr               <= 1'b1;
                     old_counter          <= 0;
                     //old_header           <= old_header << 16;
                     state                <= WRITE_OLD_HEADER;
                  end
                  f3_counter <= f3_counter + 64;
               end
            end
            
            WRITE_OLD_HEADER:begin
               if (out_rdy) begin
                  
                  if (old_header_len - old_counter > 112) begin
                     out_data          <= old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-64];
                     old_header        <= old_header << 64;
                     out_wr            <= 1'b1;
                  end
                  else if(old_header_len - old_counter == 64) begin
                     out_data          <= old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-64];
                     out_wr            <= 1'b1;
                     if(!in_fifo_empty)begin
                        state          <= WRITE_PAYLOAD_0;
                        in_fifo_rd_en  <= 1'b1;
                     end
                     else begin
                        state          <= WAIT_FOR_INPUT;
                     end
                  end
                  else if(old_header_len - old_counter == 112) begin
                     out_data             <= old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-64];
                     out_wr               <= 1;
                     out_data_hi_3        <= old_header[OLD_HEADER_WIDTH-65:OLD_HEADER_WIDTH-112];
                     if(!in_fifo_empty)begin
                        state          <= WRITE_PAYLOAD_3;
                        in_fifo_rd_en  <= 1'b1;
                     end
                  end
                  else if(old_header_len - old_counter == 96) begin
                     out_data             <= old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-64];
                     out_wr               <= 1;
                     out_data_hi_2        <= old_header[OLD_HEADER_WIDTH-65:OLD_HEADER_WIDTH-96];
                     if(!in_fifo_empty)begin
                        state          <= WRITE_PAYLOAD_2;
                        in_fifo_rd_en  <= 1'b1;
                     end
                  end
                  else if(old_header_len - old_counter == 80) begin
                     out_data             <= old_header[OLD_HEADER_WIDTH-1:OLD_HEADER_WIDTH-64];
                     out_wr               <= 1;
                     out_data_hi_1       <= old_header[OLD_HEADER_WIDTH-65:OLD_HEADER_WIDTH-80];
                     if(!in_fifo_empty)begin
                        state          <= WRITE_PAYLOAD_1;
                        in_fifo_rd_en  <= 1'b1;
                     end
                  end
                  old_counter <= old_counter + 64;
               end
            end
            
            WRITE_PAYLOAD_0:begin
               if(out_rdy && !in_fifo_empty) begin
                  in_fifo_rd_en        <= 1'b1;
                  out_wr               <= 1'b1;
                  out_data             <= in_fifo_data;
               end
               if(in_fifo_ctrl != 0)begin
                  out_ctrl             <= in_fifo_ctrl;
                  if (!result_fifo_empty) begin
                     result_fifo_rd_en <= 1;
                     in_fifo_rd_en     <= 1'b0;
                     state             <= CHECK_OUTPUT_PORT;
                  end
                  else begin
                     state             <= WAIT_FOR_INPUT;
                  end
               end
            end
            
            WRITE_PAYLOAD_1:begin
               if(out_rdy && !in_fifo_empty) begin
                  out_wr               <= 1'b1;
                  if(in_fifo_ctrl == 0) begin
                     in_fifo_rd_en     <= 1'b1;
                     out_data          <= {out_data_hi_1, in_fifo_data[63:16]};
                     out_data_hi_1     <= in_fifo_data[15:0];
                  end
                  else if(in_fifo_ctrl >= 8'h00000100) begin
                     out_data          <= {out_data_hi_1, in_fifo_data[63:16]};
                     out_ctrl          <= in_fifo_ctrl >> 6;
                     if (!result_fifo_empty) begin
                        result_fifo_rd_en <= 1;
                        state          <= CHECK_OUTPUT_PORT;
                     end
                     else begin
                        state          <= WAIT_FOR_INPUT;
                     end
                  end
                  else begin
                     out_data          <= {out_data_hi_1, in_fifo_data[63:16]};
                     out_data_hi_1     <= in_fifo_data[15:0];
                     out_ctrl_temp     <= in_fifo_ctrl;
                     state             <= EOP_1;
                  end
               end
            end
            
            WRITE_PAYLOAD_2:begin
               if(out_rdy && !in_fifo_empty) begin
                  out_wr               <= 1'b1;
                  if(in_fifo_ctrl == 0) begin
                     in_fifo_rd_en     <= 1'b1;
                     out_data          <= {out_data_hi_2, in_fifo_data[63:32]};
                     out_data_hi_2     <= in_fifo_data[31:0];
                  end
                  else if(in_fifo_ctrl > 8'h0f) begin
                     out_data          <= {out_data_hi_2, in_fifo_data[63:32]};
                     out_ctrl          <= in_fifo_ctrl >> 4;
                     if (!result_fifo_empty) begin
                        result_fifo_rd_en <= 1;
                        state          <= CHECK_OUTPUT_PORT;
                     end
                     else begin
                        state          <= WAIT_FOR_INPUT;
                     end
                  end
                  else begin
                     out_data          <= {out_data_hi_2, in_fifo_data[63:32]};
                     out_data_hi_2     <= in_fifo_data[31:0];
                     out_ctrl_temp     <= in_fifo_ctrl;
                     state             <= EOP_2;
                  end
               end
            end
            
            WRITE_PAYLOAD_3:begin
               if(out_rdy && !in_fifo_empty) begin
                  out_wr               <= 1'b1;
                  if(in_fifo_ctrl == 0) begin
                     in_fifo_rd_en     <= 1'b1;
                     out_data          <= {out_data_hi_3, in_fifo_data[63:48]};
                     out_data_hi_3     <= in_fifo_data[47:0];
                  end
                  else if(in_fifo_ctrl >= 8'b01000000) begin
                     out_data          <= {out_data_hi_3, in_fifo_data[63:48]};
                     out_ctrl          <= in_fifo_ctrl >> 6;
                     if (!result_fifo_empty) begin
                        result_fifo_rd_en <= 1;
                        state          <= CHECK_OUTPUT_PORT;
                     end
                     else begin
                        state          <= WAIT_FOR_INPUT;
                     end
                  end
                  else begin
                     out_data          <= {out_data_hi_3, in_fifo_data[63:48]};
                     out_data_hi_3     <= in_fifo_data[47:0];
                     out_ctrl_temp     <= in_fifo_ctrl;
                     state             <= EOP_3;
                  end
               end
            end
            
            EOP_1:begin
               if (out_rdy) begin
                  out_data             <= {out_data_hi_1, 48'b0};
                  out_ctrl             <= out_ctrl_temp << 6;
                  out_wr               <= 1'b1;
                  if (!result_fifo_empty) begin
                     result_fifo_rd_en <= 1;
                     state             <= CHECK_OUTPUT_PORT;
                  end
                  else begin
                     state             <= WAIT_FOR_INPUT;
                  end
               end
            end
            
            EOP_2:begin
               if (out_rdy) begin
                  out_data             <= {out_data_hi_2, 32'b0};
                  out_ctrl             <= out_ctrl_temp << 4;
                  out_wr               <= 1'b1;
                  if (!result_fifo_empty) begin
                     result_fifo_rd_en <= 1;
                     state             <= CHECK_OUTPUT_PORT;
                  end
                  else begin
                     state             <= WAIT_FOR_INPUT;
                  end
               end
            end
            
            EOP_3:begin
               if (out_rdy) begin
                  out_data             <= {out_data_hi_3, 16'b0};
                  out_ctrl             <= out_ctrl_temp << 2;
                  out_wr               <= 1'b1;
                  if (!result_fifo_empty) begin
                     result_fifo_rd_en <= 1;
                     state             <= CHECK_OUTPUT_PORT;
                  end
                  else begin
                     state             <= WAIT_FOR_INPUT;
                  end
               end
            end

            /* drop the packet
            */
            DROP_PKT: begin
                if (!in_fifo_empty) begin
                    in_fifo_rd_en       <= 1'b1;

                    if (in_fifo_ctrl != 0) begin
                        if (!result_fifo_empty) begin
                            result_fifo_rd_en   <= 1;
                            state               <= CHECK_OUTPUT_PORT;
                        end
                        else begin
                            state <= WAIT_FOR_INPUT;
                        end
                    end
                end // if (!in_fifo_empty)
            end // case: DROP_PKT
         endcase // case(state)
      end
   end // always @ (*)

endmodule // combiner
