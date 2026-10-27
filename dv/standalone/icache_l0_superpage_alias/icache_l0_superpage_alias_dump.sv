// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// Second top: writes the VCD so the testbench stays untouched.
module icache_l0_superpage_alias_dump;
  initial begin
    $dumpfile("icache_l0_superpage_alias_tb.vcd");
    $dumpvars(0, icache_l0_superpage_alias_tb);
  end
endmodule
