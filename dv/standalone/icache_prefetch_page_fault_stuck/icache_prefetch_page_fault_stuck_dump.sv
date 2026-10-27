// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// Second top: writes the VCD so the testbench stays untouched.
module icache_prefetch_page_fault_stuck_dump;
  initial begin
    $dumpfile("icache_prefetch_page_fault_stuck_tb.vcd");
    $dumpvars(0, icache_prefetch_page_fault_stuck_tb);
  end
endmodule
