// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// vim: se syn=systemverilog:

// //////////////////////////////////////////////////////////////////////////////
// Directed test for the L0 micro-cache code-prefetch FSM.
//
// Target defect
// -------------
// The prefetch FSM leaves icache_prefetch_state_Request on f0_prefetch_req_ready
// alone. Readiness only reports that no minion is driving f0_req_valid this
// cycle; it does not report that a prefetch request entered the pipeline. The
// acceptance condition is f0_prefetch_req_access, which is
// f0_prefetch_req_valid & f0_prefetch_req_ready.
//
// f0_prefetch_req_valid is qualified by the "miss not attended to" FSM, so it is
// deasserted for the whole window in which a minion miss was dropped because the
// single-entry miss handler was busy. If the prefetch FSM sits in Request during
// that window while no minion is requesting, it advances to Check_Hit without
// having injected anything. Check_Hit only leaves on f2_valid & f2_is_prefetch,
// which can never assert because no request carrying is_prefetch was issued.
// The FSM parks in Check_Hit and esr_prefetch_done stays low until software
// pulses esr_prefetch_start again.
//
// Checks
// ------
// a_prefetch_req_not_lost  concurrent, fires on the exact cycle of the defect
// liveness                 procedural, esr_prefetch_done must rise again
//
// Both sub-tests fail on unmodified RTL and pass once the Request exit is
// qualified with f0_prefetch_req_access.
// //////////////////////////////////////////////////////////////////////////////

`define CLK_HALF_PERIOD 0.5 // timescale units, usually ns

`include "soc.vh"

module icache_micro_cache_tb ();

  // Declared in the module so the test keeps its time base under any simulator
  timeunit      1ns;
  timeprecision 1ps;

  // //////////////////////////////////////////////////////////////////////////////
  // Parameters
  // //////////////////////////////////////////////////////////////////////////////
  localparam int unsigned NR_MINIONS   = 8;
  localparam int unsigned NR_MINIONS_L = $clog2(NR_MINIONS);

  // Cycles from an accepted L1 miss request to the fill response. Any value
  // above two works; the window being exercised does not depend on it.
  localparam int unsigned L1_LATENCY  = 20;
  localparam int unsigned PTW_LATENCY = 8;

  // Cycles allowed for a prefetch burst to report done before the test gives up
  localparam int unsigned DONE_TIMEOUT      = 2_000;
  // Cycles allowed for the FSM to pull esr_prefetch_done low out of Request
  localparam int unsigned DONE_FALL_TIMEOUT = 64;
  localparam int unsigned TIMEOUT_CYCLES  = 100_000;

  // SRAM region, from AD_SRAM_REGION in shire_defines.vh: paddr[39:12] == 0x0200C.
  // Chosen because icache_pma_unit reports SRAM as cacheable and never raises an
  // access fault for it, so no esr_mprot or privilege setup is needed.
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
  // ESRs
  icache_prefetch_conf_t                    esr_prefetch_conf;
  logic                                     esr_prefetch_start;
  logic                                     esr_prefetch_done;
  esr_mprot_t                               esr_mprot;
  tlb_entry_type                            esr_vmspagesize;
  logic                                     esr_bypass_icache;
  logic                                     esr_shire_coop_mode;
  // Request port
  logic                                     f0_req_ready;
  logic                                     f0_req_valid;
  frontend_icache_req                       f0_req;
  logic [NR_MINIONS_L-1:0]                  f0_req_min_id;
  // Response
  logic                                     f4_resp_valid;
  logic                                     f4_resp_miss;
  icache_frontend_resp                      f4_resp;
  logic                                     f5_resp_fill_done;
  // Flush
  logic                                     f0_flush_data;
  // Request to L1
  logic                                     f0_l1_miss_req_ready;
  logic                                     f0_l1_miss_req_valid;
  logic [`PA_RANGE]                         f0_l1_miss_req_addr;
  // Response from L1
  logic                                     f0_l1_miss_resp_early_valid;
  logic                                     f0_l1_miss_resp_valid;
  logic [`ICACHE_BLOCK_BITS-1:0]            f0_l1_miss_resp_data;
  logic                                     f0_l1_miss_resp_ecc_err;
  logic                                     f0_l1_miss_resp_l2_err;
  // TLB/PTW control
  minion_satp_info [NR_MINIONS-1:0]         satp_info;
  minion_satp_info [NR_MINIONS-1:0]         matp_info;
  logic [NR_MINIONS-1:0]                    tlb_invalidate;
  // PTW
  minion_ptw_req                            ptw_req_data;
  logic                                     ptw_req_valid;
  logic                                     ptw_req_ready;
  logic                                     ptw_invalidate;
  logic                                     ptw_resp_valid;
  minion_ptw_pte                            ptw_resp_data;
  // APB debug slave, unused here
  logic [`ICACHE_DBG_UCACHE_ADDR_WIDTH-1:0] apb_paddr;
  logic                                     apb_pwrite;
  logic                                     apb_psel;
  logic                                     apb_penable;
  logic [`bpam_shire_apb_data_width-1:0]    apb_pwdata;
  logic                                     apb_pready;
  logic [`bpam_shire_apb_data_width-1:0]    apb_prdata;
  logic                                     apb_pslverr;
  // Status monitor
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
  // A shift register keeps esr early_valid exactly one cycle ahead of valid,
  // which is how icache_top drives the pair: early_valid is the _next of valid,
  // used as the write setup for the latch based micro arrays.
  // The miss handler is single entry, so at most one request is outstanding.
  // //////////////////////////////////////////////////////////////////////////////
  logic [L1_LATENCY:0]   l1_pipe;
  logic [`PA_RANGE]      l1_addr_q;

  assign f0_l1_miss_req_ready = 1'b1;

  always_ff @(posedge clock) begin
    if (reset) begin
      l1_pipe   <= '0;
      l1_addr_q <= '0;
    end else begin
      l1_pipe <= l1_pipe >> 1;
      if (f0_l1_miss_req_valid && f0_l1_miss_req_ready) begin
        l1_pipe[L1_LATENCY] <= 1'b1;
        l1_addr_q           <= f0_l1_miss_req_addr;
      end
    end
  end

  assign f0_l1_miss_resp_valid       = l1_pipe[0];
  assign f0_l1_miss_resp_early_valid = l1_pipe[1];
  assign f0_l1_miss_resp_ecc_err     = 1'b0;
  assign f0_l1_miss_resp_l2_err      = 1'b0;

  // Address derived payload, so a fill can be told apart from stale array state
  always_comb begin
    for (int unsigned w = 0; w < (`ICACHE_BLOCK_BITS/64); w++)
      f0_l1_miss_resp_data[w*64 +: 64] = {l1_addr_q[31:0], w[15:0], 16'hFACE};
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Page table walker responder
  // Bare mode should never raise a walk. The model is here so that a walk does
  // not hang the test, and it reports any walk it sees.
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
  // Virtual address of test line n. Bare translation makes the physical address
  // identical, which keeps every test address inside the SRAM region. Returned at
  // the full extended VA width so the callers' size casts never widen a shift.
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
      @(posedge clock);
      esr_prefetch_start           = 1'b0;
    end
  endtask

  // Waits for the nomh FSM to reach a state, with a bounded patience
  task automatic wait_nomh (input icache_prefetch_miss_nomh_state s, output bit ok);
    int unsigned guard;
    begin
      guard = 0;
      ok    = 1'b0;
      while (guard < 4_000) begin
        if (dut.f0_prefetch_miss_nomh_state == s) begin
          ok = 1'b1;
          return;
        end
        @(posedge clock);
        guard++;
      end
    end
  endtask

  // Waits for a prefetch burst to report completion.
  // esr_prefetch_done resets to 1 and a start pulse holds it at 1 for one more
  // cycle, so the burst is only acknowledged once the FSM has driven it low from
  // the Request state. Both edges have to be observed, otherwise the reset value
  // alone would satisfy the check.
  task automatic check_done (input string tag);
    int unsigned guard;
    begin
      guard = 0;
      while (esr_prefetch_done && (guard < DONE_FALL_TIMEOUT)) begin
        @(posedge clock);
        guard++;
      end
      if (esr_prefetch_done) begin
        errors++;
        $display("ERROR %0t %s: esr_prefetch_done never fell, the FSM never reached Request (state %s)",
                 $time, tag, dut.f0_prefetch_state.name());
        return;
      end

      guard = 0;
      while (guard < DONE_TIMEOUT) begin
        @(posedge clock);
        guard++;
        if (esr_prefetch_done) begin
          $display("PASS  %0t %s: esr_prefetch_done rose again after %0d cycles", $time, tag, guard);
          return;
        end
      end
      errors++;
      $display("ERROR %0t %s: esr_prefetch_done still low %0d cycles after start, prefetch FSM is parked in %s",
               $time, tag, DONE_TIMEOUT, dut.f0_prefetch_state.name());
    end
  endtask

  // //////////////////////////////////////////////////////////////////////////////
  // Checks
  // //////////////////////////////////////////////////////////////////////////////

  // Leaving Request for Check_Hit is only legal on the cycle a prefetch request
  // actually enters the pipeline. Without that, the FSM waits in Check_Hit for an
  // f2_is_prefetch that was never issued. Written as a procedural checker rather
  // than an assertion action block so the counter stays portable across
  // simulators.
  logic prefetch_req_lost;

  assign prefetch_req_lost = !reset
                          && (dut.f0_prefetch_state      == icache_prefetch_state_Request)
                          && (dut.f0_prefetch_state_next == icache_prefetch_state_Check_Hit)
                          && !dut.f0_prefetch_req_access;

  int unsigned lost_req_errors = 0;

  always_ff @(posedge clock) begin
    if (prefetch_req_lost) begin
      lost_req_errors <= lost_req_errors + 1;
      $display("ERROR %0t prefetch request lost: FSM left Request for Check_Hit with req_valid=%0b ready=%0b nomh=%s",
               $time, dut.f0_prefetch_req_valid, dut.f0_prefetch_req_ready,
               dut.f0_prefetch_miss_nomh_state.name());
    end
  end

  // //////////////////////////////////////////////////////////////////////////////
  // Sub-test 1
  // Minimal form. A start pulse arrives while the nomh FSM holds the qualifier
  // low and no minion is requesting, so the FSM reaches Request with
  // f0_prefetch_req_valid already deasserted and f0_prefetch_req_ready asserted.
  // //////////////////////////////////////////////////////////////////////////////
  task automatic test_start_in_nomh_window ();
    bit ok;
    begin
      $display("\n---- test_start_in_nomh_window ----");
      do_reset();

      // Two misses back to back. The first allocates the miss handler, the second
      // finds it busy and is dropped, which is what opens the nomh window.
      minion_req(0, 0);
      minion_req(1, 1);

      wait_nomh(icache_prefetch_miss_nomh_state_FillDone_Wait, ok);
      if (!ok) begin
        errors++;
        $display("ERROR %0t test_start_in_nomh_window: nomh FSM never left NotPending, the dropped miss was not set up", $time);
        return;
      end
      $display("INFO  %0t dropped miss observed, nomh FSM in FillDone_Wait", $time);

      wait_nomh(icache_prefetch_miss_nomh_state_Req_Wait, ok);
      if (!ok) begin
        errors++;
        $display("ERROR %0t test_start_in_nomh_window: nomh FSM never reached Req_Wait", $time);
        return;
      end
      $display("INFO  %0t nomh FSM in Req_Wait, qualifier is low", $time);

      // Core is idle here, so f0_prefetch_req_ready is high the moment the FSM
      // enters Request while the qualifier is still low.
      prefetch_start(8, 0);
      check_done("test_start_in_nomh_window");
    end
  endtask

  // //////////////////////////////////////////////////////////////////////////////
  // Sub-test 2
  // Realistic form. The dropped minion retries on the fill done wake-up. That
  // retry clears the nomh FSM, but the qualifier is registered, so it recovers
  // one cycle later. In that cycle the core has gone quiet and the FSM leaves
  // Request on readiness alone.
  // //////////////////////////////////////////////////////////////////////////////
  task automatic test_retry_aligned_window ();
    bit ok;
    begin
      $display("\n---- test_retry_aligned_window ----");
      do_reset();

      minion_req(0, 0);
      minion_req(1, 1);

      wait_nomh(icache_prefetch_miss_nomh_state_Req_Wait, ok);
      if (!ok) begin
        errors++;
        $display("ERROR %0t test_retry_aligned_window: nomh FSM never reached Req_Wait", $time);
        return;
      end

      // Start pulse lands inside the window. One cycle later the FSM is in
      // Request with the qualifier low.
      prefetch_start(8, 0);

      // The retry. It holds readiness low for exactly one cycle, which keeps the
      // FSM in Request, and it clears the nomh FSM for the cycle after.
      minion_req(1, 1);

      // Core idle from here. Readiness rises while the qualifier is still low.
      check_done("test_retry_aligned_window");
    end
  endtask

  // //////////////////////////////////////////////////////////////////////////////
  // Reference sequence
  // Same burst with no dropped miss anywhere near it. This must pass on
  // unmodified RTL, which is what separates the defect from a broken testbench.
  // //////////////////////////////////////////////////////////////////////////////
  task automatic test_clean_prefetch ();
    begin
      $display("\n---- test_clean_prefetch ----");
      do_reset();
      prefetch_start(8, 0);
      check_done("test_clean_prefetch");
    end
  endtask

  // //////////////////////////////////////////////////////////////////////////////
  // Main
  // //////////////////////////////////////////////////////////////////////////////
  initial begin
    $display("\nstarting icache_micro_cache prefetch directed test");

    test_clean_prefetch();
    test_start_in_nomh_window();
    test_retry_aligned_window();

    repeat (50) @(posedge clock);

    $display("\n================================================");
    if ((errors + lost_req_errors) == 0)
      $display("TEST PASSED");
    else
      $display("TEST FAILED, %0d error(s) (%0d lost prefetch request(s))",
               errors + lost_req_errors, lost_req_errors);
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
