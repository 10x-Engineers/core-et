// Copyright (c) 2026 Ainekko
// SPDX-License-Identifier: Apache-2.0

// L0 micro-cache prefetch: fault on the last line of a burst.
//
// Checks what the prefetch FSM does when the last line of a burst gets an
// access fault in F2 without a TLB miss.
//
// DUT: icache_micro_cache (real RTL). L1 and PTW are TB models.
// Translation is bare (TLB hit, PA = VA). Only SRAM (PA 0x0200_C000 to
// 0x0200_CFFF) is fetchable. PA 0x0200_D000 is outside every fetchable
// region, so the PMA gives an access fault there.
//
// Burst: start at SRAM line 62, num_lines = 2, so 3 lines:
//   line 62  PA 0x0200_CF80  L0 miss, L1 fill
//   line 63  PA 0x0200_CFC0  L0 miss, L1 fill
//   line 64  PA 0x0200_D000  access fault, no TLB miss (last line)
//
// Phase 1: run the burst and stop. On the fault, Check_Hit loads the next
//   request without a test for the last line, so the pending-line counter
//   goes from 0 to 63. A correct FSM stops: counter 0, state Idle,
//   esr_prefetch_done = 1.
// Phase 2: M0 fetches SRAM line 0 (L0 miss, L1 fill). Its fill done is the
//   first f5_resp_fill_done after the fault. With the defect, this releases
//   the FSM, which then sends a prefetch lookup for line 65, outside the
//   requested burst.
//
// Run with:  make        (make wave opens GTKWave)

`include "soc.vh"

module icache_prefetch_last_line_fault_tb;

  localparam int NR_MINIONS   = 8;
  localparam int NR_MINIONS_L = $clog2(NR_MINIONS);
  localparam int L1_LATENCY   = 10;  // L1 request accept -> fill
  localparam int PTW_LATENCY  = 8;
  localparam int WAIT_CYCLES  = 30;  // cycles to wait for the FSM after the fault

  localparam logic [`PA_RANGE] SRAM_BASE = `PA_SIZE'h0200_C000;

  localparam int FIRST_LINE = 62;
  localparam int NUM_LINES  = 2;                      // esr_prefetch_conf.num_lines
  localparam int LAST_LINE  = FIRST_LINE + NUM_LINES; // line 64, faults
  localparam int MINION_LINE = 0;                     // phase 2 fetch

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
  logic                                     f0_req_ready;
  logic                                     f0_req_valid;
  frontend_icache_req                       f0_req;
  logic [NR_MINIONS_L-1:0]                  f0_req_min_id;
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
    .f0_req_ready                ( f0_req_ready        ),
    .f0_req_valid                ( f0_req_valid        ),
    .f0_req                      ( f0_req              ),
    .f0_req_min_id               ( f0_req_min_id       ),
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
    .matp_info                   ( satp_info           ),
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
  // Address helpers. Bare translation: PA = VA.
  // ------------------------------------------------------------------------
  function automatic logic [`VA_SIZE_EXT-1:0] line_va(int n);
    return `VA_SIZE_EXT'(SRAM_BASE) + (`VA_SIZE_EXT'(n) << 6);
  endfunction

  function automatic int line_of(logic [`PA_RANGE] pa);
    return int'((pa - SRAM_BASE) >> 6);
  endfunction

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
  // PTW model. Bare mode never walks; the model only reports a walk.
  // ------------------------------------------------------------------------
  logic [PTW_LATENCY:0] ptw_pipe;
  minion_ptw_req        ptw_req_q;
  int                   ptw_walks = 0;

  assign ptw_req_ready  = 1'b1;
  assign ptw_resp_valid = ptw_pipe[0];

  always_comb begin
    ptw_resp_data     = '0;
    ptw_resp_data.ppn = ($bits(ptw_resp_data.ppn))'(ptw_req_q.addr);
    ptw_resp_data.v   = 1'b1;
    ptw_resp_data.r   = 1'b1;
    ptw_resp_data.x   = 1'b1;
    ptw_resp_data.a   = 1'b1;
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
        ptw_walks++;
      end
    end
  end

  // ------------------------------------------------------------------------
  // Monitors
  // ------------------------------------------------------------------------
  typedef struct {
    int               t;
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

  int               fault_cyc       = -1; // F2 cycle of the fault on the last line
  int               lines_after_fault = -1;
  logic [`PA_RANGE] next_pa_after_fault;
  bit               done_seen_low   = 0;
  int               done_rise_cyc   = -1;

  // Waveform helper
  int               tb_phase = 0;

  always @(posedge clock) begin
    if (!reset) begin
      if (dut.f0_prefetch_state != dut.f0_prefetch_state_next)
        $display("  cyc %4d: prefetch FSM %-13s -> %-13s  lines %2d  next PA 0x%010h",
                 cyc, dut.f0_prefetch_state.name(), dut.f0_prefetch_state_next.name(),
                 dut.f0_prefetch_lines, dut.f0_prefetch_req.addr[`PA_RANGE]);

      if (dut.f2_valid && dut.f2_is_prefetch) begin
        lookup_t l;
        l.t            = cyc;
        l.pa           = dut.f2_paddr;
        l.lines        = dut.f0_prefetch_lines;
        l.tlb_miss     = dut.f2_tlb_resp_data.miss;
        l.l0_miss      = dut.f2_miss;
        l.page_fault   = dut.f2_page_fault;
        l.access_fault = dut.f2_access_fault;
        pf_lookups.push_back(l);
        $display("  cyc %4d: prefetch lookup in F2, line %0d PA 0x%010h, TLB %s, %s",
                 cyc, line_of(l.pa), l.pa, l.tlb_miss ? "miss" : "hit",
                 l.l0_miss ? "L0 miss -> L1" :
                 (l.page_fault || l.access_fault) ? "FAULT" : "no L1 request (retry)");
        if ((l.page_fault || l.access_fault) && line_of(l.pa) == LAST_LINE && fault_cyc < 0)
          fault_cyc = cyc;
      end

      // Counter and next request, one cycle after the fault was in F2
      if (fault_cyc >= 0 && cyc == fault_cyc + 1) begin
        lines_after_fault   = dut.f0_prefetch_lines;
        next_pa_after_fault = dut.f0_prefetch_req.addr[`PA_RANGE];
        $display("  cyc %4d: after the fault: lines = %0d, next PA 0x%010h (line %0d), state %s",
                 cyc, lines_after_fault, next_pa_after_fault, line_of(next_pa_after_fault),
                 dut.f0_prefetch_state.name());
      end

      if (l1_req_valid && l1_req_ready) begin
        l1_log_pa.push_back(l1_req_addr);
        l1_log_cyc.push_back(cyc);
        $display("  cyc %4d: L1 request PA 0x%010h (line %0d)", cyc, l1_req_addr, line_of(l1_req_addr));
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

  task automatic prefetch_start(int first, int num_lines);
    esr_prefetch_conf            = '0;
    esr_prefetch_conf.prv        = `CSR_PRV_M;
    esr_prefetch_conf.start_addr = ($bits(esr_prefetch_conf.start_addr))'(line_va(first) >> 6);
    esr_prefetch_conf.num_lines  = 6'(num_lines);
    esr_prefetch_start           = 1'b1;
    tick();
    esr_prefetch_start           = 1'b0;
  endtask

  // M0 sends one fetch and waits for F4. On a miss it waits for fill done
  // and retries until it hits.
  task automatic minion_fetch(int line);
    bit hit = 0;
    while (!hit) begin
      int n;
      f0_req_valid         = 1'b1;
      f0_req               = '0;
      f0_req.vm_status.prv = `CSR_PRV_M;
      f0_req.addr          = ($bits(f0_req.addr))'(line_va(line));
      f0_req_min_id        = '0;
      tick();
      f0_req_valid = 1'b0;
      while (!f4_resp_valid) tick();
      hit = !f4_resp_miss;
      $display("  cyc %4d: M0 line %0d F4 %s", cyc, line, hit ? "hit" : "miss, sleeps");
      if (!hit) begin
        n = fill_done_cyc.size();
        while (fill_done_cyc.size() == n) tick();
      end
    end
  endtask

  // ------------------------------------------------------------------------
  // Checks
  // ------------------------------------------------------------------------
  int errors  = 0;
  int defects = 0;

  task automatic check(string what, longint got, longint exp, bit is_defect = 0);
    if (got == exp) $display("PASS  %-56s = %0d", what, got);
    else begin
      $display("FAIL  %-56s = %0d (expected %0d)", what, got, exp);
      if (is_defect) defects++; else errors++;
    end
  endtask

  function automatic int lookups_of(int line);
    int n = 0;
    foreach (pf_lookups[k]) if (line_of(pf_lookups[k].pa) == line) n++;
    return n;
  endfunction

  function automatic int lookups_outside(int lo, int hi);
    int n = 0;
    foreach (pf_lookups[k])
      if (line_of(pf_lookups[k].pa) < lo || line_of(pf_lookups[k].pa) > hi) n++;
    return n;
  endfunction

  // ------------------------------------------------------------------------
  // Test
  // ------------------------------------------------------------------------
  int               fill_done_before_p2;
  int               lookups_before_p2;
  int               state_after_p1;
  int               fill_done_after_fault;

  initial begin
    esr_prefetch_conf  = '0;
    esr_prefetch_start = 1'b0;
    f0_req_valid       = 1'b0;
    f0_req             = '0;
    f0_req_min_id      = '0;
    satp_info          = '0;
    for (int m = 0; m < NR_MINIONS; m++) satp_info[m].mode = `CSR_SATP_MODE_BARE;

    $display("\nPrefetch fault on the last line: bare mode, M-mode, L0 micro-cache 0");
    $display("  burst: lines %0d..%0d, PA 0x%010h..0x%010h (num_lines = %0d)",
             FIRST_LINE, LAST_LINE, line_va(FIRST_LINE), line_va(LAST_LINE), NUM_LINES);
    $display("  line %0d is outside SRAM: PMA access fault", LAST_LINE);

    repeat (8) tick();
    reset = 1'b0;
    repeat (8) tick();

    // ---- Phase 1: the burst, fault on the last line ----------------------
    $display("\n=== Phase 1: esr_prefetch_start, cycle %0d ===", cyc);
    tb_phase = 1;
    prefetch_start(FIRST_LINE, NUM_LINES);

    while (fault_cyc < 0 && cyc < 2000) tick();
    if (fault_cyc < 0) begin
      $display("ERROR no fault on line %0d seen", LAST_LINE);
      $finish;
    end
    // Give a correct FSM time to finish
    while (cyc < fault_cyc + WAIT_CYCLES && done_rise_cyc < 0) tick();
    repeat (5) tick();
    state_after_p1        = dut.f0_prefetch_state;
    fill_done_after_fault = 0;
    foreach (fill_done_cyc[k]) if (fill_done_cyc[k] > fault_cyc) fill_done_after_fault++;
    $display("  cyc %4d: end of phase 1, state %s, lines %0d, esr_prefetch_done %0d",
             cyc, dut.f0_prefetch_state.name(), dut.f0_prefetch_lines, esr_prefetch_done);

    // ---- Phase 2: one fill done from a minion fetch ----------------------
    $display("\n=== Phase 2: M0 fetches line %0d, cycle %0d ===", MINION_LINE, cyc);
    tb_phase            = 2;
    fill_done_before_p2 = fill_done_cyc.size();
    lookups_before_p2   = pf_lookups.size();
    minion_fetch(MINION_LINE);
    repeat (60) tick();

    // ---- Report ----------------------------------------------------------
    $display("\n  %-5s %-5s %-12s %-6s %-4s %-6s", "cyc", "line", "PA", "lines", "TLB", "result");
    foreach (pf_lookups[k])
      $display("  %-5d %-5d 0x%010h %-6d %-4s %-6s", pf_lookups[k].t, line_of(pf_lookups[k].pa),
               pf_lookups[k].pa, pf_lookups[k].lines, pf_lookups[k].tlb_miss ? "miss" : "hit",
               pf_lookups[k].l0_miss ? "L1" :
               (pf_lookups[k].page_fault || pf_lookups[k].access_fault) ? "fault" : "retry");
    $display("");

    // Sanity: the burst runs as described in the header
    check("PTW walks (bare mode)",                                 ptw_walks, 0);
    check("L1 requests for line 62",                               l1_log_pa.size() >= 1 && l1_log_pa[0] == line_va(FIRST_LINE), 1);
    check("L1 requests for line 63",                               l1_log_pa.size() >= 2 && l1_log_pa[1] == line_va(FIRST_LINE+1), 1);
    check("line 64: prefetch lookups before phase 2",              lookups_of(LAST_LINE), 1);
    check("line 64: TLB miss on the faulting lookup (0 = hit)",    pf_lookups[lookups_before_p2-1].tlb_miss, 0);
    check("line 64: access fault",                                 pf_lookups[lookups_before_p2-1].access_fault, 1);
    check("line 64: pending-line counter in F2 (last line)",       pf_lookups[lookups_before_p2-1].lines, 0);
    check("f5_resp_fill_done after the fault, phase 1",            fill_done_after_fault, 0);

    // The defect checks
    $display("");
    check("pending-line counter after the fault on the last line", lines_after_fault, 0, 1);
    check("prefetch FSM state at end of phase 1 (0 = Idle)",       state_after_p1, icache_prefetch_state_Idle, 1);
    check("esr_prefetch_done rose after the fault",                done_rise_cyc >= 0, 1, 1);
    check("prefetch lookups outside lines 62..64",                 lookups_outside(FIRST_LINE, LAST_LINE), 0, 1);

    $display("\n================================================");
    if (errors != 0)
      $display("TEST INVALID, %0d sanity error(s)", errors);
    else if (defects != 0)
      $display("TEST FAILED: fault on the last line wraps the counter to %0d, next PA 0x%010h (line %0d)",
               lines_after_fault, next_pa_after_fault, line_of(next_pa_after_fault));
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
