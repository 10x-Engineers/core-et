// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// Xcelium-only workaround for the nested `MAX widths in debug_defines.vh.
//
// Makefile.xcelium compiles this file ahead of the testbench. Do not include
// it from the testbench, which has to stay simulator neutral.
//
// xmvlog 23.03 cannot expand a `MAX whose argument is another macro that
// itself expands to `MAX. It reports NORECI ("input source text recursion")
// and then either crashes (*F,INTERR) or loses track of the argument list.
// The rest of the file then fails to parse with EXPCOL, BDMINS and TMWFMA
// errors in shire_types.vh, and EOFICD in the next source file. These two
// widths have that shape:
//
//   NEIGH_DM_APB_ADDR_WIDTH = `MAX(`NEIGH_CH_DM_APB_ADDR_WIDTH, ...)
//                                   ^ expands to (1 + (`MAX(...)))
//   APB_AD_SHIRE_TOP_WIDTH  = `MAX(`ESR_APB_AD_PP_WIDTH, `MAX(..., `NEIGH_DM_APB_ADDR_WIDTH))
//                                   ^ expands to `MAX(...)
//
// The RTL headers are left untouched. The defines are pulled in once here.
// Their include guards keep the later `include "soc.vh" from reading them
// again. The two widths are then redefined with the same value, written as
// plain ternaries so that no `MAX receives a `MAX through another macro.

`include "soc_defines.vh"

`undef NEIGH_DM_APB_ADDR_WIDTH
`define NEIGH_DM_APB_ADDR_WIDTH \
  ((((`NEIGH_CH_DM_APB_ADDR_WIDTH) > (`MIN_DM_APB_ADDR_WIDTH)) ? \
    (`NEIGH_CH_DM_APB_ADDR_WIDTH) : (`MIN_DM_APB_ADDR_WIDTH)) + 1)

`undef APB_AD_SHIRE_TOP_WIDTH
`define APB_AD_SHIRE_TOP_WIDTH \
  ((((`ICACHE_MEMS_APB_ADDR_WIDTH) > (`NEIGH_DM_APB_ADDR_WIDTH)) ? \
    (((`ESR_APB_AD_PP_WIDTH) > (`ICACHE_MEMS_APB_ADDR_WIDTH)) ? \
      (`ESR_APB_AD_PP_WIDTH) : (`ICACHE_MEMS_APB_ADDR_WIDTH)) : \
    (((`ESR_APB_AD_PP_WIDTH) > (`NEIGH_DM_APB_ADDR_WIDTH)) ? \
      (`ESR_APB_AD_PP_WIDTH) : (`NEIGH_DM_APB_ADDR_WIDTH))))

// maxshire_defines.vh, same shape: MAXSHIRE_SBM_APB_{AD,D}_WIDTH expand to `MAX
`undef MAXSHIRE_APB_AD_WIDTH
`define MAXSHIRE_APB_AD_WIDTH \
  (((`MAXSHIRE_SBM_APB_AD_WIDTH) > (`MAXSHIRE_BPAM_APB_ADDR_WIDTH)) ? \
    (`MAXSHIRE_SBM_APB_AD_WIDTH) : (`MAXSHIRE_BPAM_APB_ADDR_WIDTH))

`undef MAXSHIRE_APB_D_WIDTH
`define MAXSHIRE_APB_D_WIDTH \
  (((`MAXSHIRE_SBM_APB_D_WIDTH) > (`MAXSHIRE_BPAM_APB_DATA_WIDTH)) ? \
    (`MAXSHIRE_SBM_APB_D_WIDTH) : (`MAXSHIRE_BPAM_APB_DATA_WIDTH))

// macros.vh latches. xmvlog 23.03 has no type(expr) operator, so
// "localparam type T = type(DIN); wire T _din = DIN;" fails with SVEXTK,
// SVNOTY and EXPCOM. The intermediate wire is kept, sized with $bits instead,
// so the latch behaves as in macros.vh. DIN is a packed value at every call
// site, so assigning the vector back to DOUT loses nothing.
`undef LATCH
`define LATCH(CLK, DOUT, DIN) \
      if (1) begin \
          wire [$bits(DIN)-1:0] _din = DIN; \
          always @(CLK or _din) \
              if(CLK) DOUT <= _din; \
      end

`undef LATCH_P2
`define LATCH_P2(CLK, DOUT, DIN) \
      if (1) begin \
          wire [$bits(DIN)-1:0] _din = DIN; \
          always @(CLK or _din) \
              if(~CLK) DOUT <= _din; \
      end
