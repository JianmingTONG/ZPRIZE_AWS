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

module bls12_381_top_tb ();

import common_pkg::*;
import bls12_381_pkg::*;
import zcash_fpga_pkg::bls12_381_interrupt_rpl_t;
import zcash_fpga_pkg::BLS12_381_INTERRUPT_RPL;
import zcash_fpga_pkg::BLS12_381_USE_KARATSUBA;

localparam LOAD_RAM = "NO"; // This loads the accum_mult_mod RAM, not needed as we use init files

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

if_axi_stream #(.DAT_BYTS(8)) out_if(clk);

if_axi_lite #(.A_BITS(32)) axi_lite_if(clk);


bls12_381_top # (
  .USE_KARATSUBA(BLS12_381_USE_KARATSUBA)
)
bls12_381_top (
  .i_clk ( clk ),
  .i_rst ( rst ),
  // Only tx interface is used to send messages to SW on a SEND-INTERRUPT instruction
  .tx_if ( out_if ),
  // User access to the instruction and register RAM
  .axi_lite_if ( axi_lite_if )
);

task test_inv_element();
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] get_dat;
  inst_t inst;
  logic failed;
  data_t data;
  logic [31:0] rdata;
  fe_t in, exp, out;
  fe2_t in2, exp2, out2;
  bls12_381_interrupt_rpl_t interrupt_rpl;

  failed = 0;
  in = (1 + random_vector(384/8)) % P;
  exp =  fe_inv(in);
  $display("Running test_inv_element...");
  $display("First trying FE element ...");
  // See what current instruction pointer is
  axi_lite_if.peek(.addr(32'h10), .data(rdata));
  $display("Current pointer at %d", rdata);

  data = '{dat:in, pt:FE};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 5*64), .len(48));  // Scalar to multiply by goes in data slot 1

  inst = '{code:COPY_REG, a:16'd6, b:16'd8, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+1)*8), .len(8));

  inst = '{code:SEND_INTERRUPT, a:16'd8, b:16'h1234, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+2)*8), .len(8));

  // Make sure instructions after are NOOP
  inst = '{code:NOOP_WAIT, a:16'd0, b:16'h0, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START+ (rdata+3)*8), .len(8));
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START+ (rdata+4)*8), .len(8));

  // Write to current slot to start
  inst = '{code:INV_ELEMENT, a:16'd5, b:16'd6, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata)*8), .len(8));

  fork
    begin
      out_if.get_stream(get_dat, get_len, 0);
      interrupt_rpl = get_dat;

      assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
      assert(interrupt_rpl.index == 16'h1234) else $fatal(1, "ERROR: Received wrong index value in message");
      assert(interrupt_rpl.data_type == FE) else $fatal(1, "ERROR: Received wrong data type value in message");

      get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);
      out = get_dat;

      if (out == exp) begin
        $display("INFO: Output element matched expected:");
        $display("0x%x", out);
      end else begin
        $display("ERROR: Output element did NOT match expected:");
        $display("0x%x", out);
        $display("Expected:");
        $display("0x%x", exp);
        failed = 1;
      end
    end
    begin
      repeat(100000) @(posedge out_if.i_clk);
      $fatal("ERROR: Timeout while waiting for result");
    end
  join_any
  disable fork;

  axi_lite_if.peek(.addr(32'h14), .data(rdata));
  $display("INFO: Last cycle count was %d", rdata);

  if(failed)
   $fatal(1, "ERROR: test_inv_element on FE element FAILED");


  // Try a FE2 elelemnt
  in2[0] = random_vector(384/8) % P;
  in2[1] = random_vector(384/8) % P;

  exp2 =  fe2_inv(in2);
  $display("Trying FE2 element ...");

  // See what current instruction pointer is
  axi_lite_if.peek(.addr(32'h10), .data(rdata));

  data = '{dat:in2[0], pt:FE2};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 5*64), .len(48));
  data = '{dat:in2[1], pt:FE2};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 6*64), .len(48));


  inst = '{code:SEND_INTERRUPT, a:16'd9, b:16'h5678, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+1)*8), .len(8));

  // Write to current slot to start
  inst = '{code:INV_ELEMENT, a:16'd5, b:16'd9, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata)*8), .len(8));

  fork
    begin
      out_if.get_stream(get_dat, get_len, 0);
      interrupt_rpl = get_dat;

      assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
      assert(interrupt_rpl.index == 16'h5678) else $fatal(1, "ERROR: Received wrong index value in message");
      assert(interrupt_rpl.data_type == FE2) else $fatal(1, "ERROR: Received wrong data type value in message");

      get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);
      for (int i = 0; i < 2; i++)
        out2[i] = get_dat[i*(48*8) +: 381];

      if (out2 == exp2) begin
        $display("INFO: Output element matched expected:");
        $display("0x%x", out2);
      end else begin
        $display("ERROR: Output element did NOT match expected:");
        $display("0x%x 0x%x", out2[1], out2[0]);
        $display("Expected:");
        $display("0x%x 0x%x", exp2[1], exp2[0]);
        failed = 1;
      end
    end
    begin
      repeat(100000) @(posedge out_if.i_clk);
      $fatal("ERROR: Timeout while waiting for result");
    end
  join_any
  disable fork;

  axi_lite_if.peek(.addr(32'h14), .data(rdata));
  $display("INFO: Last cycle count was %d", rdata);

  if(failed)
    $fatal(1, "ERROR: test_inv_element on FE2 element FAILED");

  $display("INFO: test_inv_element PASSED both FE and FE2 elements!");

endtask;

task test_mul_add_sub_element();
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] get_dat;
  inst_t inst;
  logic failed;
  data_t data;
  logic [31:0] rdata;
  fe_t in_a, in_b, exp, out;
  fe2_t in2_a, in2_b, exp2, out2;
  bls12_381_interrupt_rpl_t interrupt_rpl;

  failed = 0;
  in_a = random_vector(384/8) % P;
  in_b = random_vector(384/8) % P;
  exp =  fe_sub(fe_add(fe_mul(in_a, in_b), fe_mul(in_a, in_b)), fe_mul(in_a, in_b));
  $display("Running test_mul_add_sub_element...");
  $display("First trying FE element ...");
  //Reset the RAM
  axi_lite_if.poke(.addr(32'h0), .data(2'b11));

  axi_lite_if.poke(.addr(32'h10), .data(0));

  data = '{dat:in_a, pt:FE};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 0*64), .len(48));  // Scalar to multiply by goes in data slot 1
  data = '{dat:in_b, pt:FE};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 11*64), .len(48));  // Scalar to multiply by goes in data slot 1

  inst = '{code:SEND_INTERRUPT, a:16'd6, b:16'h1111, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 3*8), .len(8));

  inst = '{code:ADD_ELEMENT, a:16'd2, b:16'd2, c:16'd4};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 1*8), .len(8));

  inst = '{code:SUB_ELEMENT, a:16'd4, b:16'd2, c:16'd6};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 2*8), .len(8));

  inst = '{code:MUL_ELEMENT, a:16'd0, b:16'd11, c:16'd2};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 0*8), .len(8));


  fork
    begin
      out_if.get_stream(get_dat, get_len, 0);
      interrupt_rpl = get_dat;

      assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
      assert(interrupt_rpl.index == 16'h1111) else $fatal(1, "ERROR: Received wrong index value in message");
      assert(interrupt_rpl.data_type == FE) else $fatal(1, "ERROR: Received wrong data type value in message");

      get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);
      out = get_dat;

      if (out == exp) begin
        $display("INFO: Output element matched expected:");
        $display("0x%x", out);
      end else begin
        $display("ERROR: Output element did NOT match expected:");
        $display("0x%x", out);
        $display("Expected:");
        $display("0x%x", exp);
        failed = 1;
      end
    end
    begin
      repeat(100000) @(posedge out_if.i_clk);
      $fatal("ERROR: Timeout while waiting for result");
    end
  join_any
  disable fork;

  axi_lite_if.peek(.addr(32'h14), .data(rdata));
  $display("INFO: Last cycle count was %d", rdata);

  if(failed)
   $fatal(1, "ERROR: test_mul_element on FE element FAILED");


  // Try a FE2 elelemnt
  in2_a[0] = random_vector(384/8) % P;
  in2_a[1] = random_vector(384/8) % P;
  in2_b[0] = random_vector(384/8) % P;
  in2_b[1] = random_vector(384/8) % P;

  exp2 =  fe2_sub(fe2_add(fe2_mul(in2_a, in2_b), fe2_mul(in2_a, in2_b)), fe2_mul(in2_a, in2_b));
  $display("Trying FE2 element ...");

  // See what current instruction pointer is
  axi_lite_if.peek(.addr(32'h10), .data(rdata));

  data = '{dat:in2_a[0], pt:FE2};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 0*64), .len(48));
  data = '{dat:in2_a[1], pt:FE2};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 1*64), .len(48));

  data = '{dat:in2_b[0], pt:FE2};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 11*64), .len(48));
  data = '{dat:in2_b[1], pt:FE2};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 12*64), .len(48));

  // Set instruction pointer back to 0 to start
  axi_lite_if.poke(.addr(32'h10), .data(0));

  fork
    begin
      out_if.get_stream(get_dat, get_len, 0);
      interrupt_rpl = get_dat;

      assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
      assert(interrupt_rpl.index == 16'h1111) else $fatal(1, "ERROR: Received wrong index value in message");
      assert(interrupt_rpl.data_type == FE2) else $fatal(1, "ERROR: Received wrong data type value in message");

      get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);
      for (int i = 0; i < 2; i++)
        out2[i] = get_dat[i*(48*8) +: 381];

      if (out2 == exp2) begin
        $display("INFO: Output element matched expected:");
        $display("0x%x", out2);
      end else begin
        $display("ERROR: Output element did NOT match expected:");
        $display("0x%x 0x%x", out2[1], out2[0]);
        $display("Expected:");
        $display("0x%x 0x%x", exp2[1], exp2[0]);
        failed = 1;
      end
    end
    begin
      repeat(100000) @(posedge out_if.i_clk);
      $fatal("ERROR: Timeout while waiting for result");
    end
  join_any
  disable fork;

  axi_lite_if.peek(.addr(32'h14), .data(rdata));
  $display("INFO: Last cycle count was %d", rdata);

  if(failed)
    $fatal(1, "ERROR: test_mul_add_sub_element on FE2 element FAILED");

  $display("INFO: test_mul_add_sub_element PASSED both FE and FE2 elements!");

endtask;

task test_point_mult();
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] get_dat;
  inst_t inst;
  logic failed;
  data_t data;
  logic [31:0] rdata;
  fe_t in_k;
  fp2_jb_point_t p2_in, p2_out, p2_exp;
  jb_point_t p_in, p_out, p_exp;
  bls12_381_interrupt_rpl_t interrupt_rpl;

  failed = 0;

  $display("Running test_point_mult...");
  //Reset the RAM
  axi_lite_if.poke(.addr(32'h0), .data(2'b11));
  axi_lite_if.poke(.addr(32'h10), .data(0));

  for (int i = 0; i < 2; i++) begin
    in_k = random_vector(384/8) % P;
    p_in = 0;
    p2_in = 0;
    $display("INFO: Case %d", i);

    inst = '{code:SEND_INTERRUPT, a:16'd10, b:i, c:16'd0};
    axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 1*8), .len(8));

    data = '{dat:in_k, pt:SCALAR};
    axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 0*64), .len(48));

    p_in.x = random_vector(384/8) % P;
    p_in.y = random_vector(384/8) % P;

    p2_in.x[0] = random_vector(384/8) % P;
    p2_in.x[1] = random_vector(384/8) % P;
    p2_in.y[0] = random_vector(384/8) % P;
    p2_in.y[1] = random_vector(384/8) % P;

    case(i)
      // FP_AF
      0: begin

        p_in.z = 1;

        data = '{dat:p_in.x, pt:FP_AF};
        axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 1*64), .len(48));

        data = '{dat:p_in.y, pt:FP_AF};
        axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 2*64), .len(48));

        p_exp = point_mult(in_k, p_in);

      end
      // FP2_AF
      1: begin

        p2_in.z = FE2_one;

        data = '{dat:p2_in.x[0], pt:FP2_AF};
        axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 1*64), .len(48));

        data = '{dat:p2_in.x[1], pt:FP2_AF};
        axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 2*64), .len(48));

        data = '{dat:p2_in.y[0], pt:FP2_AF};
        axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 3*64), .len(48));

        data = '{dat:p2_in.y[1], pt:FP2_AF};
        axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 4*64), .len(48));

        p2_exp = fp2_point_mult(in_k, p2_in);

      end
    endcase

    inst = '{code:POINT_MULT, a:16'd0, b:16'd1, c:16'd10};
    axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 0*8), .len(8));

    if (i > 0)
      axi_lite_if.poke(.addr(32'h10), .data(0));

    fork
      begin
        out_if.get_stream(get_dat, get_len, 0);
        interrupt_rpl = get_dat;
        get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);

        assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
        assert(interrupt_rpl.index == i) else $fatal(1, "ERROR: Received wrong index value in message");
        if (i == 0) begin
          assert(interrupt_rpl.data_type == FP_JB) else $fatal(1, "ERROR: Received wrong data type value in message");

          p_out = 0;
          for (int i = 0; i < 3; i++) p_out[i*381 +: 381] = get_dat[i*(48*8) +: 381];

          if (to_affine(p_out) == to_affine(p_exp)) begin
            $display("INFO: Output element matched expected:");
            print_jb_point(p_out);
          end else begin
            $display("ERROR: Output element did NOT match expected:");
            print_jb_point(p_out);
            $display("Expected:");
            print_jb_point(p_exp);
            failed = 1;
          end

        end else begin
          assert(interrupt_rpl.data_type == FP2_JB) else $fatal(1, "ERROR: Received wrong data type value in message");

          p2_out = 0;
          for (int i = 0; i < 6; i++) p2_out[i*381 +: 381] = get_dat[i*(48*8) +: 381];

          if (fp2_to_affine(p2_out) == fp2_to_affine(p2_exp)) begin
            $display("INFO: Output element matched expected:");
            print_fp2_jb_point(p2_out);
          end else begin
            $display("ERROR: Output element did NOT match expected:");
            print_fp2_jb_point(p2_out);
            $display("Expected:");
            print_fp2_jb_point(p2_exp);
            failed = 1;
          end
        end
      end
      begin
        repeat(1000000) @(posedge out_if.i_clk);
        $fatal("ERROR: Timeout while waiting for result");
      end
    join_any
    disable fork;

    axi_lite_if.peek(.addr(32'h14), .data(rdata));
    $display("INFO: Last cycle count was %d", rdata);

    if(failed) break;

  end

  if(failed)
    $fatal(1, "ERROR: test_point_mult FAILED");

  $display("INFO: test_point_mult PASSED!");

endtask;

task test_pairing();
begin
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] get_dat;
  inst_t inst;
  logic failed;
  data_t data;
  logic [31:0] rdata;
  logic [DAT_BITS-1:0] in_k;
  bls12_381_interrupt_rpl_t interrupt_rpl;
  fe12_t  f_out, f_exp;
  af_point_t G1_p;
  fp2_af_point_t G2_p;
  fp2_jb_point_t R;
  failed = 0;

  G1_p = {Gy, Gx};
  G2_p = {bls12_381_pkg::G2y, bls12_381_pkg::G2x};

  ate_pairing(G1_p, G2_p, f_exp);
  $display("Running test_pairing...");

  // See what current instruction pointer is
  axi_lite_if.peek(.addr(32'h10), .data(rdata));

  // G1
  data = '{dat:G1_p.x, pt:FP_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START), .len(48));
  data = '{dat:G1_p.y, pt:FP_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 64), .len(48));

  data = '{dat:G2_p.x[0], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 2*64), .len(48));
  data = '{dat:G2_p.x[1], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 3*64), .len(48));

  data = '{dat:G2_p.y[0], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 4*64), .len(48));
  data = '{dat:G2_p.y[1], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 5*64), .len(48));

  inst = '{code:SEND_INTERRUPT, a:16'd6, b:16'hbeef, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+1)*8), .len(8));

  // Write to current slot to start
  inst = '{code:ATE_PAIRING, a:16'd0, b:16'd2, c:16'd6};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata)*8), .len(8));

  fork
    begin
      out_if.get_stream(get_dat, get_len, 0);
      interrupt_rpl = get_dat;

      assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
      assert(interrupt_rpl.index == 16'hbeef) else $fatal(1, "ERROR: Received wrong index value in message");
      assert(interrupt_rpl.data_type == FE12) else $fatal(1, "ERROR: Received wrong data type value in message");

      get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);

      for (int i = 0; i < 2; i++)
        for (int j = 0; j < 3; j++)
          for (int k = 0; k < 2; k++)
            f_out[i][j][k] = get_dat[(i*6+j*2+k)*(48*8) +: 381];

      if (f_out == f_exp) begin
        $display("INFO: Output matched expected:");
        print_fe12(f_out);
      end else begin
        $display("ERROR: Output did NOT match expected:");
        print_fe12(f_out);
        $display("Expected:");
        print_fe12(f_exp);
        failed = 1;
      end
    end
    begin
      repeat(1000000) @(posedge out_if.i_clk);
      $fatal("ERROR: Timeout while waiting for result");
    end
  join_any
  disable fork;

  axi_lite_if.peek(.addr(32'h14), .data(rdata));
  $display("INFO: Last cycle count was %d", rdata);

  // See what current instruction pointer is
  axi_lite_if.peek(.addr(32'h10), .data(rdata));

  $display("INFO: Current instruction pointer is 0x%x, setting to 0 and writing NULL instruction", rdata);

  inst = '{code:NOOP_WAIT, a:16'd0, b:16'h0, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START), .len(8));

  axi_lite_if.poke(.addr(32'h10), .data(32'd0));
  repeat(10) @(posedge clk);
  axi_lite_if.peek(.addr(32'h10), .data(rdata));
  assert(rdata == 32'd0) else $fatal(1, "ERROR: could not set instruction pointer");

  if(failed)
   $fatal(1, "ERROR: test_pairing FAILED");
  else
   $display("INFO: test_pairing PASSED");
end
endtask;

task test_control_logic();
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] get_dat;
  inst_t inst;
  logic failed;
  data_t data;
  logic [31:0] rdata;
  integer unsigned in, out;
  bls12_381_interrupt_rpl_t interrupt_rpl;

  failed = 0;
  in = 0;
  in[7:0] = $random();

  $display("Running test_control_logic...");

  //Reset the RAM
  axi_lite_if.poke(.addr(32'h0), .data(2'b11));

  axi_lite_if.poke(.addr(32'h10), .data(0));

  data = '{dat:in, pt:SCALAR};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 0*64), .len(48));
  data = '{dat:381'd0, pt:SCALAR};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 1*64), .len(48));
  data = '{dat:381'd1, pt:SCALAR};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + 2*64), .len(48));

  inst = '{code:SEND_INTERRUPT, a:16'd3, b:16'h8888, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 7*8), .len(8));

  inst = '{code:ADD_ELEMENT, a:16'd2, b:16'd3, c:16'd3};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 1*8), .len(8));

  inst = '{code:JUMP_NONZERO_SUB, a:16'd1, b:16'd0, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 2*8), .len(8));

  inst = '{code:JUMP_IF_EQ, a:16'd10, b:16'd0, c:16'd2};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 3*8), .len(8));

  inst = '{code:JUMP, a:16'd7, b:16'd0, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + 4*8), .len(8));

  axi_lite_if.poke(.addr(32'h10), .data(1));

  fork
    begin
      out_if.get_stream(get_dat, get_len, 0);
      interrupt_rpl = get_dat;

      assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
      assert(interrupt_rpl.index == 16'h8888) else $fatal(1, "ERROR: Received wrong index value in message");
      assert(interrupt_rpl.data_type == SCALAR) else $fatal(1, "ERROR: Received wrong data type value in message");

      get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);
      out = get_dat;

      if (out == in+1) begin
        $display("INFO: Output element matched expected:");
        $display("0x%x", out);
      end else begin
        $display("ERROR: Output element did NOT match expected:");
        $display("0x%x", out);
        $display("Expected:");
        $display("0x%x", in);
        failed = 1;
      end
    end
    begin
      repeat(100000) @(posedge out_if.i_clk);
      $fatal("ERROR: Timeout while waiting for result");
    end
  join_any
  disable fork;

  axi_lite_if.peek(.addr(32'h14), .data(rdata));
  $display("INFO: Last cycle count was %d", rdata);

  if(failed)
   $fatal(1, "ERROR: test_control_logic FAILED");


  $display("INFO: test_control_logic PASSED!");

endtask;

task test_multi_pairing();
begin
  integer signed get_len;
  logic [common_pkg::MAX_SIM_BYTS*8-1:0] get_dat;
  inst_t inst;
  logic failed;
  data_t data;
  logic [31:0] rdata;
  logic [DAT_BITS-1:0] in_k;
  bls12_381_interrupt_rpl_t interrupt_rpl;
  fe12_t  f_out, f_exp0, f_exp1;
  af_point_t G1_p;
  fp2_af_point_t G2_p;
  fp2_jb_point_t R;
  failed = 0;

  G1_p = {Gy, Gx};
  G2_p = {bls12_381_pkg::G2y, bls12_381_pkg::G2x};

  miller_loop(G1_p, G2_p, f_exp0);
  miller_loop(G1_p, G2_p, f_exp1);
  f_exp0 = fe12_mul(f_exp0, f_exp1);
  final_exponent(f_exp0);

  $display("Running test_multi_pairing...");

  // See what current instruction pointer is
  axi_lite_if.peek(.addr(32'h10), .data(rdata));

  // First load generator points into memory

  // G1
  data = '{dat:G1_p.x, pt:FP_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + ((1 << DATA_RAM_DEPTH) -1 -6)*64), .len(48));
  data = '{dat:G1_p.y, pt:FP_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + ((1 << DATA_RAM_DEPTH) -1 -5)*64), .len(48));

  // G2
  data = '{dat:G2_p.x[0], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + ((1 << DATA_RAM_DEPTH) -1 -4)*64), .len(48));
  data = '{dat:G2_p.x[1], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + ((1 << DATA_RAM_DEPTH) -1 -3)*64), .len(48));

  data = '{dat:G2_p.y[0], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + ((1 << DATA_RAM_DEPTH) -1 -2)*64), .len(48));
  data = '{dat:G2_p.y[1], pt:FP2_AF};
  axi_lite_if.put_data_multiple(.data(data), .addr(DATA_AXIL_START + ((1 << DATA_RAM_DEPTH) -1 -1)*64), .len(48));

  // Program instruction memory

  // Do two miller loops
  inst = '{code:MILLER_LOOP, a:((1 << DATA_RAM_DEPTH) -1 -6), b:((1 << DATA_RAM_DEPTH) -1 -4), c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+1)*8), .len(8));
  inst = '{code:MILLER_LOOP, a:((1 << DATA_RAM_DEPTH) -1 -6), b:((1 << DATA_RAM_DEPTH) -1 -4), c:16'd12};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+2)*8), .len(8));

  // Multiply result
  inst = '{code:MUL_ELEMENT , a:16'd0, b:16'd12, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+3)*8), .len(8));

  // Do final exp.
  inst = '{code:FINAL_EXP , a:16'd0, b:16'd0, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+4)*8), .len(8));

  inst = '{code:SEND_INTERRUPT, a:16'd0, b:16'h4321, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START + (rdata+5)*8), .len(8));

  axi_lite_if.poke(.addr(32'h10), .data(rdata+1));

  fork
    begin
      out_if.get_stream(get_dat, get_len, 0);
      interrupt_rpl = get_dat;

      assert(interrupt_rpl.hdr.cmd == BLS12_381_INTERRUPT_RPL) else $fatal(1, "ERROR: Received non-interrupt message");
      assert(interrupt_rpl.index == 16'h4321) else $fatal(1, "ERROR: Received wrong index value in message");
      assert(interrupt_rpl.data_type == FE12) else $fatal(1, "ERROR: Received wrong data type value in message");

      get_dat = get_dat >> $bits(bls12_381_interrupt_rpl_t);

      for (int i = 0; i < 2; i++)
        for (int j = 0; j < 3; j++)
          for (int k = 0; k < 2; k++)
            f_out[i][j][k] = get_dat[(i*6+j*2+k)*(48*8) +: 381];

      if (f_out == f_exp0) begin
        $display("INFO: Output matched expected:");
        print_fe12(f_out);
      end else begin
        $display("ERROR: Output did NOT match expected:");
        print_fe12(f_out);
        $display("Expected:");
        print_fe12(f_exp0);
        failed = 1;
      end
    end
    begin
      repeat(1000000) @(posedge out_if.i_clk);
      $fatal("ERROR: Timeout while waiting for result");
    end
  join_any
  disable fork;

  axi_lite_if.peek(.addr(32'h14), .data(rdata));
  $display("INFO: Last cycle count was %d", rdata);

  // See what current instruction pointer is
  axi_lite_if.peek(.addr(32'h10), .data(rdata));

  $display("INFO: Current instruction pointer is 0x%x, setting to 0 and writing NULL instruction", rdata);

  inst = '{code:NOOP_WAIT, a:16'd0, b:16'h0, c:16'd0};
  axi_lite_if.put_data_multiple(.data(inst), .addr(INST_AXIL_START), .len(8));

  axi_lite_if.poke(.addr(32'h10), .data(32'd0));
  repeat(10) @(posedge clk);
  axi_lite_if.peek(.addr(32'h10), .data(rdata));
  assert(rdata == 32'd0) else $fatal(1, "ERROR: could not set instruction pointer");

  if(failed)
   $fatal(1, "ERROR: test_multi_pairing FAILED");
  else
   $display("INFO: test_multi_pairing PASSED");
end
endtask;

task init_ram();
  int fd;
  int max_rams;
  int eod;
  int nxt_line, curr_line;
  logic [380:0] dat;
  logic [381*100-1:0] dat_flat;

  // First find how many rams we have - assume less than 100
  for (int i = 0; i < 100; i++) begin
    fd = $fopen ($sformatf("mod_ram_%0d.mem", i), "r");
    if (fd == 0) begin
      $display("INFO: Finished reading file at cnt %0d", i);
      max_rams = i;
      break;
    end
    $fclose(fd);
  end

  if (max_rams == 99)
    $display("WARNING: Reached max limit of RAMs, possibly will not simulate correctly");

  eod = 0;
  nxt_line = 0;
  dat_flat = 0;

  while(eod == 0) begin
    dat_flat = 0;
    for (int i = 0; i < max_rams; i++) begin
      fd = $fopen ($sformatf("mod_ram_%0d.mem", i), "r");
      curr_line = 0;

      while((curr_line <= nxt_line)) begin
        eod = $feof(fd);
        if (eod) break;
        $fscanf(fd,"%h\n", dat);
        curr_line++;
      end
      dat_flat[i*381 +: 381] = dat;
      $fclose(fd);
    end

    if (eod == 0) begin
      // Now shift in data
      for (int j = ((max_rams*381+31)/32); j >= 0; j--) begin
        axi_lite_if.poke(.addr(32'h18), .data(dat_flat[j*32 +: 32]));
        axi_lite_if.poke(.addr(32'h1c), .data(32'h02));
      end
      axi_lite_if.poke(.addr(32'h1c), .data(32'h01));
      nxt_line++;
    end

  end

  $display("INFO: Finished writing all RAMS", dat);

endtask

initial begin
  axi_lite_if.reset_source();
  out_if.rdy = 0;
  #100ns;

  if (BLS12_381_USE_KARATSUBA== "NO" && LOAD_RAM == "YES")
    init_ram();

  test_inv_element();
  test_mul_add_sub_element();
  test_point_mult();
  test_pairing();
  test_control_logic();
  test_multi_pairing();

  #1us $finish();
end
endmodule