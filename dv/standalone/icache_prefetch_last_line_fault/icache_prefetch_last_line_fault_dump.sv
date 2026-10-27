// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// Second top: writes the VCD so the testbench stays untouched.
module icache_prefetch_last_line_fault_dump;
  initial begin
    $dumpfile("icache_prefetch_last_line_fault_tb.vcd");
    $dumpvars(0, icache_prefetch_last_line_fault_tb);
  end
endmodule
