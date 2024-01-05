/*
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
`timescale 1ps/1ps

module bls12_381_pairing_tb ();

import common_pkg::*;
import bls12_381_pkg::*;

parameter type FE_TYPE   = bls12_381_pkg::fe_t;
parameter type FE2_TYPE  = bls12_381_pkg::fe2_t;
parameter type FE6_TYPE  = bls12_381_pkg::fe6_t;
parameter type FE12_TYPE = bls12_381_pkg::fe12_t;
parameter P              = bls12_381_pkg::P;

af_point_t G1 = {Gy, Gx};
fp2_af_point_t G2 = {G2y, G2x};

localparam CTL_BITS = 128;

localparam CLK_PERIOD = 100;

logic clk, rst;

initial begin
  rst = 0;
  repeat(2) #(20*CLK_PERIOD) rst = ~rst;
end

initial begin
  clk = 0;
  forever #(CLK_PERIOD/2) clk = ~clk;
end

logic [1:0] mode;
if_axi_stream #(.DAT_BYTS(($bits(FE_TYPE)+7)/8), .CTL_BITS(CTL_BITS)) out_if(clk);

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_fe_o_if(clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_fe_i_if(clk);

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_fe12_o_if(clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_fe12_i_if(clk);

if_axi_stream #(.DAT_BYTS(($bits(FE_TYPE)+7)/8), .CTL_BITS(CTL_BITS))   o_p_jb_if(clk);

if_axi_stream #(.DAT_BYTS(($bits(FE_TYPE)+7)/8), .CTL_BITS(CTL_BITS)) pair_af_if(clk);

if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) inv_fe_o_if(clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) inv_fe_i_if(clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) inv_fe2_o_if(clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) inv_fe2_i_if(clk);

accum_mult_mod #(
  .DAT_BITS ( $bits(FE_TYPE) ),
  .MODULUS  ( P ),
  .CTL_BITS ( CTL_BITS ),
  .A_DSP_W  ( 26 ),
  .B_DSP_W  ( 17 ),
  .GRID_BIT ( 64 ),
  .RAM_A_W  ( 8  ),
  .RAM_D_W  ( 32 )
)
accum_mult_mod (
  .i_clk ( clk ),
  .i_rst ( rst ),
  .i_mul ( mul_fe_o_if  ),
  .o_mul ( mul_fe_i_if ),
  .i_ram_d ( '0 ),
  .i_ram_we ( '0 ),
  .i_ram_se ( '0 )
);

bls12_381_pairing_wrapper #(
  .CTL_BITS    ( CTL_BITS ),
  .OVR_WRT_BIT ( 0        )
)
bls12_381_pairing_wrapper (
  .i_clk ( clk ),
  .i_rst ( rst ),
  .i_pair_af_if ( pair_af_if ),
  .i_mode    ( mode  ),
  .i_key     ( 381'd0 ),
  .o_p_jb_if ( o_p_jb_if ),
  .o_fe12_if ( out_if ),
  .o_mul_fe_if ( mul_fe_o_if ),
  .i_mul_fe_if ( mul_fe_i_if ),
  .o_mul_fe12_if ( mul_fe12_i_if ),
  .i_mul_fe12_if ( mul_fe12_o_if ),  
  .o_inv_fe2_if ( inv_fe2_i_if  ),
  .i_inv_fe2_if ( inv_fe2_o_if  ),
  .o_inv_fe_if  ( inv_fe_i_if   ),
  .i_inv_fe_if  ( inv_fe_o_if   )
);

// This just tests our software model vs a known good result
task test0();
  af_point_t P;
  fp2_af_point_t Q;
  fe12_t f, f_exp;

  $display("Running test0 ...");
  f = FE12_zero;
  f_exp =  {381'h0f41e58663bf08cf068672cbd01a7ec73baca4d72ca93544deff686bfd6df543d48eaa24afe47e1efde449383b676631,
            381'h04c581234d086a9902249b64728ffd21a189e87935a954051c7cdba7b3872629a4fafc05066245cb9108f0242d0fe3ef,
            381'h03350f55a7aefcd3c31b4fcb6ce5771cc6a0e9786ab5973320c806ad360829107ba810c5a09ffdd9be2291a0c25a99a2,
            381'h11b8b424cd48bf38fcef68083b0b0ec5c81a93b330ee1a677d0d15ff7b984e8978ef48881e32fac91b93b47333e2ba57,
            381'h06fba23eb7c5af0d9f80940ca771b6ffd5857baaf222eb95a7d2809d61bfe02e1bfd1b68ff02f0b8102ae1c2d5d5ab1a,
            381'h19f26337d205fb469cd6bd15c3d5a04dc88784fbb3d0b2dbdea54d43b2b73f2cbb12d58386a8703e0f948226e47ee89d,
            381'h018107154f25a764bd3c79937a45b84546da634b8f6be14a8061e55cceba478b23f7dacaa35c8ca78beae9624045b4b6,
            381'h01b2f522473d171391125ba84dc4007cfbf2f8da752f7c74185203fcca589ac719c34dffbbaad8431dad1c1fb597aaa5,
            381'h193502b86edb8857c273fa075a50512937e0794e1e65a7617c90d8bd66065b1fffe51d7a579973b1315021ec3c19934f,
            381'h1368bb445c7c2d209703f239689ce34c0378a68e72a6b3b216da0e22a5031b54ddff57309396b38c881c4c849ec23e87,
            381'h089a1c5b46e5110b86750ec6a532348868a84045483c92b7af5af689452eafabf1a8943e50439f1d59882a98eaa0170f,
            381'h1250ebd871fc0a92a7b2d83168d0d727272d441befa15c503dd8e90ce98db3e7b6d194f60839c508a84305aaca1789b6};

  ate_pairing(G1, G2, f);
  $display("After ate pairing:");
  print_fe12(f);
  assert(f == f_exp) else $fatal(1, "Test0 Miller loop did not match known good result");
  $display("test0 PASSED");

endtask

task test1(input af_point_t G1_p, fp2_af_point_t G2_p);
begin
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] dat_in0, dat_in1, get_dat;
  integer start_time, finish_time;
  FE12_TYPE  f_out, f_exp;
  $display("Running test1 ...");
  
  dat_in0 = 0;
  dat_in0[0*384 +: $bits(FE_TYPE)] = G1_p.x;
  dat_in0[1*384 +: $bits(FE_TYPE)] = G1_p.y;
  
  dat_in1 = 0;
  dat_in1[0*384 +: $bits(FE_TYPE)] = G2_p.x[0];
  dat_in1[1*384 +: $bits(FE_TYPE)] = G2_p.x[1];
  dat_in1[2*384 +: $bits(FE_TYPE)] = G2_p.y[0];
  dat_in1[3*384 +: $bits(FE_TYPE)] = G2_p.y[1];
  mode = 0;

  ate_pairing(G1_p, G2_p, f_exp);

  start_time = $time;
  fork
    begin
      pair_af_if.put_stream(dat_in0, (($bits(af_point_t))+7)/8);
      pair_af_if.put_stream(dat_in1, (($bits(fp2_af_point_t))+7)/8);
    end
    out_if.get_stream(get_dat, get_len);
  join
  finish_time = $time;

  for (int i = 0; i < 2; i++)
    for (int j = 0; j < 3; j++)
      for (int k = 0; k < 2; k++)
        f_out[i][j][k] = get_dat[(i*6+j*2+k)*384 +: $bits(FE_TYPE)];



  $display("Expected:");
  print_fe12(f_exp);
  $display("Was:");
  print_fe12(f_out);

  $display("test1 finished in %d clocks", (finish_time-start_time)/(CLK_PERIOD));

  if (f_exp != f_out) begin
    $fatal(1, "%m %t ERROR: output was wrong", $time);
  end

  $display("test1 PASSED");
end
endtask;

task test_linear();
begin
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] dat_in0, dat_in1, get_dat;
  integer start_time, finish_time, n;
  FE12_TYPE  f_out, f_exp0, f_exp1;
  af_point_t G1_a, G1_a_n;
  fp2_af_point_t G1_j, G2_a_n;
  fp2_af_point_t G2_a;
  fp2_jb_point_t G2_j;

  $display("Running test_linear ...");

  G1_a = {Gy, Gx};
  G2_a = {G2y, G2x};
  G1_j = {381'd1, Gy, Gx};
  G2_j = {381'd1, G2y, G2x};
  n = 2;
  G1_a_n = to_affine(point_mult(n, G1_j));
  G2_a_n = fp2_to_affine(fp2_point_mult(n, G2_j));

  ate_pairing(G1_a, G2_a_n, f_exp0);
  ate_pairing(G1_a_n, G2_a, f_exp1);

  assert(f_exp0 == f_exp1) else $fatal(1, "Error in test_linear with sw model");

  dat_in0 = 0;
  dat_in0[0*384 +: $bits(FE_TYPE)] = G1_a_n.x;
  dat_in0[1*384 +: $bits(FE_TYPE)] = G1_a_n.y;
  
  dat_in1 = 0;
  dat_in1[0*384 +: $bits(FE_TYPE)] = G2_a.x[0];
  dat_in1[1*384 +: $bits(FE_TYPE)] = G2_a.x[1];
  dat_in1[2*384 +: $bits(FE_TYPE)] = G2_a.y[0];
  dat_in1[3*384 +: $bits(FE_TYPE)] = G2_a.y[1];
  mode = 0;
  
  start_time = $time;
  fork
    begin
      pair_af_if.put_stream(dat_in0, (($bits(af_point_t))+7)/8);
      pair_af_if.put_stream(dat_in1, (($bits(fp2_af_point_t))+7)/8);
    end
    out_if.get_stream(get_dat, get_len);
  join
  finish_time = $time;

  for (int i = 0; i < 2; i++)
    for (int j = 0; j < 3; j++)
      for (int k = 0; k < 2; k++)
        f_out[i][j][k] = get_dat[(i*6+j*2+k)*384 +: $bits(FE_TYPE)];

  $display("Expected:");
  print_fe12(f_exp1);
  $display("Was:");
  print_fe12(f_out);

  $display("test_linear finished in %d clocks", (finish_time-start_time)/(CLK_PERIOD));

  if (f_exp1 != f_out) begin
    $fatal(1, "%m %t ERROR: output was wrong", $time);
  end

  $display("test_linear PASSED");
end
endtask;

task test_miller_only();
begin
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] dat_in0, dat_in1, get_dat;
  integer start_time, finish_time, n;
  FE12_TYPE  f_out, f_exp0;
  af_point_t G1_a;
  fp2_af_point_t G2_a;

  $display("Running test_miller_only ...");

  G1_a = {Gy, Gx};
  G2_a = {G2y, G2x};
  miller_loop(G1_a, G2_a, f_exp0);

  dat_in0 = 0;
  dat_in0[0*384 +: $bits(FE_TYPE)] = G1_a.x;
  dat_in0[1*384 +: $bits(FE_TYPE)] = G1_a.y;
  
  dat_in1 = 0;
  dat_in1[0*384 +: $bits(FE_TYPE)] = G2_a.x[0];
  dat_in1[1*384 +: $bits(FE_TYPE)] = G2_a.x[1];
  dat_in1[2*384 +: $bits(FE_TYPE)] = G2_a.y[0];
  dat_in1[3*384 +: $bits(FE_TYPE)] = G2_a.y[1];
  mode = 2;
  
  start_time = $time;
  fork
    begin
      pair_af_if.put_stream(dat_in0, (($bits(af_point_t))+7)/8);
      pair_af_if.put_stream(dat_in1, (($bits(fp2_af_point_t))+7)/8);
    end
    o_p_jb_if.get_stream(get_dat, get_len);
  join
  finish_time = $time;

  for (int i = 0; i < 2; i++)
    for (int j = 0; j < 3; j++)
      for (int k = 0; k < 2; k++)
        f_out[i][j][k] = get_dat[(i*6+j*2+k)*384 +: $bits(FE_TYPE)];

  $display("Expected:");
  print_fe12(f_exp0);
  $display("Was:");
  print_fe12(f_out);

  $display("test_miller_only finished in %d clocks", (finish_time-start_time)/(CLK_PERIOD));

  if (f_exp0 != f_out) begin
    $fatal(1, "%m %t ERROR: output was wrong", $time);
  end

  $display("test_miller_only PASSED");
end
endtask;

initial begin
  mul_fe12_o_if.reset_source();
  mul_fe12_i_if.rdy = 0;
  o_p_jb_if.rdy = 0;
  pair_af_if.reset_source();
  inv_fe2_o_if.reset_source();
  inv_fe_o_if.reset_source();
  inv_fe2_i_if.rdy = 0;
  inv_fe_i_if.rdy = 0;
  out_if.rdy = 0;
  mode = 0;
  #100ns;

  test0();       // Test SW model
  test1(G1, G2); // Pairing of generators
  test_linear(); // test linear properties e(n*G1,G2) == e(G1, n*G2), ...
  test_miller_only();

  #1us $finish();
end

endmodule