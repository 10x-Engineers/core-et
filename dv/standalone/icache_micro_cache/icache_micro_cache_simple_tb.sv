// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// vim: se syn=systemverilog:

// //////////////////////////////////////////////////////////////////////////////
// Simple directed test for the L0 micro-cache.
//
// Scenario
// --------
//   cycle 0   minion 0 fetches line 0
//   cycle 1   minion 1 fetches line 1
//   cycle 2-3 idle
//   cycle 4   esr_prefetch_start pulse for lines 8 to 8+PREFETCH_EXTRA_LINES
//
// Expected
// --------
//   Both minion requests miss, because the micro-cache is empty after reset.
//   The miss handler is single entry: minion 0 allocates it and sends the L1
//   request, minion 1 finds it busy and its miss is dropped, which moves the
//   "miss not attended to" FSM to FillDone_Wait.
//   The L1 model returns the fill for the minion 0 request L1_LATENCY cycles
//   after accepting it, and the micro-cache raises f5_resp_fill_done.
//   Exactly two f4 responses appear, in order, both with f4_resp_miss set.
//   The prefetch burst must finish: esr_prefetch_done falls when the FSM
//   reaches Request and rises again once the burst is served.
//
// Run with:  make TB=icache_micro_cache_simple_tb
// //////////////////////////////////////////////////////////////////////////////

`define CLK_HALF_PERIOD 0.5 // timescale units, usually ns

`include "soc.vh"

module icache_micro_cache_simple_tb ();

  timeunit      1ns;
  timeprecision 1ps;

  // //////////////////////////////////////////////////////////////////////////////
  // Parameters
  // //////////////////////////////////////////////////////////////////////////////
  localparam int unsigned NR_MINIONS   = 8;
  localparam int unsigned NR_MINIONS_L = $clog2(NR_MINIONS);

  // Cycles from an accepted L1 miss request to the fill response delivered
  // back to the micro-cache
  localparam int unsigned L1_LATENCY  = 10;
  localparam int unsigned PTW_LATENCY = 8;

  // Idle cycles between the second minion request and the prefetch start
  localparam int unsigned IDLE_BEFORE_PREFETCH = 2;

  // First line of the prefetch burst and the number of lines after it.
  // esr_prefetch_conf.num_lines counts the extra lines: the FSM loads it, and
  // in Fill_Wait it finishes when the count is zero or decrements and steps to
  // the next line. A burst therefore fetches num_lines + 1 lines.
  localparam int unsigned PREFETCH_FIRST_LINE  = 8;
  localparam int unsigned PREFETCH_EXTRA_LINES = 3; // lines 8, 9, 10, 11

  // Pipeline depth from f0 to f4, used to bound the wait for the responses
  localparam int unsigned RESP_TIMEOUT      = 64;
  // Patience for the L1 fill, well above L1_LATENCY plus the pipeline depth
  localparam int unsigned FILL_TIMEOUT      = L1_LATENCY + 32;
  localparam int unsigned DONE_TIMEOUT      = 2_000;
  localparam int unsigned DONE_FALL_TIMEOUT = 64;
  localparam int unsigned TIMEOUT_CYCLES    = 100_000;

  // SRAM region, from AD_SRAM_REGION in shire_defines.vh: paddr[39:12] == 0x0200C.
  // The PMA unit reports SRAM as cacheable and never faults on it, so no
  // esr_mprot or privilege setup is needed.
  localparam logic [`PA_SIZE-1:0] SRAM_BASE = `PA_SIZE'h0200_C000;

  int unsigned errors = 0;

  // //////////////////////////////////////////////////////////////////////////////
  // Clock and reset. Reset is synchronous and active high, matching RST_FF.
  // //////////////////////////////////////////////////////////////////////////////
  logic clock = 1'b1;
  always #(`CLK_HALF_PERIOD) clock = ~clock;

  logic reset = 1'b1;

  // //////////////////////////////////////////////////////////////////////////////
  // DUT connections
  // //////////////////////////////////////////////////////////////////////////////
  icache_prefetch_conf_t                    esr_prefetch_conf;
  logic                                     esr_prefetch_start;
  logic                                     esr_prefetch_done;
  esr_mprot_t                               esr_mprot;
  tlb_entry_type                            esr_vmspagesize;
  logic                                     esr_bypass_icache;
  logic                                     esr_shire_coop_mode;
  logic                                     f0_req_ready;
  logic                                     f0_req_valid;
  frontend_icache_req                       f0_req;
  logic [NR_MINIONS_L-1:0]                  f0_req_min_id;
  logic                                     f4_resp_valid;
  logic                                     f4_resp_miss;
  icache_frontend_resp                      f4_resp;
  logic                                     f5_resp_fill_done;
  logic                                     f0_flush_data;
  logic                                     f0_l1_miss_req_ready;
  logic                                     f0_l1_miss_req_valid;
  logic [`PA_RANGE]                         f0_l1_miss_req_addr;
  logic                                     f0_l1_miss_resp_early_valid;
  logic                                     f0_l1_miss_resp_valid;
  logic [`ICACHE_BLOCK_BITS-1:0]            f0_l1_miss_resp_data;
  logic                                     f0_l1_miss_resp_ecc_err;
  logic                                     f0_l1_miss_resp_l2_err;
  minion_satp_info [NR_MINIONS-1:0]         satp_info;
  minion_satp_info [NR_MINIONS-1:0]         matp_info;
  logic [NR_MINIONS-1:0]                    tlb_invalidate;
  minion_ptw_req                            ptw_req_data;
  logic                                     ptw_req_valid;
  logic                                     ptw_req_ready;
  logic                                     ptw_invalidate;
  logic                                     ptw_resp_valid;
  minion_ptw_pte                            ptw_resp_data;
  logic [`ICACHE_DBG_UCACHE_ADDR_WIDTH-1:0] apb_paddr;
  logic                                     apb_pwrite;
  logic                                     apb_psel;
  logic                                     apb_penable;
  logic [`bpam_shire_apb_data_width-1:0]    apb_pwdata;
  logic                                     apb_pready;
  logic [`bpam_shire_apb_data_width-1:0]    apb_prdata;
  logic                                     apb_pslverr;
  icache_dbg_sm_t                           dbg_sm_signals;

  // //////////////////////////////////////////////////////////////////////////////
  // DUT
  // //////////////////////////////////////////////////////////////////////////////
  icache_micro_cache #(
    .ID         ( 0          ),
    .NR_MINIONS ( NR_MINIONS )
  ) dut (
    .clock                       ( clock                       ),
    .reset                       ( reset                       ),
    .esr_prefetch_conf           ( esr_prefetch_conf           ),
    .esr_prefetch_start          ( esr_prefetch_start          ),
    .esr_prefetch_done           ( esr_prefetch_done           ),
    .esr_mprot                   ( esr_mprot                   ),
    .esr_vmspagesize             ( esr_vmspagesize             ),
    .esr_bypass_icache           ( esr_bypass_icache           ),
    .esr_shire_coop_mode         ( esr_shire_coop_mode         ),
    .f0_req_ready                ( f0_req_ready                ),
    .f0_req_valid                ( f0_req_valid                ),
    .f0_req                      ( f0_req                      ),
    .f0_req_min_id               ( f0_req_min_id               ),
    .f4_resp_valid               ( f4_resp_valid               ),
    .f4_resp_miss                ( f4_resp_miss                ),
    .f4_resp                     ( f4_resp                     ),
    .f5_resp_fill_done           ( f5_resp_fill_done           ),
    .f0_flush_data               ( f0_flush_data               ),
    .f0_l1_miss_req_ready        ( f0_l1_miss_req_ready        ),
    .f0_l1_miss_req_valid        ( f0_l1_miss_req_valid        ),
    .f0_l1_miss_req_addr         ( f0_l1_miss_req_addr         ),
    .f0_l1_miss_resp_early_valid ( f0_l1_miss_resp_early_valid ),
    .f0_l1_miss_resp_valid       ( f0_l1_miss_resp_valid       ),
    .f0_l1_miss_resp_data        ( f0_l1_miss_resp_data        ),
    .f0_l1_miss_resp_ecc_err     ( f0_l1_miss_resp_ecc_err     ),
    .f0_l1_miss_resp_l2_err      ( f0_l1_miss_resp_l2_err      ),
    .satp_info                   ( satp_info                   ),
    .matp_info                   ( matp_info                   ),
    .tlb_invalidate              ( tlb_invalidate              ),
    .ptw_req_data                ( ptw_req_data                ),
    .ptw_req_valid               ( ptw_req_valid               ),
    .ptw_req_ready               ( ptw_req_ready               ),
    .ptw_invalidate              ( ptw_invalidate              ),
    .ptw_resp_valid              ( ptw_resp_valid              ),
    .ptw_resp_data               ( ptw_resp_data               ),
    .apb_paddr                   ( apb_paddr                   ),
    .apb_pwrite                  ( apb_pwrite                  ),
    .apb_psel                    ( apb_psel                    ),
    .apb_penable                 ( apb_penable                 ),
    .apb_pwdata                  ( apb_pwdata                  ),
    .apb_pready                  ( apb_pready                  ),
    .apb_prdata                  ( apb_prdata                  ),
    .apb_pslverr                 ( apb_pslverr                 ),
    .dbg_sm_signals              ( dbg_sm_signals              )
  );

  // //////////////////////////////////////////////////////////////////////////////
  // L1 responder
  // early_valid runs exactly one cycle ahead of valid, which is how icache_top
  // drives the pair. The miss handler is single entry, so at most one request
  // is outstanding.
  // //////////////////////////////////////////////////////////////////////////////
  // L1_LATENCY stages: a request sampled on edge n raises resp_valid for the
  // cycle sampled on edge n + L1_LATENCY.
  logic [L1_LATENCY-1:0] l1_pipe;
  logic [`PA_RANGE]      l1_addr_q;

  assign f0_l1_miss_req_ready = 1'b1;

  always_ff @(posedge clock) begin
    if (reset) begin
      l1_pipe   <= '0;
      l1_addr_q <= '0;
    end else begin
      l1_pipe <= l1_pipe >> 1;
      if (f0_l1_miss_req_valid && f0_l1_miss_req_ready) begin
        l1_pipe[L1_LATENCY-1] <= 1'b1;
        l1_addr_q           <= f0_l1_miss_req_addr;
        $display("INFO  %0t L1 miss request for PA 0x%0h", $time, f0_l1_miss_req_addr);
      end
    end
  end

  assign f0_l1_miss_resp_valid       = l1_pipe[0];
  assign f0_l1_miss_resp_early_valid = l1_pipe[1];
  assign f0_l1_miss_resp_ecc_err     = 1'b0;
  assign f0_l1_miss_resp_l2_err      = 1'b0;

  // Fill bookkeeping for the checks: when the L1 request was accepted, when
  // the fill came back, and how many fills the micro-cache acknowledged.
  time         l1_req_time  = 0;
  time         l1_resp_time = 0;
  int unsigned l1_req_count = 0;
  int unsigned fill_count   = 0;
  int unsigned fill_done_count = 0;

  always_ff @(posedge clock) begin
    if (!reset) begin
      if (f0_l1_miss_req_valid && f0_l1_miss_req_ready) begin
        l1_req_time  <= $time;
        l1_req_count <= l1_req_count + 1;
      end
      if (f0_l1_miss_resp_valid) begin
        l1_resp_time <= $time;
        fill_count   <= fill_count + 1;
        $display("INFO  %0t L1 fill response for PA 0x%0h delivered to the micro-cache",
                 $time, l1_addr_q);
      end
      if (f5_resp_fill_done) begin
        fill_done_count <= fill_done_count + 1;
        $display("INFO  %0t f5_resp_fill_done, minions may retry", $time);
      end
    end
  end

  // Address derived payload, so a fill can be told apart from stale array state
  always_comb begin
    for (int unsigned w = 0; w < (`ICACHE_BLOCK_BITS/64); w++)
      f0_l1_miss_resp_data[w*64 +: 64] = {l1_addr_q[31:0], w[15:0], 16'hFACE};
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Page table walker responder
  // Bare mode should never raise a walk. The model keeps a walk from hanging
  // the test and reports any walk it sees.
  // //////////////////////////////////////////////////////////////////////////////
  logic [PTW_LATENCY:0] ptw_pipe;
  minion_ptw_req        ptw_req_q;

  assign ptw_req_ready = 1'b1;

  always_ff @(posedge clock) begin
    if (reset) begin
      ptw_pipe  <= '0;
      ptw_req_q <= '0;
    end else begin
      ptw_pipe <= ptw_pipe >> 1;
      if (ptw_req_valid && ptw_req_ready) begin
        ptw_pipe[PTW_LATENCY] <= 1'b1;
        ptw_req_q             <= ptw_req_data;
        $display("NOTE  %0t PTW walk requested for VA 0x%0h", $time, ptw_req_data.addr);
      end
    end
  end

  assign ptw_resp_valid = ptw_pipe[0];

  always_comb begin
    ptw_resp_data              = '0;
    ptw_resp_data.ppn          = ($bits(ptw_resp_data.ppn))'(ptw_req_q.addr); // identity mapping
    ptw_resp_data.v            = 1'b1;
    ptw_resp_data.r            = 1'b1;
    ptw_resp_data.x            = 1'b1;
    ptw_resp_data.a            = 1'b1;
    ptw_resp_data.u            = 1'b1;
    ptw_resp_data.access_fault = 1'b0;
    ptw_resp_data.canceled_req = 1'b0;
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Static configuration
  // Bare translation keeps the physical address equal to the virtual address, so
  // the test addresses land in the SRAM region without a page table.
  // //////////////////////////////////////////////////////////////////////////////
  initial begin
    esr_mprot           = '0;
    esr_vmspagesize     = tlb_entry_type_4K;
    esr_bypass_icache   = 1'b0;
    esr_shire_coop_mode = 1'b0;
    f0_flush_data       = 1'b0;
    tlb_invalidate      = '0;
    apb_paddr           = '0;
    apb_pwrite          = 1'b0;
    apb_psel            = 1'b0;
    apb_penable         = 1'b0;
    apb_pwdata          = '0;

    for (int unsigned m = 0; m < NR_MINIONS; m++) begin
      satp_info[m].mode = `CSR_SATP_MODE_BARE;
      satp_info[m].ppn  = '0;
      matp_info[m].mode = `CSR_SATP_MODE_BARE;
      matp_info[m].ppn  = '0;
    end

    esr_prefetch_conf  = '0;
    esr_prefetch_start = 1'b0;
    f0_req_valid       = 1'b0;
    f0_req             = '0;
    f0_req_min_id      = '0;

    $timeformat(-9, 0, " ns", 12);
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Stimulus helpers
  // //////////////////////////////////////////////////////////////////////////////
  function automatic logic [`VA_SIZE_EXT-1:0] line_addr (input int unsigned n);
    line_addr = `VA_SIZE_EXT'(SRAM_BASE) + (`VA_SIZE_EXT'(n) << 6);
  endfunction

  task automatic do_reset ();
    begin
      reset        = 1'b1;
      f0_req_valid = 1'b0;
      repeat (8) @(posedge clock);
      reset = 1'b0;
      repeat (8) @(posedge clock);
    end
  endtask

  // Single cycle fetch request from one minion
  task automatic minion_req (input int unsigned line_n, input int unsigned min_id);
    begin
      f0_req                = '0;
      f0_req.thread_id      = '0;
      f0_req.vm_status.prv  = 2'b11; // machine mode
      f0_req.addr           = ($bits(f0_req.addr))'(line_addr(line_n));
      f0_req_min_id         = min_id[NR_MINIONS_L-1:0];
      f0_req_valid          = 1'b1;
      $display("INFO  %0t minion %0d requests line %0d (VA 0x%0h)", $time, min_id, line_n, f0_req.addr);
      @(posedge clock);
      f0_req_valid          = 1'b0;
    end
  endtask

  task automatic prefetch_start (input int unsigned line_n, input int unsigned num_lines);
    begin
      esr_prefetch_conf            = '0;
      esr_prefetch_conf.prv        = `CSR_PRV_M;
      esr_prefetch_conf.start_addr = ($bits(esr_prefetch_conf.start_addr))'(line_addr(line_n) >> 6);
      esr_prefetch_conf.num_lines  = num_lines[5:0];
      esr_prefetch_start           = 1'b1;
      $display("INFO  %0t esr_prefetch_start for lines %0d to %0d (%0d line(s))",
               $time, line_n, line_n + num_lines, num_lines + 1);
      @(posedge clock);
      esr_prefetch_start           = 1'b0;
    end
  endtask

  // //////////////////////////////////////////////////////////////////////////////
  // Response monitor
  // The response port carries no minion id, but the pipeline is in order and
  // only the minion requests produce a response (prefetch responses are
  // suppressed in f3), so the n-th response belongs to the n-th request.
  // //////////////////////////////////////////////////////////////////////////////
  int unsigned resp_count = 0;
  bit          resp_miss [0:1];

  always_ff @(posedge clock) begin
    if (!reset && f4_resp_valid) begin
      $display("INFO  %0t f4 response #%0d: miss=%0b cacheable=%0b page_fault=%0b access_fault=%0b",
               $time, resp_count, f4_resp_miss, f4_resp.cacheable, f4_resp.page_fault, f4_resp.access_fault);
      if (resp_count < 2) resp_miss[resp_count] <= f4_resp_miss;
      resp_count <= resp_count + 1;
    end
  end

  // Monitor the dropped miss. The miss handler is single entry, so the second
  // miss is not attended to and the nomh FSM records it.
  always_ff @(posedge clock) begin
    if (!reset && (dut.f0_prefetch_miss_nomh_state != dut.f0_prefetch_miss_nomh_state_next))
      $display("INFO  %0t nomh FSM %s -> %s", $time,
               dut.f0_prefetch_miss_nomh_state.name(), dut.f0_prefetch_miss_nomh_state_next.name());
    if (!reset && (dut.f0_prefetch_state != dut.f0_prefetch_state_next))
      $display("INFO  %0t prefetch FSM %s -> %s", $time,
               dut.f0_prefetch_state.name(), dut.f0_prefetch_state_next.name());
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Checks
  // //////////////////////////////////////////////////////////////////////////////
  task automatic check_both_missed ();
    int unsigned guard;
    begin
      guard = 0;
      while ((resp_count < 2) && (guard < RESP_TIMEOUT)) begin
        @(posedge clock);
        guard++;
      end
      if (resp_count != 2) begin
        errors++;
        $display("ERROR %0t expected 2 responses, saw %0d within %0d cycles", $time, resp_count, RESP_TIMEOUT);
        return;
      end
      for (int unsigned m = 0; m < 2; m++) begin
        if (resp_miss[m])
          $display("PASS  %0t minion %0d missed", $time, m);
        else begin
          errors++;
          $display("ERROR %0t minion %0d hit, expected a miss on an empty micro-cache", $time, m);
        end
      end
    end
  endtask

  // The accepted minion miss must be answered by L1 after L1_LATENCY cycles and
  // the micro-cache must announce the fill with f5_resp_fill_done.
  task automatic check_fill_response ();
    int unsigned guard;
    int unsigned observed;
    begin
      guard = 0;
      while ((fill_done_count == 0) && (guard < FILL_TIMEOUT)) begin
        @(posedge clock);
        guard++;
      end
      if (fill_count == 0) begin
        errors++;
        $display("ERROR %0t no L1 fill response within %0d cycles, L1 requests seen: %0d",
                 $time, FILL_TIMEOUT, l1_req_count);
        return;
      end
      observed = (l1_resp_time - l1_req_time) / (2 * `CLK_HALF_PERIOD);
      if (observed == L1_LATENCY)
        $display("PASS  %0t L1 fill delivered %0d cycles after the request", $time, observed);
      else begin
        errors++;
        $display("ERROR %0t L1 fill delivered after %0d cycles, expected %0d", $time, observed, L1_LATENCY);
      end
      if (fill_done_count == 0) begin
        errors++;
        $display("ERROR %0t f5_resp_fill_done never rose after the fill", $time);
      end else
        $display("PASS  %0t fill acknowledged with f5_resp_fill_done", $time);
    end
  endtask

  // esr_prefetch_done resets to 1 and a start pulse holds it at 1 for one more
  // cycle, so the burst is only acknowledged once the FSM has driven it low from
  // Request and then high again when the burst is served.
  task automatic check_prefetch_done ();
    int unsigned guard;
    begin
      guard = 0;
      while (esr_prefetch_done && (guard < DONE_FALL_TIMEOUT)) begin
        @(posedge clock);
        guard++;
      end
      if (esr_prefetch_done) begin
        errors++;
        $display("ERROR %0t esr_prefetch_done never fell, the FSM never reached Request (state %s)",
                 $time, dut.f0_prefetch_state.name());
        return;
      end
      $display("INFO  %0t esr_prefetch_done fell, prefetch FSM in %s", $time, dut.f0_prefetch_state.name());

      guard = 0;
      while (guard < DONE_TIMEOUT) begin
        @(posedge clock);
        guard++;
        if (esr_prefetch_done) begin
          $display("PASS  %0t esr_prefetch_done rose again after %0d cycles", $time, guard);
          return;
        end
      end
      errors++;
      $display("ERROR %0t esr_prefetch_done still low %0d cycles after start, prefetch FSM is parked in %s",
               $time, DONE_TIMEOUT, dut.f0_prefetch_state.name());
    end
  endtask

  // //////////////////////////////////////////////////////////////////////////////
  // Main
  // //////////////////////////////////////////////////////////////////////////////
  initial begin
    $display("\nstarting icache_micro_cache simple test: two minion misses then a prefetch");

    do_reset();

    // Two back to back requests from two minions, both to lines that are not
    // in the micro-cache.
    minion_req(0, 0);
    minion_req(1, 1);

    // Idle gap, then the prefetch burst
    repeat (IDLE_BEFORE_PREFETCH) @(posedge clock);
    prefetch_start(PREFETCH_FIRST_LINE, PREFETCH_EXTRA_LINES);

    check_both_missed();
    check_fill_response();
    check_prefetch_done();

    repeat (50) @(posedge clock);

    $display("\n================================================");
    if (errors == 0)
      $display("TEST PASSED");
    else
      $display("TEST FAILED, %0d error(s)", errors);
    $display("================================================\n");
    $finish;
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Watchdog
  // //////////////////////////////////////////////////////////////////////////////
  int cycle_count;

  initial begin
    cycle_count = 0;
    @(negedge reset);
    forever begin
      @(posedge clock);
      cycle_count++;
      if (cycle_count == TIMEOUT_CYCLES) begin
        $display("ERROR %0t watchdog: %0d cycles elapsed without finishing", $time, TIMEOUT_CYCLES);
        $display("TEST FAILED, watchdog");
        $finish;
      end
    end
  end

endmodule
