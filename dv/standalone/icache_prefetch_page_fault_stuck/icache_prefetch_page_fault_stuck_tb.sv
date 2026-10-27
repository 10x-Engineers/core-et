// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// L0 micro-cache prefetch: FSM stuck after a page fault.
//
// Checks what the prefetch FSM does when a prefetch lookup gets a page fault
// in F2 with a TLB hit. No Minion sends a request in this test.
//
// DUT: icache_micro_cache (real RTL). L1 and PTW are TB models.
// Translation is Sv48 in S-mode. The PTW model returns a leaf PTE per page:
//   page 1  VA 0x1000..0x1FFF  V R A, X = 0  (not executable)
//   page 2  VA 0x2000..0x2FFF  V R X A
// Both pages map to the SRAM frame PA 0x0200_C000, so the PMA gives no
// access fault.
//
// Burst: start at VA 0x1FC0, num_lines = 1, so 2 lines:
//   line 0  VA 0x1FC0  page 1, page fault
//   line 1  VA 0x2000  page 2, last line, no fault
//
// Expected sequence:
//   1. Line 0 lookup: TLB miss. The FSM retries (Check_Hit -> FillDone_Wait).
//   2. PTW walk for page 1. The TLB fill gives f5_resp_fill_done.
//   3. Line 0 lookup again: TLB hit, page fault, no L1 request. The FSM
//      loads line 1 and goes to FillDone_Wait.
//   4. Nothing sends f5_resp_fill_done now: no TLB fill, no L1 fill and no
//      Minion request. With the defect the FSM stays in FillDone_Wait and
//      line 1 is never prefetched. A correct FSM goes on to line 1 and
//      finishes with esr_prefetch_done = 1.
//
// Run with:  make        (make wave opens GTKWave)

`include "soc.vh"

module icache_prefetch_page_fault_stuck_tb;

  localparam int NR_MINIONS   = 8;
  localparam int NR_MINIONS_L = $clog2(NR_MINIONS);
  localparam int L1_LATENCY   = 10;  // L1 request accept -> fill
  localparam int PTW_LATENCY  = 8;   // PTW request accept -> response
  localparam int WAIT_CYCLES  = 100; // cycles to wait for the FSM after the fault

  localparam logic [`PA_RANGE] SRAM_BASE = `PA_SIZE'h0200_C000;

  localparam logic [47:0] START_VA  = 48'h0000_0000_1FC0; // line 0, page 1
  localparam int          NUM_LINES = 1;                  // esr_prefetch_conf.num_lines
  localparam logic [47:0] LINE1_VA  = START_VA + 48'h40;  // line 1, page 2

  // VPN -> PTE permissions for the PTW model
  localparam logic [35:0] VPN_NOX = 36'h1; // page 1, X = 0
  localparam logic [35:0] VPN_X   = 36'h2; // page 2, X = 1

  // ------------------------------------------------------------------------
  // Clock, reset, cycle counter
  // ------------------------------------------------------------------------
  logic clock = 1'b0;
  logic reset = 1'b1;
  int   cyc   = 0;

  always #1 clock = ~clock;
  always @(posedge clock) cyc <= cyc + 1;

  // ------------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------------
  icache_prefetch_conf_t                    esr_prefetch_conf;
  logic                                     esr_prefetch_start;
  logic                                     esr_prefetch_done;
  logic                                     f4_resp_valid;
  logic                                     f4_resp_miss;
  icache_frontend_resp                      f4_resp;
  logic                                     f5_resp_fill_done;
  logic                                     l1_req_ready;
  logic                                     l1_req_valid;
  logic [`PA_RANGE]                         l1_req_addr;
  logic                                     l1_resp_early_valid;
  logic                                     l1_resp_valid;
  logic [`ICACHE_BLOCK_BITS-1:0]            l1_resp_data;
  minion_satp_info [NR_MINIONS-1:0]         satp_info;
  minion_ptw_req                            ptw_req_data;
  logic                                     ptw_req_valid;
  logic                                     ptw_req_ready;
  logic                                     ptw_resp_valid;
  minion_ptw_pte                            ptw_resp_data;

  icache_micro_cache #(
    .ID         ( 0          ),
    .NR_MINIONS ( NR_MINIONS )
  ) dut (
    .clock                       ( clock               ),
    .reset                       ( reset               ),
    .esr_prefetch_conf           ( esr_prefetch_conf   ),
    .esr_prefetch_start          ( esr_prefetch_start  ),
    .esr_prefetch_done           ( esr_prefetch_done   ),
    .esr_mprot                   ( '0                  ),
    .esr_vmspagesize             ( tlb_entry_type_4K   ),
    .esr_bypass_icache           ( 1'b0                ),
    .esr_shire_coop_mode         ( 1'b0                ),
    .f0_req_ready                (                     ),
    .f0_req_valid                ( 1'b0                ),
    .f0_req                      ( '0                  ),
    .f0_req_min_id               ( '0                  ),
    .f4_resp_valid               ( f4_resp_valid       ),
    .f4_resp_miss                ( f4_resp_miss        ),
    .f4_resp                     ( f4_resp             ),
    .f5_resp_fill_done           ( f5_resp_fill_done   ),
    .f0_flush_data               ( 1'b0                ),
    .f0_l1_miss_req_ready        ( l1_req_ready        ),
    .f0_l1_miss_req_valid        ( l1_req_valid        ),
    .f0_l1_miss_req_addr         ( l1_req_addr         ),
    .f0_l1_miss_resp_early_valid ( l1_resp_early_valid ),
    .f0_l1_miss_resp_valid       ( l1_resp_valid       ),
    .f0_l1_miss_resp_data        ( l1_resp_data        ),
    .f0_l1_miss_resp_ecc_err     ( 1'b0                ),
    .f0_l1_miss_resp_l2_err      ( 1'b0                ),
    .satp_info                   ( satp_info           ),
    .matp_info                   ( '0                  ),
    .tlb_invalidate              ( '0                  ),
    .ptw_req_data                ( ptw_req_data        ),
    .ptw_req_valid               ( ptw_req_valid       ),
    .ptw_req_ready               ( ptw_req_ready       ),
    .ptw_invalidate              (                     ),
    .ptw_resp_valid              ( ptw_resp_valid      ),
    .ptw_resp_data               ( ptw_resp_data       ),
    .apb_paddr                   ( '0                  ),
    .apb_pwrite                  ( 1'b0                ),
    .apb_psel                    ( 1'b0                ),
    .apb_penable                 ( 1'b0                ),
    .apb_pwdata                  ( '0                  ),
    .apb_pready                  (                     ),
    .apb_prdata                  (                     ),
    .apb_pslverr                 (                     ),
    .dbg_sm_signals              (                     )
  );

  // ------------------------------------------------------------------------
  // L1 model: one request at a time, fill L1_LATENCY cycles after accept.
  // early_valid is one cycle ahead of valid, as icache_top drives it.
  // ------------------------------------------------------------------------
  logic [L1_LATENCY-1:0] l1_pipe;
  logic [`PA_RANGE]      l1_addr_q;

  assign l1_req_ready        = 1'b1;
  assign l1_resp_valid       = l1_pipe[0];
  assign l1_resp_early_valid = l1_pipe[1];

  always_comb
    for (int w = 0; w < `ICACHE_BLOCK_BITS/64; w++)
      l1_resp_data[w*64 +: 64] = {l1_addr_q[31:0], 16'(w), 16'hFACE};

  always @(posedge clock) begin
    if (reset) begin
      l1_pipe   <= '0;
      l1_addr_q <= '0;
    end else begin
      l1_pipe <= l1_pipe >> 1;
      if (l1_req_valid && l1_req_ready) begin
        l1_pipe[L1_LATENCY-1] <= 1'b1;
        l1_addr_q             <= l1_req_addr;
      end
    end
  end

  // ------------------------------------------------------------------------
  // PTW model: returns the leaf PTE for the VPN PTW_LATENCY cycles after
  // accept. rsvd_for_hw[0] marks an M-mode walk, as ptw_top sets it.
  // ------------------------------------------------------------------------
  logic [PTW_LATENCY:0] ptw_pipe;
  minion_ptw_req        ptw_req_q;
  logic [35:0]          ptw_vpn_log [$];
  int                   ptw_cyc_log [$];

  assign ptw_req_ready  = 1'b1;
  assign ptw_resp_valid = ptw_pipe[0];

  always_comb begin
    ptw_resp_data                = '0;
    ptw_resp_data.ppn            = ($bits(ptw_resp_data.ppn))'(SRAM_BASE >> 12);
    ptw_resp_data.v              = 1'b1;
    ptw_resp_data.r              = 1'b1;
    ptw_resp_data.x              = (36'(ptw_req_q.addr) != VPN_NOX);
    ptw_resp_data.a              = 1'b1;
    ptw_resp_data.rsvd_for_hw[0] = (ptw_req_q.prv == `CSR_PRV_M);
  end

  always @(posedge clock) begin
    if (reset) begin
      ptw_pipe  <= '0;
      ptw_req_q <= '0;
    end else begin
      ptw_pipe <= ptw_pipe >> 1;
      if (ptw_req_valid && ptw_req_ready) begin
        ptw_pipe[PTW_LATENCY] <= 1'b1;
        ptw_req_q             <= ptw_req_data;
        ptw_vpn_log.push_back(36'(ptw_req_data.addr));
        ptw_cyc_log.push_back(cyc);
        $display("  cyc %4d: PTW walk for VPN 0x%0h", cyc, ptw_req_data.addr);
      end
      if (ptw_resp_valid)
        $display("  cyc %4d: PTW response, PPN 0x%0h, X = %0d",
                 cyc, ptw_resp_data.ppn, ptw_resp_data.x);
    end
  end

  // ------------------------------------------------------------------------
  // Monitors
  // ------------------------------------------------------------------------
  typedef struct {
    int               t;
    logic [47:0]      va;
    logic [`PA_RANGE] pa;
    int               lines;     // f0_prefetch_lines when the lookup is in F2
    bit               tlb_miss;
    bit               l0_miss;   // miss sent to the L1
    bit               page_fault;
    bit               access_fault;
  } lookup_t;

  lookup_t          pf_lookups [$];
  logic [`PA_RANGE] l1_log_pa  [$];
  int               l1_log_cyc [$];
  int               fill_done_cyc [$];

  int               fault_cyc         = -1; // F2 cycle of the page fault on line 0
  int               fault_idx         = -1; // index of that lookup in pf_lookups
  int               lines_after_fault = -1;
  logic [47:0]      next_va_after_fault;
  int               stuck_cycles      = 0;  // cycles in FillDone_Wait after the fault
  bit               left_filldone     = 0;  // FSM left FillDone_Wait after the fault
  bit               done_seen_low     = 0;
  int               done_rise_cyc     = -1;

  // Waveform helper
  int               tb_phase = 0;

  always @(posedge clock) begin
    if (!reset) begin
      if (dut.f0_prefetch_state != dut.f0_prefetch_state_next)
        $display("  cyc %4d: prefetch FSM %-13s -> %-13s  lines %2d  next VA 0x%012h",
                 cyc, dut.f0_prefetch_state.name(), dut.f0_prefetch_state_next.name(),
                 dut.f0_prefetch_lines, dut.f0_prefetch_req.addr[47:0]);

      if (dut.f2_valid && dut.f2_is_prefetch) begin
        lookup_t l;
        l.t            = cyc;
        l.va           = dut.f2_req.addr[47:0];
        l.pa           = dut.f2_paddr;
        l.lines        = dut.f0_prefetch_lines;
        l.tlb_miss     = dut.f2_tlb_resp_data.miss;
        l.l0_miss      = dut.f2_miss;
        l.page_fault   = dut.f2_page_fault;
        l.access_fault = dut.f2_access_fault;
        pf_lookups.push_back(l);
        $display("  cyc %4d: prefetch lookup in F2, VA 0x%012h, TLB %s, %s",
                 cyc, l.va, l.tlb_miss ? "miss" : "hit",
                 l.l0_miss      ? "L0 miss -> L1" :
                 l.page_fault   ? "PAGE FAULT"    :
                 l.access_fault ? "ACCESS FAULT"  : "no L1 request (retry)");
        if (l.page_fault && fault_cyc < 0) begin
          fault_cyc = cyc;
          fault_idx = pf_lookups.size() - 1;
        end
      end

      // Counter and next request, one cycle after the fault was in F2
      if (fault_cyc >= 0 && cyc == fault_cyc + 1) begin
        lines_after_fault   = dut.f0_prefetch_lines;
        next_va_after_fault = dut.f0_prefetch_req.addr[47:0];
        $display("  cyc %4d: after the fault: lines = %0d, next VA 0x%012h, state %s",
                 cyc, lines_after_fault, next_va_after_fault, dut.f0_prefetch_state.name());
      end

      if (fault_cyc >= 0 && cyc > fault_cyc) begin
        if (dut.f0_prefetch_state == icache_prefetch_state_FillDone_Wait && !left_filldone)
          stuck_cycles++;
        else
          left_filldone = 1;
      end

      if (l1_req_valid && l1_req_ready) begin
        l1_log_pa.push_back(l1_req_addr);
        l1_log_cyc.push_back(cyc);
        $display("  cyc %4d: L1 request PA 0x%010h", cyc, l1_req_addr);
      end

      if (f5_resp_fill_done) begin
        fill_done_cyc.push_back(cyc);
        $display("  cyc %4d: f5_resp_fill_done", cyc);
      end

      if (!esr_prefetch_done) done_seen_low = 1;
      if (done_seen_low && esr_prefetch_done && done_rise_cyc < 0) begin
        done_rise_cyc = cyc;
        $display("  cyc %4d: esr_prefetch_done rises", cyc);
      end
    end
  end

  // ------------------------------------------------------------------------
  // Stimulus helpers. tick() returns half a cycle after a posedge.
  // ------------------------------------------------------------------------
  task automatic tick();
    @(posedge clock);
    #0.5;
  endtask

  task automatic prefetch_start(logic [47:0] va, int num_lines);
    esr_prefetch_conf            = '0;
    esr_prefetch_conf.prv        = `CSR_PRV_S;
    esr_prefetch_conf.start_addr = va[`VA_RANGE_CA];
    esr_prefetch_conf.num_lines  = 6'(num_lines);
    esr_prefetch_start           = 1'b1;
    tick();
    esr_prefetch_start           = 1'b0;
  endtask

  // ------------------------------------------------------------------------
  // Checks
  // ------------------------------------------------------------------------
  int errors  = 0;
  int defects = 0;

  task automatic check(string what, longint got, longint exp, bit is_defect = 0);
    if (got == exp) $display("PASS  %-56s = 0x%0h", what, got);
    else begin
      $display("FAIL  %-56s = 0x%0h (expected 0x%0h)", what, got, exp);
      if (is_defect) defects++; else errors++;
    end
  endtask

  function automatic int lookups_of(logic [47:0] va);
    int n = 0;
    foreach (pf_lookups[k]) if (pf_lookups[k].va == va) n++;
    return n;
  endfunction

  function automatic int l1_reqs_before(int t);
    int n = 0;
    foreach (l1_log_cyc[k]) if (l1_log_cyc[k] <= t) n++;
    return n;
  endfunction

  function automatic int fill_done_between(int lo, int hi);
    int n = 0;
    foreach (fill_done_cyc[k]) if (fill_done_cyc[k] > lo && fill_done_cyc[k] <= hi) n++;
    return n;
  endfunction

  // ------------------------------------------------------------------------
  // Test
  // ------------------------------------------------------------------------
  int state_at_end;

  initial begin
    esr_prefetch_conf  = '0;
    esr_prefetch_start = 1'b0;
    satp_info          = '0;
    for (int m = 0; m < NR_MINIONS; m++) satp_info[m].mode = `CSR_SATP_MODE_SV48;

    $display("\nPrefetch page fault: Sv48, S-mode, L0 micro-cache 0, no Minion requests");
    $display("  burst: VA 0x%012h (page 1, X = 0) and VA 0x%012h (page 2), num_lines = %0d",
             START_VA, LINE1_VA, NUM_LINES);

    repeat (8) tick();
    reset = 1'b0;
    repeat (8) tick();

    $display("\n=== esr_prefetch_start, cycle %0d ===", cyc);
    tb_phase = 1;
    prefetch_start(START_VA, NUM_LINES);

    while (fault_cyc < 0 && cyc < 1000) tick();
    if (fault_cyc < 0) begin
      $display("ERROR no page fault seen");
      $finish;
    end
    tb_phase = 2;
    // Give a correct FSM time to prefetch line 1 and finish
    while (cyc < fault_cyc + WAIT_CYCLES && done_rise_cyc < 0) tick();
    repeat (5) tick();
    state_at_end = dut.f0_prefetch_state;
    $display("  cyc %4d: end, state %s, lines %0d, esr_prefetch_done %0d",
             cyc, dut.f0_prefetch_state.name(), dut.f0_prefetch_lines, esr_prefetch_done);

    // ---- Report ----------------------------------------------------------
    $display("\n  %-5s %-14s %-12s %-6s %-4s %-6s", "cyc", "VA", "PA", "lines", "TLB", "result");
    foreach (pf_lookups[k])
      $display("  %-5d 0x%012h 0x%010h %-6d %-4s %-6s", pf_lookups[k].t, pf_lookups[k].va,
               pf_lookups[k].pa, pf_lookups[k].lines, pf_lookups[k].tlb_miss ? "miss" : "hit",
               pf_lookups[k].l0_miss    ? "L1"         :
               pf_lookups[k].page_fault ? "page fault" :
               pf_lookups[k].access_fault ? "access fault" : "retry");
    $display("");
    $display("INFO  f5_resp_fill_done after the fault: %0d", fill_done_between(fault_cyc, cyc));
    $display("INFO  cycles in FillDone_Wait after the fault: %0d%s", stuck_cycles,
             left_filldone ? "" : " (never left)");
    $display("");

    // Sanity: the sequence in the header up to the page fault
    check("line 0: first lookup, TLB miss",                        pf_lookups[0].va == START_VA && pf_lookups[0].tlb_miss, 1);
    check("PTW walks before the fault",                            ptw_cyc_log.size(), 1);
    check("PTW walk VPN (page 1)",                                 ptw_vpn_log[0], VPN_NOX);
    check("f5_resp_fill_done between walk and fault (TLB fill)",   fill_done_between(ptw_cyc_log[0], fault_cyc), 1);
    check("line 0: faulting lookup VA",                            pf_lookups[fault_idx].va, START_VA);
    check("line 0: TLB miss on the faulting lookup (0 = hit)",     pf_lookups[fault_idx].tlb_miss, 0);
    check("line 0: page fault",                                    pf_lookups[fault_idx].page_fault, 1);
    check("line 0: access fault",                                  pf_lookups[fault_idx].access_fault, 0);
    check("L1 requests up to the fault",                           l1_reqs_before(fault_cyc + 1), 0);
    check("pending-line counter after the fault (no wrap)",        lines_after_fault, NUM_LINES - 1);
    check("next prefetch VA after the fault (line 1)",             next_va_after_fault, LINE1_VA);

    // The defect checks
    $display("");
    check("prefetch FSM left FillDone_Wait after the fault",       left_filldone, 1, 1);
    check("prefetch lookups for line 1",                           lookups_of(LINE1_VA) >= 1, 1, 1);
    check("prefetch FSM state at the end (0 = Idle)",              state_at_end, icache_prefetch_state_Idle, 1);
    check("esr_prefetch_done rose after the fault",                done_rise_cyc >= 0, 1, 1);

    $display("\n================================================");
    if (errors != 0)
      $display("TEST INVALID, %0d sanity error(s)", errors);
    else if (defects != 0)
      $display("TEST FAILED: prefetch FSM stuck in FillDone_Wait for %0d cycles after a page fault",
               stuck_cycles);
    else
      $display("TEST PASSED");
    $display("================================================");
    $finish;
  end

  // Watchdog
  initial begin
    #20000;
    $display("ERROR watchdog");
    $finish;
  end

endmodule
