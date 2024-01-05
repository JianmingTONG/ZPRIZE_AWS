/*
  Wrapper for the bls12-381 pairing engine.

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

module bls12_381_pairing_wrapper
  import bls12_381_pkg::*;
#(
  parameter type FE_TYPE = fe_t,
  parameter type FE2_TYPE = fe2_t,
  parameter type FE6_TYPE = fe6_t,
  parameter type FE12_TYPE = fe12_t,
  parameter type G1_FP_AF_TYPE = af_point_t,
  parameter type G2_FP_AF_TYPE = fp2_af_point_t,
  parameter type G2_FP_JB_TYPE = fp2_jb_point_t,
  parameter CTL_BITS = 32,
  parameter OVR_WRT_BIT = 8 // Need 82 bits for control
)(
  input i_clk, i_rst,
  // Inputs
  if_axi_stream.sink   i_pair_af_if, // G1 and G2 input point - or Fe12 element if we are only performing the final exponentiation
  input [1:0]          i_mode,       // 0 == ate pairing, 1 == only point multiplication, 2 == only miller loop, 3 == only final exponentiation
  input FE_TYPE        i_key,        // Input key when in mode == 1
  if_axi_stream.source o_fe12_if,    // Result fe12 of ate pairing / final exponentiation (if mode was 0/3)
  if_axi_stream.source o_p_jb_if,    // Result of point multiplication / miller loop  (if mode was 1/2)
  // Interface to FE_TYPE multiplier (mod P)
  if_axi_stream.source o_mul_fe_if,
  if_axi_stream.sink   i_mul_fe_if,
  // Interface to FE12_TYPE multiplier (mod P) (Implemented internally)
  if_axi_stream.source o_mul_fe12_if,
  if_axi_stream.sink   i_mul_fe12_if,
  // We provide interfaces to the inversion module
  if_axi_stream.source o_inv_fe2_if,
  if_axi_stream.sink   i_inv_fe2_if,
  if_axi_stream.source o_inv_fe_if,
  if_axi_stream.sink   i_inv_fe_if
);

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_fe_o_if  [3:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_fe_i_if  [3:0] (i_clk);
if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) add_fe_o_if  [6:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   add_fe_i_if  [6:0] (i_clk);
if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) sub_fe_o_if  [7:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   sub_fe_i_if  [7:0] (i_clk);

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_fe2_o_if  [4:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_fe2_i_if  [4:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mnr_fe2_o_if  [3:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mnr_fe2_i_if  [3:0] (i_clk);

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_fe6_o_if  [2:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_fe6_i_if  [2:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mnr_fe6_o_if  [2:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mnr_fe6_i_if  [2:0] (i_clk);

if_axi_stream #(.DAT_BITS(2*$bits(FE_TYPE)), .CTL_BITS(CTL_BITS)) mul_fe12_o_if [3:0] (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   mul_fe12_i_if [3:0] (i_clk);

if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   pow_fe12_o_if       (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   pow_fe12_i_if       (i_clk);

if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   fmap_fe12_o_if      (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   fmap_fe12_i_if      (i_clk);

if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   inv_fe12_o_if       (i_clk);
if_axi_stream #(.DAT_BITS($bits(FE_TYPE)), .CTL_BITS(CTL_BITS))   inv_fe12_i_if       (i_clk);

always_comb begin
  i_mul_fe12_if.rdy = mul_fe12_o_if[2].rdy;
  mul_fe12_o_if[2].copy_if_comb(i_mul_fe12_if.dat, i_mul_fe12_if.val, i_mul_fe12_if.sop, i_mul_fe12_if.eop, i_mul_fe12_if.err, i_mul_fe12_if.mod, i_mul_fe12_if.ctl);

  mul_fe12_i_if[2].rdy = o_mul_fe12_if.rdy;
  o_mul_fe12_if.copy_if_comb(mul_fe12_i_if[2].dat, mul_fe12_i_if[2].val, mul_fe12_i_if[2].sop, mul_fe12_i_if[2].eop, mul_fe12_i_if[2].err, mul_fe12_i_if[2].mod, mul_fe12_i_if[2].ctl);
end

bls12_381_pairing #(
  .FE_TYPE     ( FE_TYPE   ),
  .FE2_TYPE    ( FE2_TYPE  ),
  .FE12_TYPE   ( FE12_TYPE ),
  .CTL_BITS    ( CTL_BITS  ),
  .OVR_WRT_BIT ( OVR_WRT_BIT      ), // 16 bits
  .SQ_BIT      ( OVR_WRT_BIT + 16 ),
  .FMAP_BIT    ( OVR_WRT_BIT + 17 ),
  .POW_BIT     ( OVR_WRT_BIT + 17 )
)
bls12_381_pairing (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_pair_af_if ( i_pair_af_if ),
  .i_mode  ( i_mode  ),
  .i_key   ( i_key   ),
  .o_fe12_if      ( o_fe12_if        ),
  .o_p_jb_if      ( o_p_jb_if        ),
  .o_mul_fe2_if   ( mul_fe2_o_if[1]  ),
  .i_mul_fe2_if   ( mul_fe2_i_if[1]  ),
  .o_add_fe_if    ( add_fe_o_if[4]   ),
  .i_add_fe_if    ( add_fe_i_if[4]   ),
  .o_sub_fe_if    ( sub_fe_o_if[4]   ),
  .i_sub_fe_if    ( sub_fe_i_if[4]   ),
  .o_mul_fe12_if  ( mul_fe12_o_if[0] ),
  .i_mul_fe12_if  ( mul_fe12_i_if[0] ),
  .o_mul_fe_if    ( mul_fe_o_if[1]   ),
  .i_mul_fe_if    ( mul_fe_i_if[1]   ),
  .o_pow_fe12_if  ( pow_fe12_o_if    ),
  .i_pow_fe12_if  ( pow_fe12_i_if    ),
  .o_fmap_fe12_if ( fmap_fe12_o_if   ),
  .i_fmap_fe12_if ( fmap_fe12_i_if   ),
  .o_inv_fe12_if  ( inv_fe12_o_if    ),
  .i_inv_fe12_if  ( inv_fe12_i_if    )
);

bls12_381_fe12_fmap_wrapper #(
  .FE_TYPE     ( FE_TYPE           ),
  .CTL_BITS    ( CTL_BITS          ),
  .CTL_BIT_POW ( OVR_WRT_BIT + 17  )
)
bls12_381_fe12_fmap_wrapper (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_fmap_fe12_if ( fmap_fe12_i_if  ),
  .i_fmap_fe12_if ( fmap_fe12_o_if  ),
  .o_mul_fe2_if   ( mul_fe2_o_if[2] ),
  .i_mul_fe2_if   ( mul_fe2_i_if[2] ),
  .o_mul_fe_if    ( mul_fe_o_if[2]  ),
  .i_mul_fe_if    ( mul_fe_i_if[2]  )
);

bls12_381_fe12_inv_wrapper #(
  .FE_TYPE     ( FE_TYPE         ),
  .CTL_BITS    ( CTL_BITS        ),
  .OVR_WRT_BIT ( OVR_WRT_BIT + 0 )  // Can overlap as we restore control on output when valid
)
bls12_381_fe12_inv_wrapper (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_inv_fe12_if ( inv_fe12_i_if   ),
  .i_inv_fe12_if ( inv_fe12_o_if   ),
  .o_inv_fe2_if  ( o_inv_fe2_if    ),
  .i_inv_fe2_if  ( i_inv_fe2_if    ),
  .o_inv_fe_if   ( o_inv_fe_if     ),
  .i_inv_fe_if   ( i_inv_fe_if     ),
  .o_mul_fe_if   ( mul_fe_o_if[3]  ),
  .i_mul_fe_if   ( mul_fe_i_if[3]  ),
  .o_mul_fe2_if  ( mul_fe2_o_if[3] ),
  .i_mul_fe2_if  ( mul_fe2_i_if[3] ),
  .o_mnr_fe2_if  ( mnr_fe2_o_if[2] ),
  .i_mnr_fe2_if  ( mnr_fe2_i_if[2] ),
  .o_mul_fe6_if  ( mul_fe6_o_if[1] ),
  .i_mul_fe6_if  ( mul_fe6_i_if[1] ),
  .o_mnr_fe6_if  ( mnr_fe6_o_if[1] ),
  .i_mnr_fe6_if  ( mnr_fe6_i_if[1] ),
  .o_add_fe_if   ( add_fe_o_if[5]  ),
  .i_add_fe_if   ( add_fe_i_if[5]  ),
  .o_sub_fe_if   ( sub_fe_o_if[6]  ),
  .i_sub_fe_if   ( sub_fe_i_if[6]  )
);

ec_fe12_pow_s #(
  .FE_TYPE     ( FE_TYPE                     ),
  .CTL_BIT_POW ( OVR_WRT_BIT + 17            ),
  .POW_BITS    ( $bits(bls12_381_pkg::ATE_X) ),
  .SQ_BIT      ( OVR_WRT_BIT + 16            )
)
ec_fe12_pow_s (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_mul_fe12_if ( mul_fe12_o_if[1] ),
  .i_mul_fe12_if ( mul_fe12_i_if[1] ),
  .o_sub_fe_if   ( sub_fe_o_if[5]   ),
  .i_sub_fe_if   ( sub_fe_i_if[5]   ),
  .o_pow_fe12_if ( pow_fe12_i_if    ),
  .i_pow_fe12_if ( pow_fe12_o_if    )
);

ec_fe2_mul_s #(
  .FE_TYPE  ( FE_TYPE  ),
  .CTL_BITS ( CTL_BITS )
)
ec_fe2_mul_s (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_mul_fe2_if ( mul_fe2_i_if[4] ),
  .i_mul_fe2_if ( mul_fe2_o_if[4] ),
  .o_add_fe_if  ( add_fe_o_if[0]  ),
  .i_add_fe_if  ( add_fe_i_if[0]  ),
  .o_sub_fe_if  ( sub_fe_o_if[0]  ),
  .i_sub_fe_if  ( sub_fe_i_if[0]  ),
  .o_mul_fe_if  ( mul_fe_o_if[0]  ),
  .i_mul_fe_if  ( mul_fe_i_if[0]  )
);

fe2_mul_by_nonresidue_s #(
  .FE_TYPE  ( FE_TYPE  )
)
fe2_mul_by_nonresidue_s (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_mnr_fe2_if ( mnr_fe2_i_if[3] ),
  .i_mnr_fe2_if ( mnr_fe2_o_if[3] ),
  .o_add_fe_if  ( add_fe_o_if[1]  ),
  .i_add_fe_if  ( add_fe_i_if[1]  ),
  .o_sub_fe_if  ( sub_fe_o_if[1]  ),
  .i_sub_fe_if  ( sub_fe_i_if[1]  )
);

ec_fe6_mul_s #(
  .FE_TYPE  ( FE_TYPE  ),
  .FE2_TYPE ( FE2_TYPE ),
  .FE6_TYPE ( FE6_TYPE ),
  .OVR_WRT_BIT ( OVR_WRT_BIT + 8 ) // 3 bits
)
ec_fe6_mul_s (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_mul_fe2_if ( mul_fe2_o_if[0] ),
  .i_mul_fe2_if ( mul_fe2_i_if[0] ),
  .o_add_fe_if  ( add_fe_o_if[2]  ),
  .i_add_fe_if  ( add_fe_i_if[2]  ),
  .o_sub_fe_if  ( sub_fe_o_if[2]  ),
  .i_sub_fe_if  ( sub_fe_i_if[2]  ),
  .o_mnr_fe2_if ( mnr_fe2_o_if[0] ),
  .i_mnr_fe2_if ( mnr_fe2_i_if[0] ),
  .o_mul_fe6_if ( mul_fe6_i_if[2] ),
  .i_mul_fe6_if ( mul_fe6_o_if[2] )
);

fe6_mul_by_nonresidue_s #(
  .FE_TYPE  ( FE_TYPE  )
)
fe6_mul_by_nonresidue_s (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_mnr_fe2_if ( mnr_fe2_o_if[1] ),
  .i_mnr_fe2_if ( mnr_fe2_i_if[1] ),
  .o_mnr_fe6_if ( mnr_fe6_i_if[2] ),
  .i_mnr_fe6_if ( mnr_fe6_o_if[2] )
);

ec_fe12_mul_s #(
  .FE_TYPE  ( FE_TYPE  ),
  .OVR_WRT_BIT ( OVR_WRT_BIT + 0  ), // 3 bits
  .SQ_BIT      ( OVR_WRT_BIT + 16 )
)
ec_fe12_mul_s (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .o_mul_fe6_if   ( mul_fe6_o_if[0]     ),
  .i_mul_fe6_if   ( mul_fe6_i_if[0]     ),
  .o_add_fe_if    ( add_fe_o_if[3]   ),
  .i_add_fe_if    ( add_fe_i_if[3]   ),
  .o_sub_fe_if    ( sub_fe_o_if[3]   ),
  .i_sub_fe_if    ( sub_fe_i_if[3]   ),
  .o_mnr_fe6_if   ( mnr_fe6_o_if[0]  ),
  .i_mnr_fe6_if   ( mnr_fe6_i_if[0]  ),
  .o_mul_fe12_if  ( mul_fe12_i_if[3] ),
  .i_mul_fe12_if  ( mul_fe12_o_if[3] )
);

adder_pipe # (
  .BITS     ( bls12_381_pkg::DAT_BITS ),
  .P        ( bls12_381_pkg::P        ),
  .CTL_BITS ( CTL_BITS ),
  .LEVEL    ( 2        )
)
adder_pipe (
  .i_clk ( i_clk        ),
  .i_rst ( i_rst        ),
  .i_add ( add_fe_o_if[6] ),
  .o_add ( add_fe_i_if[6] )
);

subtractor_pipe # (
  .BITS     ( bls12_381_pkg::DAT_BITS ),
  .P        ( bls12_381_pkg::P        ),
  .CTL_BITS ( CTL_BITS ),
  .LEVEL    ( 2        )
)
subtractor_pipe (
  .i_clk ( i_clk          ),
  .i_rst ( i_rst          ),
  .i_sub ( sub_fe_o_if[7] ),
  .o_sub ( sub_fe_i_if[7] )
);

resource_share # (
  .NUM_IN       ( 6                ),
  .DAT_BITS     ( 2*$bits(FE_TYPE) ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 32 ), // 3 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 1                )
)
resource_share_fe_add (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( add_fe_o_if[5:0] ),
  .o_res ( add_fe_o_if[6]   ),
  .i_res ( add_fe_i_if[6]   ),
  .o_axi ( add_fe_i_if[5:0] )
);

resource_share # (
  .NUM_IN       ( 7                ),
  .DAT_BITS     ( 2*$bits(FE_TYPE) ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 32 ), // 3 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 1                )
)
resource_share_fe_sub (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( sub_fe_o_if[6:0] ),
  .o_res ( sub_fe_o_if[7]   ),
  .i_res ( sub_fe_i_if[7]   ),
  .o_axi ( sub_fe_i_if[6:0] )
);

resource_share # (
  .NUM_IN       ( 4                ),
  .DAT_BITS     ( 2*$bits(FE_TYPE) ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 32 ), // 3 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 1                )
)
resource_share_fe_mul (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( mul_fe_o_if[3:0] ),
  .o_res ( o_mul_fe_if      ),
  .i_res ( i_mul_fe_if      ),
  .o_axi ( mul_fe_i_if[3:0] )
);

resource_share # (
  .NUM_IN       ( 4                ),
  .DAT_BITS     ( 2*$bits(FE_TYPE) ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 38 ), // 2 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 0                )
)
resource_share_fe2_mul (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( mul_fe2_o_if[3:0] ),
  .o_res ( mul_fe2_o_if[4]   ),
  .i_res ( mul_fe2_i_if[4]   ),
  .o_axi ( mul_fe2_i_if[3:0] )
);

resource_share # (
  .NUM_IN       ( 2                ),
  .DAT_BITS     ( 2*$bits(FE_TYPE) ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 38 ), // 2 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 0                )
)
resource_share_fe6_mul (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( mul_fe6_o_if[1:0] ),
  .o_res ( mul_fe6_o_if[2]   ),
  .i_res ( mul_fe6_i_if[2]   ),
  .o_axi ( mul_fe6_i_if[1:0] )
);

resource_share # (
  .NUM_IN       ( 3                ),
  .DAT_BITS     ( 2*$bits(FE_TYPE) ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 42 ), // 2 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 0                )
)
resource_share_fe12_mul (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( mul_fe12_o_if[2:0] ),
  .o_res ( mul_fe12_o_if[3]   ),
  .i_res ( mul_fe12_i_if[3]   ),
  .o_axi ( mul_fe12_i_if[2:0] )
);

resource_share # (
  .NUM_IN       ( 3                ),
  .DAT_BITS     ( $bits(FE_TYPE)   ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 46 ), // 2 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 0                )
)
resource_share_fe2_mnr (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( mnr_fe2_o_if[2:0] ),
  .o_res ( mnr_fe2_o_if[3]   ),
  .i_res ( mnr_fe2_i_if[3]   ),
  .o_axi ( mnr_fe2_i_if[2:0] )
);

resource_share # (
  .NUM_IN       ( 2                ),
  .DAT_BITS     ( $bits(FE_TYPE)   ),
  .CTL_BITS     ( CTL_BITS         ),
  .OVR_WRT_BIT  ( OVR_WRT_BIT + 48 ), // 2 bits
  .PIPELINE_IN  ( 1                ),
  .PIPELINE_OUT ( 0                )
)
resource_share_fe6_mnr (
  .i_clk ( i_clk ),
  .i_rst ( i_rst ),
  .i_axi ( mnr_fe6_o_if[1:0] ),
  .o_res ( mnr_fe6_o_if[2]   ),
  .i_res ( mnr_fe6_i_if[2]   ),
  .o_axi ( mnr_fe6_i_if[1:0] )
);

endmodule