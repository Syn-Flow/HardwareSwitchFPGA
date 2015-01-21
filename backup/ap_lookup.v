///////////////////////////////////////////////////////////////////////////////
//
// Module: ap_lookup.v
///////////////////////////////////////////////////////////////////////////////
//`include "onet_defines.v"

  module ap_lookup
    #(parameter NUM_OUTPUT_QUEUES = 8,                  // obvious
      parameter PKT_SIZE_WIDTH = 12,                    // number of bits for pkt size
      parameter AP_WIDTH = 32,
      parameter ACTION_WIDTH = 64,
      parameter APT_DEPTH = `F3_ACTION_TABLE_SIZE,
      parameter APT_DEPTH_BITS = log2(APT_DEPTH),
      parameter UDP_REG_SRC_WIDTH = 2,                  // identifies which module started this request
      parameter TAG = 13'h1,                                // Tag identifying the address block
      parameter REG_ADDR_WIDTH = 10                      // Width of addresses in the same block
      )
   (// --- Interface for lookups
   input [AP_WIDTH-1:0]                   ap_entry,
   input                                  ap_fifo_empty,
   output reg                             ap_fifo_rd_en,
   input [PKT_SIZE_WIDTH-1:0]             pkt_size,
   input [7:0]                            ttl,
   input [7:0]                            aps,
  
   // --- Interface to opl_processer  
   output [ACTION_WIDTH-1:0]              action,
   output [PKT_SIZE_WIDTH + 15:0]         parser_result_dout,
   output                                 parser_restult_fifo_empty,
   output                                 action_fifo_empty,
   input                                  fifo_rd_en,

   // --- Interface to registers
   input                                  reg_req_in,
   input                                  reg_ack_in,
   input                                  reg_rd_wr_L_in,
   input  [`UDP_REG_ADDR_WIDTH-1:0]       reg_addr_in,
   input  [`CPCI_NF2_DATA_WIDTH-1:0]      reg_data_in,
   input  [UDP_REG_SRC_WIDTH-1:0]         reg_src_in,

   output reg                             reg_req_out,
   output reg                             reg_ack_out,
   output reg                             reg_rd_wr_L_out,
   output reg [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
   output reg [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
   output reg [UDP_REG_SRC_WIDTH-1:0]     reg_src_out,

   // --- Misc
   input                                  reset,
   input                                  clk
   );
   `LOG2_FUNC
   `CEILDIV_FUNC
   //------------------ Internal Parameter ---------------------------
   localparam RESET           = 0;
   localparam WAIT_FOR_INPUT  = 1;
   localparam INIT            = 2;
   localparam LOOP            = 3;

   localparam WAIT_FOR_REQUEST = 1;
   localparam WAIT_FOR_READ_ACK = 2;
   localparam WAIT_FOR_WRITE_ACK = 4;

   localparam NUM_ACTION_WORDS_USED = ceildiv(ACTION_WIDTH,`CPCI_NF2_DATA_WIDTH);
   localparam NUM_AP_WORDS_USED  = ceildiv(AP_WIDTH, `CPCI_NF2_DATA_WIDTH);
   localparam NUM_REGS_USED = (2 // for the read and write address registers
                               + NUM_ACTION_WORDS_USED // for data associated with an entry
                               + NUM_AP_WORDS_USED ); // for the data to match on

   localparam READ_ADDR  = NUM_REGS_USED-2;
   localparam WRITE_ADDR = READ_ADDR+1;

   //---------------------- Wires/Regs -------------------------------
   reg [ACTION_WIDTH+AP_WIDTH-1:0]           ap_table[APT_DEPTH-1:0];
      
   reg [1:0]                                 state;
   reg [APT_DEPTH_BITS-1:0]                  reset_count;
      
   wire [ACTION_WIDTH+AP_WIDTH-1:0]          ap_ac;
   reg [AP_WIDTH-1:0]                        ap_next;
   wire [ACTION_WIDTH-1:0]                   action_temp;
   reg  [ACTION_WIDTH-1:0]                   action_fifo_in;
   wire [APT_DEPTH_BITS-1:0]                 addr_next;
   wire                                      ap_end;

   reg                                       action_vld;

   reg [2:0]                                 reg_state;
   integer                                   i;

   wire [REG_ADDR_WIDTH-1:0]                 addr;
   wire [`UDP_REG_ADDR_WIDTH-REG_ADDR_WIDTH-1:0] tag_addr;
   wire                                      addr_good;
   wire                                      tag_hit;

   reg [APT_DEPTH_BITS-1:0]                  rd_addr;          // address in table to read
//   reg                                       rd_req;           // request a read
   wire [ACTION_WIDTH-1:0]                   rd_action;        //
   wire [AP_WIDTH-1:0]                       rd_ap;            //
//   reg                                       rd_ack;           //

   reg [APT_DEPTH_BITS-1:0]                  wr_addr;          //
   reg                                       wr_req;           //
   wire [ACTION_WIDTH-1:0]                   wr_action;        //
   wire [AP_WIDTH-1:0]                       wr_ap;            //
   reg                                       wr_ack;

   reg [`CPCI_NF2_DATA_WIDTH-1:0]            reg_file[0:NUM_REGS_USED-1];

    //------------------------- Modules -------------------------------
   fallthrough_small_fifo
     #(.WIDTH(PKT_SIZE_WIDTH + 16),
       .MAX_DEPTH_BITS(3))
      parser_result_fifo
        (.din           ({pkt_size, ttl, aps}),
         .wr_en         (ap_fifo_rd_en),
         .rd_en         (fifo_rd_en),
         .dout          (parser_result_dout),
         .full          (),
         .nearly_full   (),
         .empty         (parser_restult_fifo_empty),
         .reset         (reset),
         .clk           (clk)
         );

   fallthrough_small_fifo
     #(.WIDTH(ACTION_WIDTH),
       .MAX_DEPTH_BITS(3))
      action_fifo
        (.din           (action_fifo_in),
         .wr_en         (action_vld),
         .rd_en         (fifo_rd_en),
         .dout          (action),
         .full          (),
         .nearly_full   (),
         .empty         (action_fifo_empty),
         .reset         (reset),
         .clk           (clk)
         );
   //-------------------------- Logic --------------------------------
   assign addr_next              = ap_next[APT_DEPTH_BITS-1:0];
   assign ap_end                 = ap_next[AP_WIDTH-1];
   assign ap_ac                  = ap_table[addr_next];
   assign action_temp            = ap_ac[ACTION_WIDTH-1:0];

   assign addr                   = reg_addr_in;                        // addresses in this module
   assign tag_addr               = reg_addr_in[`UDP_REG_ADDR_WIDTH - 1:REG_ADDR_WIDTH];
   assign addr_good              = addr < NUM_REGS_USED;   // address is used in this module
   assign tag_hit                = tag_addr == TAG;        // address is in this block

   assign {rd_ap, rd_action}     = ap_table[rd_addr];

   generate
      genvar ii;
      for (ii=0; ii<NUM_ACTION_WORDS_USED-1; ii=ii+1) begin:gen_wraction
         assign wr_action[ii*`CPCI_NF2_DATA_WIDTH +: `CPCI_NF2_DATA_WIDTH] = reg_file[ii];
      end
      assign wr_action[ACTION_WIDTH-1:(NUM_ACTION_WORDS_USED-1)*`CPCI_NF2_DATA_WIDTH] = reg_file[NUM_ACTION_WORDS_USED-1];

      for (ii=0; ii<NUM_AP_WORDS_USED-1; ii=ii+1) begin:gen_wrap
         assign wr_ap[ii*`CPCI_NF2_DATA_WIDTH +: `CPCI_NF2_DATA_WIDTH] = reg_file[ii+NUM_ACTION_WORDS_USED];
      end
      assign wr_ap[AP_WIDTH-1:(NUM_AP_WORDS_USED-1)*`CPCI_NF2_DATA_WIDTH]
             = reg_file[NUM_AP_WORDS_USED+NUM_ACTION_WORDS_USED-1];
   endgenerate

   /* Handle registers */
   always @(posedge clk) begin
      if(reset) begin
         reg_req_out        <= 0;
         reg_ack_out        <= 0;
         reg_rd_wr_L_out    <= 0;
         reg_addr_out       <= 0;
         reg_src_out        <= 0;
         reg_data_out       <= 0;

         wr_req             <= 0;
         reg_state          <= WAIT_FOR_REQUEST;

         wr_addr            <= 0;
         rd_addr            <= 0;

         for (i=0; i<NUM_REGS_USED; i=i+1) begin
            reg_file[i] <= 0;
         end
      end
      else begin
         reg_req_out     <= 1'b0;
         reg_ack_out     <= 1'b0;
         reg_rd_wr_L_out <= reg_rd_wr_L_in;
         reg_addr_out    <= reg_addr_in;
         reg_src_out     <= reg_src_in;
         reg_data_out    <= reg_data_in;

         wr_req          <= 0;

         case (reg_state)
            WAIT_FOR_REQUEST: begin
               /* check if we should respond to this address */
               if(addr_good && tag_hit && reg_req_in) begin

                  /* check if this is a write to the read addr register
                   * or the write addr register. */
                  if (!reg_rd_wr_L_in && addr == READ_ADDR) begin
                     /* we need to pull data from the cam/lut */
                     rd_addr                 <= reg_data_in;
                     reg_state               <= WAIT_FOR_READ_ACK;
                     reg_file[READ_ADDR]     <= reg_data_in;
                  end // if (!reg_rd_wr_L_in && addr == READ_ADDR)

                  else if (!reg_rd_wr_L_in && addr == WRITE_ADDR) begin
                     /* we need to write data to the cam/lut */
                     wr_addr                 <= reg_data_in;
                     wr_req                  <= 1;
                     reg_state               <= WAIT_FOR_WRITE_ACK;
                     reg_file[WRITE_ADDR]    <= reg_data_in;
                  end // if (!reg_rd_wr_L_in && addr == WRITE_ADDR)

                  else begin
                     /* not a write to a special address */
                     reg_req_out        <= reg_req_in;
                     reg_ack_out        <= 1'b1;
                     /* if read */
                     if(reg_rd_wr_L_in) begin
                        reg_data_out       <= reg_file[addr];
                     end
                     /* if write */
                     else begin
                        reg_data_out       <= reg_data_in;
                        reg_file[addr]     <= reg_data_in;
                     end
                  end // else: !if(!reg_rd_wr_L_in && addr == WRITE_ADDR)

               end // if (addr_good && tag_hit && reg_req_in)

               /* otherwise just forward anything that comes over */
               else begin
                  reg_req_out        <= reg_req_in;
                  reg_ack_out        <= reg_ack_in;
               end // else: !if(addr_good && tag_hit && reg_req_in)

            end // case: WAIT_FOR_REQUEST

            WAIT_FOR_READ_ACK: begin
               reg_req_out    <= 1'b1;
               reg_ack_out    <= 1'b1;
               reg_state      <= WAIT_FOR_REQUEST;

               /* put the info in the registers */
               for (i=0; i<NUM_ACTION_WORDS_USED-1; i=i+1) begin
                  reg_file[i] <= rd_action[i*`CPCI_NF2_DATA_WIDTH +: `CPCI_NF2_DATA_WIDTH];
               end
               reg_file[NUM_ACTION_WORDS_USED-1] <= {{(ACTION_WIDTH % `CPCI_NF2_DATA_WIDTH){1'b0}},
                                                   rd_action[ACTION_WIDTH-1:(NUM_ACTION_WORDS_USED-1)*`CPCI_NF2_DATA_WIDTH]};

               for (i=0; i<NUM_AP_WORDS_USED-1; i=i+1) begin
                  reg_file[i+NUM_ACTION_WORDS_USED] <= rd_ap[i*`CPCI_NF2_DATA_WIDTH +: `CPCI_NF2_DATA_WIDTH];
               end
               reg_file[NUM_AP_WORDS_USED+NUM_ACTION_WORDS_USED-1]
                 <= {{(AP_WIDTH % `CPCI_NF2_DATA_WIDTH){1'b0}}, rd_ap[AP_WIDTH-1:(NUM_AP_WORDS_USED-1)*`CPCI_NF2_DATA_WIDTH]};
            end

            WAIT_FOR_WRITE_ACK: begin
               if(wr_ack) begin
                  reg_req_out    <= 1'b1;
                  reg_ack_out    <= 1'b1;
                  reg_state      <= WAIT_FOR_REQUEST;
               end
               else begin
                  wr_req <= 1;
               end
            end
         endcase // case(reg_state)
      end // else: !if(reset)
   end // always @ (posedge clk)


   always @(posedge clk) begin
      if(reset) begin
         state             <= RESET;
         action_vld        <= 0;
         reset_count       <= 0;
      end
      else begin
         action_vld        <= 0;
         ap_fifo_rd_en     <= 0;

         if(wr_req) begin
            ap_table[wr_addr]    <= {wr_ap, wr_action};
            wr_ack               <= 1;
         end

         case(state)
            RESET: begin/*
               if(reset_count == APT_DEPTH - 1) begin
                  state <= READY;
               end
               reset_count <= reset_count + 1'b1;
               ap_table[reset_count] = {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               */
               ap_table[0] <= {32'h1, 32'h0, 16'h0004, 16'h0001};
               ap_table[1] <= {1'b1, 31'h2, 32'h0f0f0f0f, 16'h0000, 16'h0002};
               ap_table[2] <= {32'hffffffff, 32'h0, 16'h0000, 16'h0004};
               
               ap_table[3] <= {1'b1, 31'h4, 32'h0, 16'h0004, 16'h0001};
               ap_table[4] <= {{AP_WIDTH{1'b1}}, 32'h0, 16'h0000, 16'h0004};
               
               ap_table[5] <= {{AP_WIDTH{1'b1}}, 32'h00abcdef, 16'h0006, 16'h0007};
               
               ap_table[6] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               ap_table[7] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               state       <= WAIT_FOR_INPUT;
            end
            
            WAIT_FOR_INPUT:begin
               if(!ap_fifo_empty) begin
                  ap_fifo_rd_en     <= 1;
                  state             <= INIT;
               end
            end
            
            INIT: begin
               ap_next              <= ap_entry;
               action_fifo_in       <= 0;
               state                <= LOOP;
            end
            
            LOOP: begin
               action_fifo_in       <= action_fifo_in | action_temp;
               if(ap_end)begin
                  if(!ap_fifo_empty) begin
                     ap_fifo_rd_en  <= 1;
                     state          <= INIT;
                  end
                  else begin
                     state          <= WAIT_FOR_INPUT;
                  end
                  action_vld        <= 1;
               end
               else begin
                  ap_next           <= ap_ac[ACTION_WIDTH+AP_WIDTH-1:ACTION_WIDTH];
               end
            end
         endcase
      end
   end // always @ (posedge clk)

endmodule // wildcard_match


