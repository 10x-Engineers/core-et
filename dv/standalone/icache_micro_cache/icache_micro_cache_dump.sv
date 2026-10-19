// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// Waveform dump companion for icache_micro_cache_tb.
//
// Kept outside the testbench so the testbench stays simulator neutral. This
// module is elaborated as a second top alongside the testbench and dumps the
// whole testbench hierarchy to a VCD that GTKWave can open.
//
// +define+TB_TOP=<module> selects the testbench, default icache_micro_cache_tb.
// +dumpfile=<path> overrides the VCD location, default waves.vcd in the run
// directory.

`timescale 1ns/1ps

`ifndef TB_TOP
  `define TB_TOP icache_micro_cache_tb
`endif

module icache_micro_cache_dump;
  string dumpfile;
  initial begin
    if (!$value$plusargs("dumpfile=%s", dumpfile)) dumpfile = "waves.vcd";
    $dumpfile(dumpfile);
    $dumpvars(0, `TB_TOP);
  end
endmodule
