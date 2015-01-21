///////////////////////////////////////////////////////////////////////////////
// Module: opl_processor.v
// Project: F3
// Author: wuch
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
//`include "onet_defines.v"
module opl_processor
  #(parameter NUM_OUTPUT_QUEUES = 8,
    parameter DATA_WIDTH = 64,
    parameter CTRL_WIDTH = DATA_WIDTH/8,
    parameter PKT_SIZE_WIDTH = 12,
    parameter ACTION_WIDTH = 64)
  (// --- interface to action fifo
   input [ACTION_WIDTH-1:0]                action_fifo_dout,
   input [PKT_SIZE_WIDTH + 15:0]           parser_result_dout,
   output reg                              result_fifo_rd_en,
   input                                   action_fifo_empty,
   input                                   parser_result_fifo_empty,

   // --- interface to input fifo
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
   localparam NUM_STATES = 9;
   localparam WAIT_FOR_INPUT            = 1,
              CHECK_OUTPUT_PORT         = 2,
              WRITE_OUTPUT_PORT         = 4,
              PUSH_AP                   = 8,
              POP_AP                    = 16,
              WAIT_EOP                  = 32,
              WRITE_PACKET              = 64,
              EOP                       = 128,
              DROP_PKT                  = 256;

    //------------------------ Wires/Regs -----------------------------
    wire [`F3_NF2_ACTION_FLAG_WIDTH-1:0]        nf2_action_flag;
    wire [`F3_FORWARD_BITMASK_WIDTH-1:0]        forward_bitmask;
    wire [`F3_PUSH_AP_WIDTH-1:0]                set_push_ap;
    
    wire [PKT_SIZE_WIDTH-1:0]                   pkt_size;
    wire [7:0]                                  ttl;
    wire [7:0]                                  aps;

    reg [NUM_STATES-1:0]                        state, state_nxt;
                     
    reg [DATA_WIDTH-1:0]                        out_data_nxt;
    reg [31:0]                                  out_data_hi_nxt;
    reg [31:0]                                  out_data_hi;
    reg [CTRL_WIDTH-1:0]                        out_ctrl_temp;
    reg [CTRL_WIDTH-1:0]                        out_ctrl_nxt;
    reg                                         out_wr_nxt;

    //-------------------------- Logic --------------------------------
   assign forward_bitmask
       = (action_fifo_dout[`F3_FORWARD_BITMASK_POS +: `F3_FORWARD_BITMASK_WIDTH]);
   assign nf2_action_flag
       = (action_fifo_dout[`F3_NF2_ACTION_FLAG_POS +: `F3_NF2_ACTION_FLAG_WIDTH]);
   assign set_push_ap  = (action_fifo_dout[`F3_PUSH_AP_POS +: `F3_PUSH_AP_WIDTH]);
   
   assign pkt_size = parser_result_dout[PKT_SIZE_WIDTH+15:16];
   assign ttl = parser_result_dout[15:8];
   assign aps = parser_result_dout[7:0];

    always @(*) begin
        state_nxt                = state;
        result_fifo_rd_en        = 0;
        in_fifo_rd_en            = 0;
        out_wr_nxt               = 0;
        out_ctrl_nxt             = in_fifo_ctrl;
        out_data_nxt             = in_fifo_data;

        case (state)
         /* wait until the lookup is done and we have the actions we
          * need to do
          */
            WAIT_FOR_INPUT: begin
                if (!parser_result_fifo_empty & !action_fifo_empty) begin
                    result_fifo_rd_en   = 1;
                    state_nxt           = CHECK_OUTPUT_PORT;
                end
            end
    
            /* check if an output is specified
             */
            CHECK_OUTPUT_PORT: begin
                //if (|nf2_action_flag) wildcard_wins = 1;
                //else wildcard_lose = 1;
                if (forward_bitmask == 0) begin
                    state_nxt = DROP_PKT;
                end
                else if (out_rdy) begin
                    state_nxt = WRITE_OUTPUT_PORT;
                end
            end // case: CHECK_OUTPUT_PORT
    
            /* write out all the module headers and search for the
             * I/O queue header to insert the destination output queues
             */
            WRITE_OUTPUT_PORT: begin
                if (out_rdy && !in_fifo_empty) begin
                    in_fifo_rd_en       = 1'b1;
                   
                    if (in_fifo_ctrl == `IO_QUEUE_STAGE_NUM) begin
                        if (nf2_action_flag & `NF2_F3AT_PUSH_AP) begin
//                            out_data_nxt[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS] = in_fifo_data[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS];
//                            out_data_nxt[`IOQ_WORD_LEN_POS+15:`IOQ_WORD_LEN_POS] = in_fifo_data[`IOQ_WORD_LEN_POS+15:`IOQ_WORD_LEN_POS];
                            state_nxt = PUSH_AP;
                        end
                        else begin
                            out_data_nxt[`IOQ_BYTE_LEN_POS+15:`IOQ_BYTE_LEN_POS] = pkt_size - 4;
                            out_data_nxt[`IOQ_WORD_LEN_POS+15:`IOQ_WORD_LEN_POS] = ceildiv(pkt_size-4, 8);
                            state_nxt = POP_AP;
                        end
                        out_data_nxt[`IOQ_DST_PORT_POS+15:`IOQ_DST_PORT_POS] = forward_bitmask;
                        //out_data_nxt[`IOQ_SRC_PORT_POS+15:`IOQ_SRC_PORT_POS] = in_fifo_data[`IOQ_SRC_PORT_POS+15:`IOQ_SRC_PORT_POS];
                        out_wr_nxt = 1'b1;
                    end
                    // synthesis translate_off
                    else if (in_fifo_ctrl==0 || in_fifo_empty) begin
                        $display ("%t %m ERROR: Could not find IOQ module header", $time);
                        $stop;
                    end
                    // synthesis translate_on
                end // if (out_rdy && !in_fifo_empty)
            end // case: WRITE_OUTPUT_PORT
    
            PUSH_AP:begin
                if (out_rdy && !in_fifo_empty) begin
                    in_fifo_rd_en           = 1'b1;
                    if (in_fifo_ctrl == 0) begin
                        if(nf2_action_flag & `NF2_F3AT_DEC_TTL)begin
                            out_data_nxt[63:56] = ttl - 1'b1;
                        end
                        //out_data_nxt[55:48] = in_fifo_data[55:48];
                        out_data_nxt[47:16] = set_push_ap;
                        //out_data_nxt[15:0]  = in_fifo_data[15:0];
                        out_wr_nxt          = 1'b1;
                        state_nxt           = WAIT_EOP;
                    end
                end
            end
            
            POP_AP:begin
                if (out_rdy && !in_fifo_empty) begin
                    in_fifo_rd_en = 1'b1;
                    if (in_fifo_ctrl == 0) begin
                        if(nf2_action_flag & `NF2_F3AT_DEC_TTL)begin
                           out_data_hi_nxt[31:24] = ttl - 1'b1;
                        end
                        else begin
                           out_data_hi_nxt[31:24] = ttl;
                        end
                        out_data_hi_nxt[23:16]    = aps - 1;
                        out_data_hi_nxt[15:0]     = in_fifo_data[15:0];
                        state_nxt                  = WRITE_PACKET;
                    end
                end
            end

            /* write the rest of the packet data
            */
            WRITE_PACKET: begin
                if (out_rdy && !in_fifo_empty) begin
                    in_fifo_rd_en       = 1'b1;
                    out_wr_nxt          = 1'b1;
                    if(in_fifo_ctrl == 0)begin
                        out_data_nxt        = {out_data_hi, in_fifo_data[63:32]};
                        out_data_hi_nxt    = in_fifo_data[31:0];
                    end
                    else if(in_fifo_ctrl >= 8'b00010000) begin
                        out_data_nxt    = {out_data_hi_nxt, in_fifo_data[63:32]};
                        out_ctrl_nxt    = in_fifo_ctrl >> 4;
                        if (!parser_result_fifo_empty && !action_fifo_empty) begin
                            result_fifo_rd_en = 1;
                            state_nxt         = CHECK_OUTPUT_PORT;
                        end
                        else begin
                            state_nxt = WAIT_FOR_INPUT;
                        end
                    end
                    else begin
                        out_data_nxt        = {out_data_hi_nxt, in_fifo_data[63:32]};
                        out_data_hi_nxt    = in_fifo_data[31:0];
                        out_ctrl_temp       = in_fifo_ctrl;
                        state_nxt           = EOP;
                    end
                end // if (out_rdy)
            end // case: WRITE_PACKET
            
            EOP:begin
                if (out_rdy) begin
                    out_data_nxt        = {out_data_hi_nxt, 32'b0};
                    out_ctrl_nxt        = out_ctrl_temp << 4;
                    out_wr_nxt          = 1'b1;
                    if (!parser_result_fifo_empty && !action_fifo_empty) begin
                        result_fifo_rd_en = 1;
                        state_nxt         = CHECK_OUTPUT_PORT;
                    end
                    else begin
                        state_nxt = WAIT_FOR_INPUT;
                    end
                end
            end
            
            WAIT_EOP:begin
                if (out_rdy && !in_fifo_empty) begin
                    in_fifo_rd_en       = 1'b1;
                    out_wr_nxt          = 1'b1;
                    out_data_nxt        = in_fifo_data;
                    if(in_fifo_ctrl != 0)begin
                        if (!parser_result_fifo_empty && !action_fifo_empty) begin
                            result_fifo_rd_en = 1;
                            state_nxt         = CHECK_OUTPUT_PORT;
                        end
                        else begin
                            state_nxt = WAIT_FOR_INPUT;
                        end
                    end
                end
            end
            /* drop the packet
            */
            DROP_PKT: begin
                if (!in_fifo_empty) begin
                    in_fifo_rd_en       = 1'b1;

                    if (in_fifo_ctrl != 0) begin
                        if (!parser_result_fifo_empty && !action_fifo_empty) begin
                            result_fifo_rd_en = 1;
                            state_nxt         = CHECK_OUTPUT_PORT;
                        end
                        else begin
                            state_nxt = WAIT_FOR_INPUT;
                        end
                    end
                end // if (!in_fifo_empty)
            end // case: DROP_PKT
      endcase // case(state)
   end // always @ (*)

    always @(posedge clk) begin
        if (reset) begin
            state               <= WAIT_FOR_INPUT;
            out_wr              <= 0;
            out_ctrl            <= 0;
            out_data            <= 0;
        end
        else begin
            state                <= state_nxt;
            out_wr               <= out_wr_nxt;
            out_ctrl             <= out_ctrl_nxt;
            out_data             <= out_data_nxt;
            out_data_hi          <= out_data_hi_nxt;
        end // else: !if (reset)
    end // always @ (posedge clk)


endmodule // opl_processor
