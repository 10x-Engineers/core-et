// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// Second top: writes the VCD so the testbench stays untouched.
module icache_sum_fetch_fault_dump;
  initial begin
    $dumpfile("icache_sum_fetch_fault_tb.vcd");
    $dumpvars(0, icache_sum_fetch_fault_tb);
  end
endmodule
