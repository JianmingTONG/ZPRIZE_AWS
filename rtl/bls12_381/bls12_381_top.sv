/*
  This module is the top level for the BLS12-381 coprocessor.
  Runs on instruction memory and has access to slot memory.

  Copyright (C) 2019  Benjamin Devlin and Zcash Foundation

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

module bls12_381_top
  import bls12_381_pkg::*;
#(
  parameter USE_KARATSUBA = "YES"
)(
  input i_clk, i_rst,
  // Only tx interface is used to send messages to SW on a SEND-INTERRUPT instruction
  if_axi_stream.source tx_if,
  // User access to the instruction, data, and config
  if_axi_lite.sink     axi_lite_if
);

localparam DAT_BITS = bls12_381_pkg::DAT_BITS;
localparam AXI_STREAM_BYTS = 8;

parameter type FE_TYPE   = bls12_381_pkg::fe_t;
parameter type FE2_TYPE  = bls12_381_pkg::fe2_t;
parameter type FE6_TYPE  = bls12_381_pkg::fe6_t;
parameter type FE12_TYPE = bls12_381_pkg::fe12_t;
parameter P              = bls12_381_pkg::P;

// Used for sending interrupts back to SW
import zcash_fpga_pkg::bls12_381_interrupt_rpl_t;
import zcash_fpga_pkg::bls12_381_interrupt_rpl;
bls12_381_interrupt_rpl_t interrupt_rpl;
enum {WAIT_FIFO, SEND_HDR, SEND_DATA} interrupt_state;
logic [7:0] interrupt_hdr_byt;


logic [READ_CYCLE:0] inst_ram_read, data_ram_read;
logic reset_inst_ram, reset_data_ram;

logic [31:0] mult_ram_d;
logic mult_ram_we, mult_ram_se;

// Instruction RAM
if_ram #(.RAM_WIDTH(bls12_381_pkg::INST_RAM_WIDTH), .RAM_DEPTH(bls12_381_pkg::INST_RAM_DEPTH)) inst_ram_sys_if(.i_clk(i_clk), .i_rst(i_rst || reset_inst_ram));
if_ram #(.RAM_WIDTH(bls12_381_pkg::INST_RAM_WIDTH), .RAM_DEPTH(bls12_381_pkg::INST_RAM_DEPTH)) inst_ram_usr_if(.i_clk(i_clk), .i_rst(i_rst || reset_inst_ram));
inst_t curr_inst;

// Data RAM
if_ram #(.RAM_WIDTH(bls12_381_pkg::DATA_RAM_WIDTH), .RAM_DEPTH(bls12_381_pkg::DATA_RAM_DEPTH)) data_ram_sys_if(.i_clk(i_clk), .i_rst(i_rst || reset_data_ram));
if_ram #(.RAM_WIDTH(bls12_381_pkg::DATA_RAM_WIDTH), .RAM_DEPTH(bls12_381_pkg::DATA_RAM_DEPTH)) data_ram_usr_if(.i_clk(i_clk), .i_rst(i_rst || reset_data_ram));
data_t curr_data, new_data;

// Loading the fifo with slots and outputting an interrupt
if_axi_stream #(.DAT_BYTS(48)) interrupt_in_if(i_clk);
if_axi_stream #(.DAT_BYTS(8)) interrupt_out_if(i_clk);
if_axi_stream #(.DAT_BYTS(3)) idx_in_if(i_clk);
if_axi_stream #(.DAT_BYTS(3)) idx_out_if(i_clk);

// Point multiplication
logic [1:0] pair_mode;
fe_t  pair_key;
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mult_pt_if (i_clk);

if_axi_stream #(.DAT_BITS(2*$bits(bls12_381_pkg::fp2_jb_point_t))) add_i_if(i_clk);
if_axi_stream #(.DAT_BITS($bits(bls12_381_pkg::fp2_jb_point_t)))   add_o_if(i_clk);
if_axi_stream #(.DAT_BITS($bits(bls12_381_pkg::fp2_jb_point_t)))   dbl_i_if(i_clk);
if_axi_stream #(.DAT_BITS($bits(bls12_381_pkg::fp2_jb_point_t)))   dbl_o_if(i_clk);

localparam CTL_BITS = 128;

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_in_if  [2:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_out_if [2:0] (i_clk);
if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) add_in_if        (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   add_out_if       (i_clk);
if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) sub_in_if        (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   sub_out_if       (i_clk);

if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   inv_fe_o_if      (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   inv_fe_i_if      (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   inv_fe2_o_if     (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   inv_fe2_i_if     (i_clk);

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_fe12_o_if     (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_fe12_i_if     (i_clk);


if_axi_stream #(.DAT_BITS($bits(FE_TYPE))) pair_i_af_if  (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE))) pair_o_res_if (i_clk);

logic [31:0] new_inst_pt;
logic        new_inst_pt_val, new_inst_pt_val_l;
logic        reset_done_inst, reset_done_data;

logic [7:0] cnt;
integer unsigned pt_size;

always_comb begin
  curr_inst = inst_ram_sys_if.q;
  curr_data = data_ram_sys_if.q;
  data_ram_sys_if.d = new_data;
end

code_t inst_state;
point_type_t pt_l;

logic [31:0] last_inst_cnt, curr_inst_pt;

always_ff @ (posedge i_clk) begin
  if (i_rst) begin
    inst_ram_sys_if.reset_source();
    data_ram_sys_if.we <= 0;
    data_ram_sys_if.a <= 0;
    data_ram_sys_if.re <= 1;
    data_ram_sys_if.en <= 1;
    inst_ram_read <= 0;
    data_ram_read <= 0;
    cnt <= 0;
    inv_fe_o_if.reset_source();
    inv_fe_i_if.rdy <= 0;
    inv_fe2_o_if.reset_source();
    inv_fe2_i_if.rdy <= 0;
    inst_state <= NOOP_WAIT;
    pt_l <= SCALAR;
    new_data <= 0;
    pt_size <= 0;
    idx_in_if.reset_source();
    interrupt_in_if.reset_source();
    last_inst_cnt <= 0;
    pair_o_res_if.rdy <= 0;

    new_inst_pt_val_l <= 0;

    mul_in_if[1].reset_source();
    add_in_if.reset_source();
    sub_in_if.reset_source();

    mul_out_if[1].rdy <= 0;
    add_out_if.rdy <= 0;
    sub_out_if.rdy <= 0;

    pair_i_af_if.reset_source();

    pair_mode <= 0;
    pair_key <= 0;
    mult_pt_if.rdy <= 0;

    mul_fe12_o_if.reset_source();
    mul_fe12_i_if.rdy <= 0;

  end else begin

    mul_in_if[1].sop <= 1;
    mul_in_if[1].eop <= 1;
    add_in_if.sop <= 1;
    add_in_if.eop <= 1;
    sub_in_if.sop <= 1;
    sub_in_if.eop <= 1;

    new_inst_pt_val_l <= new_inst_pt_val || new_inst_pt_val_l; // Latch this pulse if we want to update instruction pointer

    inst_ram_sys_if.re <= 1;
    inst_ram_sys_if.en <= 1;
    inst_ram_read <= inst_ram_read << 1;

    data_ram_sys_if.re <= 1;
    data_ram_sys_if.en <= 1;
    data_ram_sys_if.we <= 0;
    data_ram_read <= data_ram_read << 1;

    if (inv_fe_o_if.rdy) inv_fe_o_if.val <= 0;
    if (inv_fe2_o_if.rdy) inv_fe2_o_if.val <= 0;
    if (add_in_if.rdy) add_in_if.val <= 0;
    if (sub_in_if.rdy) sub_in_if.val <= 0;
    if (mul_in_if[1].rdy) mul_in_if[1].val <= 0;
    if (pair_i_af_if.rdy) pair_i_af_if.val <= 0;
    if (mul_fe12_o_if.rdy) mul_fe12_o_if.val <= 0;

    mult_pt_if.rdy <= 1;
    mul_fe12_i_if.rdy <= 1;

    if (idx_in_if.val && idx_in_if.rdy) idx_in_if.val <= 0;
    if (interrupt_in_if.val && interrupt_in_if.rdy) interrupt_in_if.val <= 0;

    last_inst_cnt <= last_inst_cnt + 1;

    case(inst_state)
      NOOP_WAIT: begin
        last_inst_cnt <= last_inst_cnt;
        // Wait in this state
        get_next_inst();
      end
      JUMP: begin
        last_inst_cnt <= last_inst_cnt;
        task_jump();
      end
      JUMP_IF_EQ: begin
        last_inst_cnt <= last_inst_cnt;
        task_jump_if_eq();
      end
      JUMP_NONZERO_SUB: begin
        last_inst_cnt <= last_inst_cnt;
        task_jump_nonzero_sub();
      end
      COPY_REG: begin
        last_inst_cnt <= last_inst_cnt;
        task_copy_reg();
      end
      INV_ELEMENT: begin
        if (cnt == 0) last_inst_cnt <= 0;
        task_inv_element();
      end
      MUL_ELEMENT: begin
        if (cnt == 0) last_inst_cnt <= 0;
        task_mul_element();
      end
      SUB_ELEMENT: begin
        if (cnt == 0) last_inst_cnt <= 0;
        task_sub_element();
      end
      ADD_ELEMENT: begin
        if (cnt == 0) last_inst_cnt <= 0;
        task_add_element();
      end
      SEND_INTERRUPT: begin
        last_inst_cnt <= last_inst_cnt;
        task_send_interrupt();
      end
      POINT_MULT: begin
        if (cnt == 0) last_inst_cnt <= 0;
        task_point_mult();
      end
      ATE_PAIRING: begin
        if (cnt == 0) last_inst_cnt <= 0;
        pair_mode <= 0;
        task_pairing();
      end
      MILLER_LOOP: begin
        if (cnt == 0) last_inst_cnt <= 0;
        pair_mode <= 2;
        task_pairing();
      end
      FINAL_EXP: begin
        if (cnt == 0) last_inst_cnt <= 0;
        task_final_exp();
      end
      default: get_next_inst();
    endcase

  end
end

bls12_381_axi_bridge bls12_381_axi_bridge (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .axi_lite_if        ( axi_lite_if     ),
  .data_ram_if        ( data_ram_usr_if ),
  .inst_ram_if        ( inst_ram_usr_if ),
  .i_curr_inst_pt     ( curr_inst_pt    ),
  .i_last_inst_cnt    ( last_inst_cnt   ),
  .i_reset_done       ( reset_done_data && reset_done_inst ),
  .o_new_inst_pt      ( new_inst_pt     ),
  .o_new_inst_pt_val  ( new_inst_pt_val ),
  .o_reset_inst_ram   ( reset_inst_ram  ),
  .o_reset_data_ram   ( reset_data_ram  ),
  .o_ram_d            ( mult_ram_d      ),
  .o_ram_we           ( mult_ram_we     ),
  .o_ram_se           ( mult_ram_se     )
);

always_comb begin
  curr_inst_pt = 0;
  curr_inst_pt = inst_ram_sys_if.a;
end

uram_reset #(
  .RAM_WIDTH(bls12_381_pkg::INST_RAM_WIDTH),
  .RAM_DEPTH(bls12_381_pkg::INST_RAM_DEPTH),
  .PIPELINES( READ_CYCLE - 2 )
)
inst_uram_reset (
  .a ( inst_ram_usr_if ),
  .b ( inst_ram_sys_if ),
  .o_reset_done ( reset_done_inst )
);

uram_reset #(
  .RAM_WIDTH(bls12_381_pkg::DATA_RAM_WIDTH),
  .RAM_DEPTH(bls12_381_pkg::DATA_RAM_DEPTH),
  .PIPELINES( READ_CYCLE - 2 )
)
data_uram_reset (
  .a ( data_ram_usr_if ),
  .b ( data_ram_sys_if ),
  .o_reset_done ( reset_done_data )
);

bls12_381_pairing_wrapper #(
  .CTL_BITS    ( CTL_BITS ),
  .OVR_WRT_BIT ( 0        )
)
bls12_381_pairing_wrapper (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_pair_af_if ( pair_i_af_if ),
  .i_mode  ( pair_mode ),
  .i_key   ( pair_key  ),
  .o_fe12_if     ( pair_o_res_if ),
  .o_p_jb_if     ( mult_pt_if    ),
  .o_mul_fe_if   ( mul_in_if[0]  ),
  .i_mul_fe_if   ( mul_out_if[0] ),
  .i_mul_fe12_if ( mul_fe12_o_if ),
  .o_mul_fe12_if ( mul_fe12_i_if ),
  .o_inv_fe2_if  ( inv_fe2_i_if  ),
  .i_inv_fe2_if  ( inv_fe2_o_if  ),
  .o_inv_fe_if   ( inv_fe_i_if   ),
  .i_inv_fe_if   ( inv_fe_o_if   )
);

resource_share # (
  .NUM_IN       ( 2                ),
  .DAT_BITS     ( 2*$bits(FE_TYPE) ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( 120              ),
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 0                )
)
resource_share_mul (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( mul_in_if[1:0]  ),
  .o_res ( mul_in_if[2]    ),
  .i_res ( mul_out_if[2]   ),
  .o_axi ( mul_out_if[1:0] )
);

generate
  if (USE_KARATSUBA == "YES") begin: GEN_KARATSUBA
    ec_fp_mult_mod #(
      .P             ( P        ),
      .KARATSUBA_LVL ( 3        ),
      .CTL_BITS      ( CTL_BITS )
    )
    ec_fp_mult_mod (
      .i_clk( i_clk ),
      .i_rst( i_rst ),
      .i_mul ( mul_in_if[2]  ),
      .o_mul ( mul_out_if[2] )
    );
  end else begin
    accum_mult_mod #(
      .DAT_BITS ( $bits(FE_TYPE) ),
      .MODULUS  ( P ),
      .CTL_BITS ( CTL_BITS ),
      .A_DSP_W  ( 26 ),
      .B_DSP_W  ( 17 ),
      .GRID_BIT ( 64 ),
      .RAM_A_W  ( 10 ),
      .RAM_D_W  ( 32 )
    )
    accum_mult_mod (
      .i_clk ( i_clk ),
      .i_rst ( i_rst ),
      .i_mul ( mul_in_if[2]  ),
      .o_mul ( mul_out_if[2] ),
      .i_ram_d  ( mult_ram_d ),
      .i_ram_we ( mult_ram_we ),
      .i_ram_se ( mult_ram_se )
    );
  end
endgenerate

adder_pipe # (
  .P        ( P        ),
  .CTL_BITS ( CTL_BITS ),
  .LEVEL    ( 2        )
)
adder_pipe (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_add ( add_in_if  ),
  .o_add ( add_out_if )
);

subtractor_pipe # (
  .P        ( P        ),
  .CTL_BITS ( CTL_BITS ),
  .LEVEL    ( 2        )
)
subtractor_pipe (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_sub ( sub_in_if  ),
  .o_sub ( sub_out_if )
);

// Tasks for each of the different instructions

task get_next_inst();
  if(inst_ram_read == 0) begin
    inst_ram_sys_if.a <=  new_inst_pt_val_l ? new_inst_pt : inst_state == NOOP_WAIT ? inst_ram_sys_if.a : inst_ram_sys_if.a + 1;
    inst_ram_read[0] <= 1;
    if (new_inst_pt_val_l) new_inst_pt_val_l <= 0;
  end
  if (inst_ram_read[READ_CYCLE]) begin
    inst_state <= curr_inst.code;
    cnt <= 0;
  end
endtask

task task_sub_element();
  case(cnt)
    0: begin
      sub_out_if.rdy <= 1;
      data_ram_sys_if.a <= curr_inst.a;
      data_ram_read[0] <= 1;
      cnt <= 1;
    end
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        sub_in_if.dat[0 +: $bits(fe_t)] <= curr_data.dat;
        pt_l <= curr_data.pt;
        data_ram_sys_if.a <=  curr_inst.b;
        data_ram_read[0] <= 1;
        cnt <= 2;
      end
    end
    2: begin
      if (data_ram_read[READ_CYCLE]) begin
        sub_in_if.dat[$bits(fe_t) +: $bits(fe_t)] <= curr_data.dat;
        sub_in_if.val <= 1;
      end
      if (sub_out_if.val && sub_out_if.rdy) begin
        data_ram_sys_if.a <=  curr_inst.c;
        new_data.dat <= sub_out_if.dat;
        new_data.pt <= pt_l;
        data_ram_sys_if.we <= 1;
        cnt <= 5;
        if (pt_l == FE2 || pt_l == FP2_JB || pt_l == FP2_AF) begin
          // FE2 requires extra logic
          cnt <= 3;
        end
      end
    end
    3: begin
      if (!(|data_ram_read)) begin
        data_ram_sys_if.a <= curr_inst.a + 1;
        data_ram_read[0] <= 1;
      end
      if (data_ram_read[READ_CYCLE]) begin
        sub_in_if.dat[0 +: $bits(fe_t)] <= curr_data.dat;
        pt_l <= curr_data.pt;
        data_ram_sys_if.a <=  curr_inst.b + 1;
        data_ram_read[0] <= 1;
        cnt <= 4;
      end
    end
    4: begin
      if (data_ram_read[READ_CYCLE]) begin
        sub_in_if.dat[$bits(fe_t) +: $bits(fe_t)] <= curr_data.dat;
        sub_in_if.val <= 1;
      end
      if (sub_out_if.val && sub_out_if.rdy) begin
        data_ram_sys_if.a <=  curr_inst.c + 1;
        new_data.dat <= sub_out_if.dat;
        new_data.pt <= pt_l;
        data_ram_sys_if.we <= 1;
        cnt <= 5;
      end
    end
    5: begin
      get_next_inst();
    end
  endcase
endtask;

task task_add_element();
  case(cnt)
    0: begin
      add_out_if.rdy <= 1;
      data_ram_sys_if.a <= curr_inst.a;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        add_in_if.dat[0 +: $bits(fe_t)] <= curr_data.dat;
        pt_l <= curr_data.pt;
        data_ram_sys_if.a <=  curr_inst.b;
        data_ram_read[0] <= 1;
        cnt <= 2;
      end
    end
    2: begin
      if (data_ram_read[READ_CYCLE]) begin
        add_in_if.dat[$bits(fe_t) +: $bits(fe_t)] <= curr_data.dat;
        add_in_if.val <= 1;
      end
      if (add_out_if.val && add_out_if.rdy) begin
        data_ram_sys_if.a <=  curr_inst.c;
        new_data.dat <= add_out_if.dat;
        new_data.pt <= pt_l;
        data_ram_sys_if.we <= 1;
        cnt <= 5;
        if (pt_l == FE2 || pt_l == FP2_JB || pt_l == FP2_AF) begin
          // FE2 requires extra logic
          cnt <= 3;
        end
      end
    end
    3: begin
      if (!(|data_ram_read)) begin
        data_ram_sys_if.a <= curr_inst.a + 1;
        data_ram_read[0] <= 1;
      end
      if (data_ram_read[READ_CYCLE]) begin
        add_in_if.dat[0 +: $bits(fe_t)] <= curr_data.dat;
        pt_l <= curr_data.pt;
        data_ram_sys_if.a <=  curr_inst.b + 1;
        data_ram_read[0] <= 1;
        cnt <= 4;
      end
    end
    4: begin
      if (data_ram_read[READ_CYCLE]) begin
        add_in_if.dat[$bits(fe_t) +: $bits(fe_t)] <= curr_data.dat;
        add_in_if.val <= 1;
      end
      if (add_out_if.val && add_out_if.rdy) begin
        data_ram_sys_if.a <=  curr_inst.c + 1;
        new_data.dat <= add_out_if.dat;
        new_data.pt <= pt_l;
        data_ram_sys_if.we <= 1;
        cnt <= 5;
      end
    end
    5: begin
      get_next_inst();
    end
  endcase
endtask;

task task_mul_element();
  case(cnt)
    0: begin
      mul_out_if[1].rdy <= 1;
      data_ram_sys_if.a <= curr_inst.a;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        mul_in_if[1].dat[0 +: $bits(fe_t)] <= curr_data.dat;
        pt_l <= curr_data.pt;
        data_ram_sys_if.a <=  curr_inst.b;
        data_ram_read[0] <= 1;
        cnt <= 2;
        if (curr_data.pt == FE12) begin
          cnt <= 8;
          data_ram_sys_if.a <=  curr_inst.a;
        end
      end
    end
    2: begin
      if (data_ram_read[READ_CYCLE]) begin
        mul_in_if[1].dat[$bits(fe_t) +: $bits(fe_t)] <= curr_data.dat;
        mul_in_if[1].val <= 1;
        mul_in_if[1].ctl <= 0;
        if (pt_l == FE2 || pt_l == FP2_JB || pt_l == FP2_AF) begin
          data_ram_sys_if.a <= curr_inst.a + 1;
          data_ram_read[0] <= 1;
          mul_out_if[1].rdy <= 0;
          // FE2 requires extra logic
          cnt <= 3;
        end
      end
      if (mul_out_if[1].val && mul_out_if[1].rdy) begin
        data_ram_sys_if.a <=  curr_inst.c;
        new_data.dat <= mul_out_if[1].dat;
        new_data.pt <= pt_l;
        data_ram_sys_if.we <= 1;
        cnt <= 33;
      end
    end
    3: begin
      if (data_ram_read[READ_CYCLE]) begin
         mul_in_if[1].dat[0 +: $bits(fe_t)] <= curr_data.dat;
         mul_in_if[1].val <= 1;
         mul_in_if[1].ctl <= 3;
         data_ram_sys_if.a <= curr_inst.b + 1;
         data_ram_read[0] <= 1;
         cnt <= 4;
      end
    end
    4: begin
      if (data_ram_read[READ_CYCLE]) begin
         mul_in_if[1].dat[$bits(fe_t) +: $bits(fe_t)] <= curr_data.dat;
         mul_in_if[1].val <= 1;
         mul_in_if[1].ctl <= 1;
         data_ram_sys_if.a <= curr_inst.a;
         data_ram_read[0] <= 1;
         cnt <= 5;
      end
    end
    5: begin
      if (data_ram_read[READ_CYCLE]) begin
         mul_in_if[1].dat[0 +: $bits(fe_t)] <= curr_data.dat;
         mul_in_if[1].val <= 1;
         mul_in_if[1].ctl <= 2;
         mul_out_if[1].rdy <= 1;
         cnt <= 6;
      end
    end
    6: begin
      sub_out_if.rdy <= 1;
      if (mul_out_if[1].val && mul_out_if[1].rdy) begin
        case(mul_out_if[1].ctl)
          0: begin
            sub_in_if.dat[0 +: $bits(fe_t)] <= mul_out_if[1].dat;
          end
          1: begin
            sub_in_if.dat[$bits(fe_t) +: $bits(fe_t)] <= mul_out_if[1].dat;
            sub_in_if.val <= 1;
          end
          2: begin
            add_in_if.dat[0 +: $bits(fe_t)] <= mul_out_if[1].dat;
            add_in_if.val <= 1;
          end
          3: begin
            add_in_if.dat[$bits(fe_t) +: $bits(fe_t)] <= mul_out_if[1].dat;
          end
        endcase
      end

      if (sub_out_if.val && sub_out_if.rdy) begin
        new_data.dat <= sub_out_if.dat;
        new_data.pt <= pt_l;
        data_ram_sys_if.we <= 1;
        data_ram_sys_if.a <=  curr_inst.c;
        add_out_if.rdy <= 1;
      end
      if (add_out_if.val && add_out_if.rdy) begin
        new_data.dat <= add_out_if.dat;
        new_data.pt <= pt_l;
        data_ram_sys_if.we <= 1;
        data_ram_sys_if.a <=  curr_inst.c + 1;
        cnt <= 33;
      end
    end
    // FE12 multiplication
    8,9,10,11,12,13,14,15,16,17,18,19,
    20,21,22,23,24,25,26,27,28,29,30,31: begin
      mul_fe12_i_if.rdy <= 0;

      if (|data_ram_read[READ_CYCLE:1]== 0 && (~mul_fe12_o_if.val || (mul_fe12_o_if.val && mul_fe12_o_if.rdy))) begin
        if (data_ram_read[0]) begin
          data_ram_read[0] <= 1;
          data_ram_sys_if.a <= curr_inst.b + ((cnt-8)/2);
        end else begin
          data_ram_read[0] <= 1;
          data_ram_sys_if.a <= curr_inst.a + ((cnt-8)/2);
        end
      end

      if (data_ram_read[READ_CYCLE]) begin
       cnt <= cnt + 1;
        if (cnt % 2 == 1) begin
          mul_fe12_o_if.sop <= cnt == 9;
          mul_fe12_o_if.eop <= cnt == 31;
          mul_fe12_o_if.val <= 1;
          mul_fe12_o_if.dat[$bits(fe_t) +: $bits(fe_t)] <= curr_data.dat;
        end else begin
          mul_fe12_o_if.dat[0 +: $bits(fe_t)] <= curr_data.dat;
        end
      end
    end
    32: begin
      mul_fe12_i_if.rdy <= 1;
      if (mul_fe12_i_if.val && mul_fe12_i_if.rdy) begin
        if (mul_fe12_i_if.sop)
          data_ram_sys_if.a <= curr_inst.c;
        else
          data_ram_sys_if.a <= data_ram_sys_if.a + 1;
        data_ram_sys_if.we <= 1;
        new_data.dat <= mul_fe12_i_if.dat;
        new_data.pt <= pt_l;
        if (mul_fe12_i_if.eop) cnt <= cnt + 1;
      end
    end
    33: begin
      get_next_inst();
    end
  endcase
endtask;

task task_copy_reg();
  case(cnt)
    0: begin
      data_ram_sys_if.a <= curr_inst.a;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        data_ram_sys_if.a <=  curr_inst.b;
        new_data <= curr_data;
        data_ram_sys_if.we <= 1;
        cnt <= cnt + 1;
      end
    end
    2: begin
      get_next_inst();
    end
  endcase
endtask

task task_jump();
  case(cnt)
    0: begin
      inst_ram_sys_if.a <= curr_inst.a;
      inst_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    1: begin
      get_next_inst();
    end
  endcase
endtask

task task_jump_if_eq();
  case(cnt)
    0: begin
      data_ram_sys_if.a <= curr_inst.b;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        data_ram_sys_if.a <= curr_inst.c;
        new_data <= curr_data;
        data_ram_read[0] <= 1;
        cnt <= cnt + 1;
      end
    end
    2: begin
      if (data_ram_read[READ_CYCLE]) begin
        if (new_data.dat[63:0] == curr_data.dat[63:0])
          inst_ram_sys_if.a <= curr_inst.a;
        else
          inst_ram_sys_if.a <= inst_ram_sys_if.a + 1;
        inst_ram_read[0] <= 1;
        cnt <= cnt + 1;
      end
    end
    3: begin
      get_next_inst();
    end
  endcase
endtask

task task_jump_nonzero_sub();
  case(cnt)
    0: begin
      data_ram_sys_if.a <= curr_inst.b;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        if (curr_data.dat[63:0] != 0) begin
          inst_ram_sys_if.a <= curr_inst.a;
          new_data.pt <= curr_data.pt;
          new_data.dat[63:0] <= curr_data.dat[63:0] - 1;
          data_ram_sys_if.we <= 1;
        end else begin
          inst_ram_sys_if.a <= inst_ram_sys_if.a + 1;
        end
        inst_ram_read[0] <= 1;
        cnt <= cnt + 1;
      end
    end
    2: begin
      get_next_inst();
    end
  endcase
endtask

task task_inv_element();
  case(cnt)
    0: begin
      inv_fe_o_if.reset_source();
      inv_fe2_o_if.reset_source();
      inv_fe_i_if.rdy <= 0;
      inv_fe2_i_if.rdy <= 0;
      data_ram_sys_if.a <= curr_inst.a;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        // Depending on type of data
        if (curr_data.pt == FE) begin
          inv_fe_o_if.val <= 1;
          inv_fe_o_if.dat <= curr_data.dat;
          inv_fe_o_if.sop <= 1;
          inv_fe_o_if.eop <= 1;
          pt_l <= curr_data.pt;
        end else begin
          inv_fe2_o_if.dat <= curr_data.dat;
          data_ram_sys_if.a <= data_ram_sys_if.a + 1;
          data_ram_read[0] <= 1;
          inv_fe2_o_if.ctl <= 0;
          inv_fe2_o_if.val <= 1;
          inv_fe2_o_if.sop <= 1;
          inv_fe2_o_if.eop <= 0;
        end
      end
      if (inv_fe_o_if.val && inv_fe_o_if.rdy) cnt <= 2;
      if (inv_fe2_o_if.val && inv_fe2_o_if.rdy) cnt <= 3;
    end
    2: begin
      inv_fe_i_if.rdy <= 1;
      // FE element
      if (inv_fe_i_if.val && inv_fe_i_if.rdy) begin
        data_ram_sys_if.a <= curr_inst.b;
        new_data.pt <= pt_l;
        new_data.dat <= inv_fe_i_if.dat;
        data_ram_sys_if.we <= 1;
        cnt <= 5;
      end
    end
    //FE2 element
    3: begin
      if (data_ram_read[READ_CYCLE]) begin
        inv_fe2_o_if.val <= 1;
        inv_fe2_o_if.dat <= curr_data.dat;
        inv_fe2_o_if.sop <= 0;
        inv_fe2_o_if.eop <= 1;
        pt_l <= curr_data.pt;
      end
      if (inv_fe2_o_if.eop && inv_fe2_o_if.val && inv_fe2_o_if.rdy) cnt <= 4;
    end
    4: begin
      inv_fe2_i_if.rdy <= 1;
      if (inv_fe2_i_if.val && inv_fe2_i_if.rdy) begin
        data_ram_sys_if.a <= inv_fe2_i_if.sop ? curr_inst.b : data_ram_sys_if.a + 1;
        new_data.pt <= pt_l;
        new_data.dat <= inv_fe2_i_if.dat;
        data_ram_sys_if.we <= 1;
        if (inv_fe2_i_if.eop) cnt <= 5;
      end
    end
    5: begin
      get_next_inst();
    end
  endcase
endtask

task task_point_mult();
  pair_mode <= 1;
  case(cnt) inside
    0: begin
      data_ram_sys_if.a <= curr_inst.a;
      if (|data_ram_read == 0) data_ram_read[0] <= 1;
      if (data_ram_read[READ_CYCLE]) begin
        cnt <= cnt + 1;
        pair_key <= curr_data.dat;
        data_ram_sys_if.a <= curr_inst.b;
        data_ram_read[0] <= 1;
      end
    end
    1,2,3,4: begin
      if (|data_ram_read == 0 && (~pair_i_af_if.val || (pair_i_af_if.val && pair_i_af_if.rdy))) begin
        data_ram_read[0] <= 1;
        data_ram_sys_if.a <= data_ram_sys_if.a + 1;
        if (curr_data.pt == FP_AF && cnt % 2 == 0) data_ram_sys_if.a <= data_ram_sys_if.a;
      end
      if (data_ram_read[READ_CYCLE]) begin
        pair_i_af_if.val <= 1;
        pair_i_af_if.sop <= cnt == 1;
        pair_i_af_if.eop <= cnt == 4;
        pair_i_af_if.dat <= (curr_data.pt == FP_AF && cnt % 2 == 0) ? 0 : curr_data.dat;
        cnt <= cnt + 1;
        if (cnt == 1) pt_l <= curr_data.pt;
        if (cnt == 4) begin
          data_ram_sys_if.a <= curr_inst.c;
        end
      end
    end
    // Wait for result
    5,6,7,8,9,10: begin
      mult_pt_if.rdy <= 1;
      if (mult_pt_if.val) begin
         new_data.pt <= pt_l == FP_AF ? FP_JB : FP2_JB;
         new_data.dat <= mult_pt_if.dat;
         data_ram_sys_if.we <= 1;
         if (cnt > 5) data_ram_sys_if.a <= data_ram_sys_if.a + 1;
         if (pt_l == FP_AF && cnt % 2 == 0) begin // Even elements will be 0 for FP points
           data_ram_sys_if.a <= data_ram_sys_if.a;
           data_ram_sys_if.we <= 0;
         end
         cnt <= cnt + 1;
      end
    end
    11: begin
      pair_mode <= 0;
      get_next_inst();
    end
  endcase
endtask

task task_pairing();
  case(cnt) inside
    0: begin
      data_ram_sys_if.a <= curr_inst.a;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    // Load G1 affine point
    1,2: begin
      if (data_ram_read[READ_CYCLE]) begin
        data_ram_sys_if.a <= data_ram_sys_if.a + 1;
        data_ram_read[0] <= 1;
        pair_i_af_if.dat <= curr_data.dat;
        pair_i_af_if.val <= 1;
        pair_i_af_if.sop <= cnt == 1;
        pair_i_af_if.eop <= cnt == 2;
        cnt <= cnt + 1;
        if (cnt == 2) begin
          data_ram_sys_if.a <= curr_inst.b;
        end
      end
    end
    // Load G2 affine point
    3,4,5,6: begin
      if (data_ram_read[READ_CYCLE]) begin
        data_ram_sys_if.a <= data_ram_sys_if.a + 1;
        data_ram_read[0] <= 1;
        pair_i_af_if.dat <= curr_data.dat;
        pair_i_af_if.val <= 1;
        pair_i_af_if.sop <= cnt == 3;
        pair_i_af_if.eop <= cnt == 6;
        cnt <= cnt + 1;
        if (cnt == 6) begin
          data_ram_sys_if.a <= curr_inst.c;
          pair_o_res_if.rdy <= 1;
          mult_pt_if.rdy <= 1;
        end
      end
    end
    // Wait for result
    7: begin
      if (pair_o_res_if.val || mult_pt_if.val) begin
         new_data.pt <= FE12;
         new_data.dat <= pair_o_res_if.val ? pair_o_res_if.dat : mult_pt_if.dat;
         data_ram_sys_if.we <= 1;
         if ((pair_o_res_if.val && ~pair_o_res_if.sop) ||
              (mult_pt_if.val && ~mult_pt_if.sop))
           data_ram_sys_if.a <= data_ram_sys_if.a + 1;
         if (pair_o_res_if.eop || mult_pt_if.eop) begin
           mult_pt_if.rdy <= 0;
           pair_o_res_if.rdy <= 0;
           cnt <= cnt + 1;
         end
      end
    end
    8: begin
      get_next_inst();
    end
  endcase
endtask

task task_final_exp();
  pair_mode <= 3;
  case(cnt) inside
    0: begin
      data_ram_sys_if.a <= curr_inst.a;
      data_ram_read[0] <= 1;
      cnt <= cnt + 1;
    end
    // Load FE12
    1,2,3,4,5,6,7,8,9,10,11,12: begin
      if (data_ram_read[READ_CYCLE]) begin
        data_ram_sys_if.a <= data_ram_sys_if.a + 1;
        data_ram_read[0] <= 1;
        pair_i_af_if.dat <= curr_data.dat;
        pair_i_af_if.val <= 1;
        pair_i_af_if.sop <= cnt == 1;
        pair_i_af_if.eop <= cnt == 12;
        cnt <= cnt + 1;
        if (cnt == 12) begin
          data_ram_sys_if.a <= curr_inst.b;
        end
      end
    end
    // Wait for result
    13: begin
      pair_o_res_if.rdy <= 1;
      if (pair_o_res_if.val && pair_o_res_if.rdy) begin
         new_data.pt <= FE12;
         new_data.dat <= pair_o_res_if.dat;
         data_ram_sys_if.we <= 1;
         if (~pair_o_res_if.sop) data_ram_sys_if.a <= data_ram_sys_if.a + 1;
         if (pair_o_res_if.eop) begin
           cnt <= cnt + 1;
           pair_o_res_if.rdy <= 0;
         end
      end
    end
    14: begin
      get_next_inst();
    end
  endcase
endtask

task task_send_interrupt();
  case(cnt) inside
    // Load the data
    0: begin
      interrupt_in_if.eop <= 0;
      data_ram_sys_if.a <= curr_inst.a;
      if (interrupt_state != WAIT_FIFO) begin
        // Wait here
      end else begin
        data_ram_read[0] <= 1;
        cnt <= cnt + 1;
      end
    end
    // Check what type of data it is and write index fifo
    1: begin
      if (data_ram_read[READ_CYCLE]) begin
        pt_size <= get_point_type_size(curr_data.pt);
        idx_in_if.val <= 1;
        idx_in_if.dat <= {curr_data.pt, curr_inst.b};
      end
      if (idx_in_if.val && idx_in_if.rdy) begin
        cnt <= cnt + 1;
        data_ram_read[0] <= 1;
        data_ram_sys_if.a <= curr_inst.a;
      end
    end
    // Write the slot fifo
    2: begin

      if (~interrupt_in_if.val) begin
        interrupt_in_if.dat <= curr_data.dat;
        interrupt_in_if.val <= data_ram_read[READ_CYCLE];
        interrupt_in_if.eop <= pt_size == 1;
      end

      if (interrupt_in_if.val && interrupt_in_if.rdy) begin
        pt_size <= pt_size - 1;
        interrupt_in_if.val <= 0;
        data_ram_sys_if.a <= data_ram_sys_if.a + 1;
        data_ram_read[0] <= 1;
        if (pt_size == 1) cnt <= cnt + 1;
      end

    end
    3: begin
      get_next_inst();
    end
  endcase
endtask

// Use this FIFO - width converter to send out interrupt messages
axis_dwidth_converter_48_to_8 interrupt_converter_48_to_8 (
  .aclk   ( i_clk  ),                    // input wire aclk
  .aresetn( ~i_rst ),              // input wire aresetn
  .s_axis_tvalid( interrupt_in_if.val  ),  // input wire s_axis_tvalid
  .s_axis_tready( interrupt_in_if.rdy  ),  // output wire s_axis_tready
  .s_axis_tdata ( interrupt_in_if.dat  ),    // input wire [383 : 0] s_axis_tdata
  .s_axis_tlast ( interrupt_in_if.eop  ),    // input wire s_axis_tlast
  .m_axis_tvalid( interrupt_out_if.val ),  // output wire m_axis_tvalid
  .m_axis_tready( interrupt_out_if.rdy ),  // input wire m_axis_tready
  .m_axis_tdata ( interrupt_out_if.dat ),    // output wire [63 : 0] m_axis_tdata
  .m_axis_tlast ( interrupt_out_if.eop )    // output wire m_axis_tlast
);

// This just stores the index + length of interrupt packet
axi_stream_fifo #(
  .SIZE     ( 4  ),
  .DAT_BITS ( 16 + 3 )
)
interrupt_index_fifo (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( idx_in_if ),
  .o_axi ( idx_out_if ),
  .o_full(),
  .o_emp ()
);

// Process for reading from FIFO and sending interrupt
always_comb begin
  interrupt_out_if.rdy = (interrupt_state == SEND_DATA) && (~tx_if.val || (tx_if.val && tx_if.rdy));
end


always_ff @ (posedge i_clk) begin
  if (i_rst) begin
    interrupt_rpl <= 0;
    interrupt_state <= WAIT_FIFO;
    interrupt_hdr_byt <= 0;
    idx_out_if.rdy <= 0;
    tx_if.reset_source();
  end else begin
    case (interrupt_state)
      WAIT_FIFO: begin
        idx_out_if.rdy <= 1;
        if (idx_out_if.val) begin
          idx_out_if.rdy <= 0;
          interrupt_state <= SEND_HDR;
          interrupt_rpl <= bls12_381_interrupt_rpl(idx_out_if.dat[0 +: 16], (point_type_t)'(idx_out_if.dat[16 +: 3]));
          interrupt_hdr_byt <= $bits(bls12_381_interrupt_rpl_t)/8;
        end
      end
      // Header needs to be aligned to AXI_STREAM_BYTS
      SEND_HDR: begin
        if (~tx_if.val || (tx_if.val && tx_if.rdy)) begin
          tx_if.sop <= interrupt_hdr_byt == $bits(bls12_381_interrupt_rpl_t)/8;
          tx_if.val <= 1;
          tx_if.dat <= interrupt_rpl;
          interrupt_rpl <= interrupt_rpl >> AXI_STREAM_BYTS*8;
          interrupt_hdr_byt <= interrupt_hdr_byt - 8;
          if (interrupt_hdr_byt <= 8) interrupt_state <= SEND_DATA;
        end
      end
      SEND_DATA: begin
        if (~tx_if.val || (tx_if.val && tx_if.rdy)) begin
          tx_if.sop <= 0;
          tx_if.val <= interrupt_out_if.val;
          tx_if.dat <= interrupt_out_if.dat;
          tx_if.eop <= interrupt_out_if.eop;
          if (tx_if.eop) begin
            tx_if.reset_source();
            interrupt_state <= WAIT_FIFO;
          end
        end
      end
    endcase
  end
end
endmodule