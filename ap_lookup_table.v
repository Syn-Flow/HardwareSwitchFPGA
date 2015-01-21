///////////////////////////////////////////////////////////////////////////////
//
// Module: ap_lookup_table.v
///////////////////////////////////////////////////////////////////////////////
`include "onet_defines.v"

  module ap_lookup_table
    #(parameter NUM_OUTPUT_QUEUES = 8,                  // obvious
      parameter PKT_SIZE_WIDTH = 12,                    // number of bits for pkt size
      parameter AP_WIDTH = 16,
      parameter ACTION_WIDTH = 160,
      parameter APT_DEPTH = 8,
      parameter APT_DEPTH_BITS = log2(APT_DEPTH),
      parameter DEFAULT_APT = {ACTION_WIDTH{1'b0}},
      parameter UDP_REG_SRC_WIDTH = 2,                  // identifies which module started this request
      parameter TAG = 13'h1,                                // Tag identifying the address block
      parameter REG_ADDR_WIDTH = 10                      // Width of addresses in the same block
      )
   (// --- Interface for lookups
   input [AP_WIDTH-1:0]                   ap,
   input                                  ap_vld,
   //output reg [AP_WIDTH-1:0]              next_ap,
   output reg [ACTION_WIDTH-1:0]          action,
   output reg                             action_vld,

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
   localparam RESET           = 1;
   localparam WAIT_FOR_INPUT  = 2;

   localparam WAIT_FOR_REQUEST = 1;
   localparam WAIT_FOR_READ_ACK = 2;
   localparam WAIT_FOR_WRITE_ACK = 4;

   localparam NUM_ACTION_WORDS_USED = ceildiv(ACTION_WIDTH,`CPCI_NF2_DATA_WIDTH);
   //localparam NUM_AP_WORDS_USED  = ceildiv(AP_WIDTH, `CPCI_NF2_DATA_WIDTH);
   localparam NUM_REGS_USED = (3 // for the read and write address registers
                               + NUM_ACTION_WORDS_USED // for data associated with an entry
                               /*+ NUM_AP_WORDS_USED */); // for the data to match on

   localparam READ_ADDR  = NUM_REGS_USED-3;
   localparam WRITE_ADDR = READ_ADDR+1;
   localparam TABLE_SIZE_ADDR = WRITE_ADDR+1;

   //---------------------- Wires/Regs -------------------------------
   reg [ACTION_WIDTH-1:0]                    ap_table[APT_DEPTH-1:0];
      
   reg [1:0]                                 state;
   reg [APT_DEPTH_BITS-1:0]                  reset_count;
   
   wire [APT_DEPTH_BITS-1:0]                 lut_addr;
   wire [ACTION_WIDTH+AP_WIDTH-1:0]          lut_data;

   reg [2:0]                                 reg_state;
   integer                                   i;

   wire [REG_ADDR_WIDTH-1:0]                 addr;
   wire [`UDP_REG_ADDR_WIDTH-REG_ADDR_WIDTH-1:0] tag_addr;
   wire                                      addr_good;
   wire                                      tag_hit;

   reg [APT_DEPTH_BITS-1:0]                  rd_addr;          // address in table to read
//   reg                                       rd_req;           // request a read
   wire [ACTION_WIDTH-1:0]                   rd_action;        //
   //wire [AP_WIDTH-1:0]                       rd_ap;            //
//   reg                                       rd_ack;           //

   reg [APT_DEPTH_BITS-1:0]                  wr_addr;          //
   reg                                       wr_req;           //
   wire [ACTION_WIDTH-1:0]                   wr_action;        //
   //wire [AP_WIDTH-1:0]                       wr_ap;            //
   reg                                       wr_ack;

   reg [`CPCI_NF2_DATA_WIDTH-1:0]            reg_file[0:NUM_REGS_USED-1];

    //------------------------- Modules -------------------------------

   //-------------------------- Logic --------------------------------
   assign lut_addr               = ap[APT_DEPTH_BITS-1:0];
   assign lut_data               = ap_table[lut_addr];

   assign addr                   = reg_addr_in;                        // addresses in this module
   assign tag_addr               = reg_addr_in[`UDP_REG_ADDR_WIDTH - 1:REG_ADDR_WIDTH];
   assign addr_good              = addr < NUM_REGS_USED;   // address is used in this module
   assign tag_hit                = tag_addr == TAG;        // address is in this block

   assign rd_action              = ap_table[rd_addr];

   generate
      genvar ii;
      for (ii=0; ii<NUM_ACTION_WORDS_USED-1; ii=ii+1) begin:gen_wraction
         assign wr_action[ii*`CPCI_NF2_DATA_WIDTH +: `CPCI_NF2_DATA_WIDTH] = reg_file[ii];
      end
      assign wr_action[ACTION_WIDTH-1:(NUM_ACTION_WORDS_USED-1)*`CPCI_NF2_DATA_WIDTH] = reg_file[NUM_ACTION_WORDS_USED-1];

      //for (ii=0; ii<NUM_AP_WORDS_USED-1; ii=ii+1) begin:gen_wrap
      //   assign wr_ap[ii*`CPCI_NF2_DATA_WIDTH +: `CPCI_NF2_DATA_WIDTH] = reg_file[ii+NUM_ACTION_WORDS_USED];
      //end
      //assign wr_ap[AP_WIDTH-1:(NUM_AP_WORDS_USED-1)*`CPCI_NF2_DATA_WIDTH]
      //       = reg_file[NUM_AP_WORDS_USED+NUM_ACTION_WORDS_USED-1];
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
         
         reg_file[TABLE_SIZE_ADDR]   <= APT_DEPTH;
         for (i=0; i<NUM_REGS_USED-1; i=i+1) begin
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

               //for (i=0; i<NUM_AP_WORDS_USED-1; i=i+1) begin
               //   reg_file[i+NUM_ACTION_WORDS_USED] <= rd_ap[i*`CPCI_NF2_DATA_WIDTH +: `CPCI_NF2_DATA_WIDTH];
               //end
               //reg_file[NUM_AP_WORDS_USED+NUM_ACTION_WORDS_USED-1]
               //  <= {{(AP_WIDTH % `CPCI_NF2_DATA_WIDTH){1'b0}}, rd_ap[AP_WIDTH-1:(NUM_AP_WORDS_USED-1)*`CPCI_NF2_DATA_WIDTH]};
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

         if(wr_req) begin
            ap_table[wr_addr]    <= wr_action;
            wr_ack               <= 1;
         end

         case(state)
            RESET: begin
               if(reset_count == APT_DEPTH - 1) begin
                  state <= WAIT_FOR_INPUT;
               end
               reset_count <= reset_count + 1'b1;
               if(reset_count == 0) begin
                  ap_table[0]          <= DEFAULT_APT;
               end
               else begin
                  ap_table[reset_count]<= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               end
               /*
               ap_table[0] <= {32'h1, 128'h0f0f0f0f, 16'h0004, 16'h0009};
               ap_table[1] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               ap_table[2] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               ap_table[3] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               ap_table[4] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               ap_table[5] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               ap_table[6] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               ap_table[7] <= {{AP_WIDTH{1'b1}}, {ACTION_WIDTH{1'b0}}};
               state       <= WAIT_FOR_INPUT;
               */
            end
            
            WAIT_FOR_INPUT:begin
               if(ap_vld) begin
                  //next_ap     <= lut_data[AP_WIDTH+ACTION_WIDTH-1:ACTION_WIDTH];
                  action      <= lut_data;
                  action_vld  <= 1;
               end
            end
         endcase
      end
   end // always @ (posedge clk)

endmodule // ap_lookup_table


