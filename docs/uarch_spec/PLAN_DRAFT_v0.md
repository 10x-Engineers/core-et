# ET-Minion CPU Subsystem (ET-SoC-1 lineage): Micro-Architecture Reference: Documentation Plan

Status: **DRAFT PLAN**. No chapter content has been written yet.
Working sources: `docs/u_arch/*.pdf`, `docs/arch/*.pdf` (extracted to text under `docs/gen_doc/extracted/`), `rtl/`, `rtl/shire/esr/scripts/systemRDL/*.rdl`, `rtl/shire/minion/intpipe/csr/semifore/minion_csr.csr`.

---

## 0. Findings from the source survey that shape this plan

| # | Finding | Evidence | Consequence for the document |
|---|---------|----------|------------------------------|
| 1 | The RTL top is **`cpu_subsystem_top`**, the *Erbium CPU Subsystem*: **one** Neighborhood (8 Minions × 2 harts) plus ETL2AXI bridge, PLIC, CLINT, FLB, FCC, CPU ESRs, and an external L1 ICache SRAM. | `rtl/cpu_subsystem/cpu_subsystem_top.v`, `README.md` | The document is organized around the implemented hierarchy (CPUSS → Neigh → Minion). ET-SoC-1 shire-level blocks are covered as context (see #2). |
| 2 | There is **no RTL** for the Shire Cache (L2/L3/SCP), Mesh NoC, Shire Channel/UC in its ET-SoC-1 form, Memshire, IOShire or Maxion. The four SC bank ports plus the UC port of the Neighborhood are OR-merged into one ET-Link port that feeds `cpu_etl2axi_top`. | `cpu_subsystem_top.v` (`neigh_sc_req_valid[SC_BANKS:0]`) | The Shire Cache spec (131 pp) and Shire description can only be carried over from documentation. Part VII covers them and marks them "not implemented in this RTL". **Scope decision needed (Q1).** |
| 3 | Several Neighborhood features are **present in RTL but tied off** in the CPUSS: inter-neighborhood cooperative TensorLoad buses, TBOX ids/enables, power-control sleep/isolate, voltage monitors, DFT scan. | `cpu_subsystem_top.v` port map (`'0`/`'1`, `*_unused_ok`) | Each such feature is documented with an "Active in CPUSS?" note, plus its tie-off value and resulting behavior. |
| 4 | Two TXFMA implementations exist (`txfma_6s`, `txfma_7s`). Only **`txfma_7s`** is in the filelist. `txfma_top_fake` is selected by `USE_FAKE_TXFMA`. | `rtl/shire/minion/vpu/txfma_rtl.f`, `vpu_txfma_trans_top.v` | Document the 7-stage TXFMA only. Legacy docs describe F0–F8 VPU staging, so the stage count must be reconciled against the 7s RTL. |
| 5 | CPUSS-only blocks (**ETL2AXI, CLINT, PLIC, APB mux, CPU power-down handshake**) have **no legacy micro-architecture document**. The only existing material is the `cpuss_diagram.png` figure. | `docs/u_arch/cpu_subsystem/images/` | These chapters are derived from RTL alone, and they carry the highest risk of error. |
| 6 | Register maps have machine-readable sources: SystemRDL (`esr.rdl`, `neigh.rdl`, `cpu.rdl`, `hart.rdl`, `plic.rdl`, plus a generated `esr.md`) and the CSR `.csr` database. | `rtl/shire/esr/scripts/systemRDL/`, `intpipe/csr/semifore/` | Register appendices are generated or derived from these sources, not copied from the PDFs. |
| 7 | The ESR map in RDL is "Erbium_ESR" (U/S/D/M × neigh/cpu/hart regions). It differs from the ET-SoC-1 shire ESR map in the PRM. | `systemRDL/doc/esr.md` | The memory-map chapter follows the RDL. PRM differences go into the discrepancy register. |
| 8 | The legacy docs cross-reference documents that are **not** in the repo (Shire Bus Master spec, UC spec, Debug HLS, MAS Minion Shire Debug, DFT spec). | Reference lists in the PDFs | Gaps are recorded explicitly. Content is reconstructed from RTL where possible. |
| 9 | The existing drawio figure (`docs/diagrams/FrontEnd_L0uCache.drawio`) models the Frontend as stages **F0–F7** (thread buffers, 2:1 LRU arbiter, RVC expander, bypass mux, decoders). | drawio labels | It is reused and extended for Chapter 6. |

---

## 1. Document conventions (apply to every chapter)

### 1.1 Standard per-module template
Every *significant module* section follows this skeleton. Sub-items that do not apply are stated as "N/A" with a reason, never silently omitted.

1. **Purpose & rationale.** What the module is, why it exists, and what problem it solves.
2. **Position in the hierarchy.** Instance path, RTL files, parent and children, and whether it is active in the CPUSS.
3. **Block diagram.** Internal structure (drawio → SVG).
4. **External interface.** The I/O signal table (§1.2) grouped by interface, plus an interface diagram.
5. **Data structures.** Struct and packet tables (§1.3).
6. **Micro-architecture.** Datapath, control, and pipeline stages: pipeline diagram, per-stage actions table.
7. **Buffering & queueing.** Every FIFO or queue: depth, width, entry format, full/empty/almost-full policy.
8. **Arbitration & scheduling.** Arbiter type (LRU/RR/priority), requesters, fairness, starvation analysis.
9. **State machines.** State diagram, state table, transition conditions, outputs per state.
10. **Handshake, backpressure & flow control.** Valid/ready or credit rules, and ready propagation (combinational or registered).
11. **Timing diagrams.** WaveDrom scenarios: normal, backpressure, stall, full/empty, flush, reset, error, and relevant corner cases.
12. **Hazards, ordering & corner cases.**
13. **Reset behavior.** Reset domain, per-register reset values, and post-reset idle state.
14. **Clocking & power.** Clock gates, clock-gate-disable ESR bits, and voltage domain.
15. **Configuration & programming.** CSRs/ESRs that affect the block, programming sequences, and chicken bits.
16. **Errors & exceptions.** ECC, access faults, bus errors, logging, and reporting.
17. **Performance.** Latency, throughput, bottlenecks, and PMU events.
18. **Firmware notes.** Required sequences, restrictions, and relevant errata.
19. **Verification notes.** Key checks and assertions, coverage points, known tricky scenarios, and observable debug state.
20. **Doc-vs-RTL discrepancies.** Local list, also mirrored in Appendix D.

### 1.2 Signal-table columns
`Signal | Dir | Width / type | Clock / domain | Reset value | Description | Valid when | Handshake / timing | Dependencies & corner cases`

### 1.3 Structure-table columns
`Field | Bits | Width | Meaning | Producer | Consumer | Valid when | Usage | Encoding / special values`

### 1.4 Source tagging
Each non-trivial claim carries one of three provenance tags:
- **[RTL]**: verified in RTL.
- **[DOC]**: from legacy documentation, consistent with RTL or not checkable.
- **[DOC≠RTL]**: legacy documentation disagrees with RTL. The implemented behavior is stated, with evidence.

The tags are kept as small margin markers so they don't clutter the text.

### 1.5 Figure tooling (proposal)
- Block, data-flow, and state diagrams are authored in **draw.io** (`docs/diagrams/*.drawio`) and exported to SVG.
- Timing diagrams are authored in **WaveDrom** (`docs/diagrams/wave/*.json`) and rendered to SVG.
- Pipeline diagrams are tables or drawio figures.
- Figures from the legacy PDFs are reused where they are still accurate, either extracted as images or redrawn.

---

## 2. Proposed document structure

Legend for each section: **Covers** = RTL modules; **Topics** = micro-architecture topics; **F** = figures; **W** = waveforms; **T** = tables.

### Front matter
- **FM.1** Title, revision history, and status of each chapter.
- **FM.2** Scope: what is and is not implemented in this RTL, and the relationship between ET-SoC-1 and Erbium.
- **FM.3** Audience and reading guide: suggested reading paths for RTL, DV, firmware, and newcomers.
- **FM.4** Conventions: the §1 rules, signal-prefix conventions (stage prefixes `f0_…`, `ex_…`, `id_…`), bus and struct naming, and diagram legend.
- **FM.5** Legacy-document supersession matrix. Every section of every legacy PDF is mapped to the section of this document that replaces it. This matrix is the gate for deleting the old docs.

---

### PART I: SYSTEM CONTEXT & FOUNDATIONS

#### Chapter 1: Introduction & System Overview
- **1.1 ET-SoC-1 in brief.** Covers the 34 compute shires, master shire, Maxions, Memshire, IOShire/Service Processor, mesh NoC, and PCIe card. This is context only. F: SoC hierarchy.
- **1.2 The Erbium CPU Subsystem.** What this RTL is, how it is derived from an ET-SoC-1 Minion Shire, and what was removed or replaced (Shire Cache → ETL2AXI; UC → FLB/FCC; CLINT and PLIC added; ICache data RAM moved outside the Neighborhood). T: ET-SoC-1 shire vs Erbium CPUSS feature comparison.
- **1.3 Hierarchy and instance map.** Instance tree down to leaf units. T: module → file → instance path → one-line role → active in CPUSS?
- **1.4 Key parameters.** T: harts, minions, VPU lanes, cache geometries, ET-Link widths, AXI widths, and address widths, each with its `define` name and value.
- **1.5 End-to-end walkthroughs** for newcomers. Each is a sequence diagram:
  - Instruction fetch: hit in L0, miss to L1, miss to AXI.
  - Scalar load: hit and miss.
  - Store and write-through.
  - TensorLoad.
  - Atomic.
  - FLB barrier.
  - Interrupt delivery.
- **1.6 Clock, reset, voltage and power domains at a glance.** F: domain map.

#### Chapter 2: Architectural Foundations (the programmer-visible model the micro-architecture implements)
- **2.1 ISA baseline and extensions.** Covers RV64IMFC, Zicsr and Zifencei, plus the Esperanto extensions: PS, PI, Mask, Atomic, Cache-control, Tensor, FLB, FCC, code prefetch, and IPI. T: instruction class → executing unit(s) → pipeline path → scoreboard used.
- **2.2 Harts and privilege.** Covers M/S/U modes, trap delegation, and custom exception causes (instruction bus error, instruction ECC error, split-page fault, and others). T: cause codes → originating unit.
- **2.3 Memory model.** Non-coherent L1, ordering rules, fences, cache-control semantics, write-through vs write-back, and uncacheable regions.
- **2.4 Memory map.** Covers the CPUSS address space as seen by a Minion and by AXI/APB, and the ESR region layout (U/S/D/M × neigh/cpu/hart). T: region map. Differences from the ET-SoC-1 PRM map are recorded in Appendix D.
- **2.5 Virtual memory.** Covers the supported modes, PTW placement, MPROT, and VMSPAGESIZE, plus errata 1.6.
- **2.6 Interrupt model.** Covers MEIP/SEIP (PLIC), MTIP (CLINT), MSIP/IPI, IPI redirect PC, and the interrupt → hart mapping.

#### Chapter 3: On-Chip Protocols & Common Interface Conventions
- **3.1 Handshake conventions.** Covers valid/ready, `valid_early`, credits, pulse vs level, and multi-cycle transfers. W: basic valid/ready, back-to-back, backpressure.
- **3.2 ET-Link protocol.** Replaces the ET-Link spec. Topics:
  - Request and reply channels, and multiple handshake pairs.
  - id/source/dest fields and multi-cycle requests and replies.
  - Operations: Read, Write, WriteAround, Cooperative Read, Messages (message ID), Atomics, and CacheOps (Flush, FlushToMem, Evict, EvictToMem, Lock/Unlock, ScpFill, Prefetch).
  - Error responses.
  - T: `et_link_req_info_t`, `et_link_rsp_info_t`, `et_link_neigh_req_info_t`, and opcode encoding tables.
  - W: read, multi-beat write, atomic, cacheop, error reply, and backpressure on each channel.
- **3.3 Frontend ↔ ICache bus.** Request and response channels and fill-done broadcast. T: structs. W: hit, miss/fill, and livelock scenario.
- **3.4 Minion ↔ Neighborhood side-band interfaces.** PTW, FLB, FCC, IPI, PMU, messages, and TBOX (overview; details in their own chapters).
- **3.5 APB fabric.** The APB tree (external → CPUSS mux → neigh mux → per-minion debug slave), address decode, PSLVERR rules, and CDC/voltage crossing. F: APB tree. W: read/write/error.
- **3.6 AXI4 master interface** (summary; details in Ch 22).

---

### PART II: THE ET-MINION CORE

#### Chapter 4: Minion Overview
- **Covers:** `minion_top`, `core_top`, `minion_debug_apb_slv`, `pseudo_lru`, `tlb_top`.
- **Topics:**
  - Dual-hart model and what is shared vs replicated per thread.
  - Unit partitioning: Frontend, Intpipe, DCache, VPU.
  - Global pipeline diagram joining all units: FE F0–F7 → ID/EX/GSC/TAG/MEM/WB → DCache S0–S5 → VPU stages.
  - Inter-unit interfaces, thread enable, feature bits, clock-gate domains, and reset fan-out (`rst_repeat`).
- **F:** Minion block diagram; unified pipeline chart.
- **T:** `minion_top` I/O (all groups); inter-unit interface list.
- **W:** Thread interleaving through the whole pipeline.

#### Chapter 5: Instruction Set Dispatch Model (short bridging chapter)
- Instruction groups, how each class flows through the units, and issue restrictions (thread 1 restrictions, VPU-only instructions, serializing instructions).
- T: instruction-group table derived from `instructions.vh` and the decoders.

#### Chapter 6: Frontend
- **Covers:** `frontend_top`, `frontend_thread_sched`, `frontend_thread_buffer`, `frontend_rvc_expander`, and the decode placement of `intpipe_decode` and `vpu_decoder`.
- **Topics:**
  - Why each hart has its own buffers, and the thread scheduler policy.
  - Thread buffer: entries, PC tracking, sequential prefetch of the next 32 B line, and entry states.
  - Request generation and the 2:1 LRU arbitration to the L0.
  - Stages F0–F7 in detail: response capture, instruction extraction across entry boundaries, the RVC expander and a compressed instruction split across lines, and the bypass mux.
  - Decode handoff and backpressure from ID.
  - Redirects: branch, trap, xRET, fence.i, and debug.
  - Fetch faults (access fault, ECC, page fault), including errata 1.20.
  - Debug-mode instruction injection (errata 1.19).
  - The ICache livelock mechanism and its fix.
  - Clock gating.
- **F:** Updated `FrontEnd_L0uCache.drawio`; thread-buffer structure; thread-buffer state diagram.
- **T:** I/O tables; thread-buffer entry fields; per-stage actions.
- **W:**
  - Straight-line fetch.
  - L0 hit / L0 miss with fill-done.
  - Thread alternation.
  - ID backpressure.
  - Branch redirect/flush.
  - Compressed instruction straddling a line.
  - Fetch exception.
  - Reset-vector fetch after reset.
  - Livelock scenario.

#### Chapter 7: Integer Pipeline (Intpipe)
- **Covers:** `intpipe_top`, `intpipe_decode`, `intpipe_inst_bits_stage`, `intpipe_imm`, `intpipe_rf`, `intpipe_alu`, `intpipe_int_scoreboard`, `intpipe_fp_scoreboard`, `intpipe_mask_scoreboard`, `intpipe_mul_div*`, `debug_breakpoint`.
- **Topics:**
  - **7.1 Stage overview.** ID, EX, GSC, TAG, MEM, WB, and why the GSC and TAG stages exist.
  - **7.2 Decode and instruction groups.**
  - **7.3 Register file.** Latch-based design, ports, and write-back arbitration between the int, DCache, and VPU sources.
  - **7.4 Bypass/forwarding network.**
  - **7.5 Scoreboards.** Int, FP, and mask scoreboards: entry format, set/clear sources, and how long-latency VPU/DCache results are tracked. Includes errata 1.21.
  - **7.6 Stall conditions.** ID stalls, CSR replay stalls, and VPU internal stalls. T: full stall-cause matrix.
  - **7.7 ALU, branch resolution and redirect.**
  - **7.8 MulDiv unit.** Interface, control FSM, datapath (Wallace tree, iterative divide), latency, and early termination.
  - **7.9 Gather/scatter sequencing.** Includes `gsc_progress` and errata 1.3.
  - **7.10 Traps.** Exceptions, interrupts, trap entry, xRET, WFI, and precise-exception guarantees. Includes misaligned accesses (errata 1.15, 1.16).
  - **7.11 Thread 1 restrictions.**
  - **7.12 Instruction clock gating.**
  - **7.13 Hardware breakpoints/triggers.** Includes errata 1.13.
- **F:** Intpipe block diagram; scoreboard structure; MulDiv FSM.
- **T:** I/O; the pipeline register contents per stage.
- **W:** Back-to-back dependent ops with bypass; load-use stall; MulDiv multi-cycle; CSR replay; branch mispredict/redirect; exception flush; interrupt taken; thread interleave stall.

#### Chapter 8: CSR File, Hart Control & Performance Counters
- **Covers:** `intpipe_csr_file`, `intpipe_csr_file_auto`, `intpipe_csr_file_conv`, `intpipe_csr_file_fl_barrier`, `intpipe_csr_pmu_read_interface`, `intpipe_csr_replay`.
- **Topics:**
  - CSR access pipeline and the replay mechanism, and why CSRs replay.
  - Side-effecting CSRs: tensor_*, mcache_control, flb, fcc, and message ports.
  - Per-thread vs shared CSRs.
  - CSR ↔ ESR relationships.
  - HPM counters and events. Includes errata 1.12, 1.22 and 1.23.
- **T:** Full custom-CSR summary: address, privilege, fields, reset, side effects, and owning unit (details in Appendix B).
- **W:** CSR read, CSR write with side effect, and replay.

#### Chapter 9: L1 Data Cache
- **Covers:** `dcache_top` and all `dcache_*` units, `tlb_top`, `pseudo_lru`.
- **Topics:**
  - **9.1 Overview & organization.** 4 KB; 16 sets × 4 ways × 64 B; the shared, split, and scratchpad (SCP) modes and switching between them (`mcache_control`); non-coherence.
  - **9.2 Interfaces.** Pipeline, CSR, VPU (scratchpad read, TensorReduce/Store/Load), TLB/PTW, ET-Link, APB, errors, and debug. T: an I/O table for each.
  - **9.3 Pipeline stages S0–S5.** Per-stage actions, arbitration into S0 (pipeline, replay, fills, tensor, cacheops), and hazards.
  - **9.4 Arrays.** Data, metadata/tag, LRU, and buffer array; the latch macro `dcache_128x32_1r1w_lram`. T: metadata entry format.
  - **9.5 Address translation.** TLB array, PMA unit (checks and attributes), split-page handling, and the PTW request path.
  - **9.6 Miss handler.** Allocation policy, number of entries, FSM, fill merging, and ordering with in-flight stores.
  - **9.7 Replay queue.** Why misses/conflicts replay rather than block; entry format; wake-up conditions; starvation avoidance.
  - **9.8 Store path.** Store merge unit and writeback unit (evictions, write-through vs write-back).
  - **9.9 Atomics.** Local vs global (L2/UC) atomic paths and the atomic ALU. Includes errata 1.28.
  - **9.10 Scratchpad controller.**
  - **9.11 CacheOps FSM and CacheOps-L2 FSM.** Flush, evict, lock, unlock, prefetch, and the tensor-mask interaction (errata 1.26, 1.4).
  - **9.12 TensorLoad engines TL0/TL1.** Control FSM, request control FSM, the stride/overflow check (errata 1.7), cooperative mode, and TensorLoadSetupB (errata 1.2).
  - **9.13 TensorReduce** (`dcache_reduce`). Send and receive, and the message network use.
  - **9.14 Ordering, fences, and interaction with the scoreboard.**
  - **9.15 Errors, ECC, and access faults.** Debug APB access to internal state.
  - **9.16 Performance.** Hit latency, miss penalty, and MSHR limits.
- **F:** DCache block diagram; pipeline; miss-handler FSM; replay flow; TL FSMs; CacheOps FSMs.
- **T:** All request/response structs from `dcache_types.vh`.
- **W:**
  - Load hit.
  - Load miss → fill → replay.
  - Store hit/miss.
  - Replay-queue full backpressure.
  - Eviction.
  - Atomic.
  - Split-page access.
  - TLB miss → PTW.
  - TensorLoad burst.
  - CacheOp flush.
  - ECC error.
  - Mode change.

#### Chapter 10: Vector Processing Unit (VPU)
- **Covers:** `vpu_top`, `vpu_ctrl`, `vpu_decoder`, `vpu_uinst_decoder`, `vpu_lane`, `vpu_rf`, `vpu_bypass`, `vpu_sh_sw`, `vpu_lane_tima`/`tima_*`, `vpu_txfma_trans_top`, `txfma_7s/*`, `vpu_trans`/`trans_unit/*`, `vpu_mask`, `vpu_ml`, `vpu_tensorfma`, `vpu_tensorquant`, `vpu_tensorreduce`, and `vpu_tensor{a,b,c,tmp}_rf`.
- **Topics:**
  - **10.1 Overview.** 8 lanes × 32 b; FP registers widened to 256 b; ctrl vs lane partitioning.
  - **10.2 Pipeline.** Stages as implemented (reconciled against the documented F0–F8), issue from the intpipe, and writeback.
  - **10.3 Decode & micro-op sequencing.**
  - **10.4 Register files.** VPURF 3R2W macro, port allocation, and the timing path (errata 1.29, workaround types A–G).
  - **10.5 Bypass network.**
  - **10.6 TXFMA** (7-stage): FP32 FMA, FP16A32, int multiply, compare/convert, denormal handling, exception flags, and rounding.
  - **10.7 INT short/swizzle unit.**
  - **10.8 TIMA.** Int8 multiply-accumulate; scalar vs vector TIMA lanes.
  - **10.9 Transcendental unit.** Sequencer, ROM tables, and the FRCP, FLOG, FEXP, rsqrt and sin algorithms; FRCP_FIX.RAST.
  - **10.10 Load/store, gather/scatter, and VPU atomics.** Includes errata 1.8.
  - **10.11 Mask unit and mask registers.**
  - **10.12 ML units.** TensorFMA (A/B/C/tmp RF usage and the pairing with TensorLoad), TensorQuant (errata 1.11), TensorStore, and TensorReduce send/receive. Includes tensor_mask and conv (errata 1.10, 1.25).
  - **10.13 Scoreboards.** FP, FP2INT, trans, and mask.
  - **10.14 Instruction latency & throughput.**
  - **10.15 Clock gating, reset (errata 1.14), and debug.**
- **F:** VPU block diagram; lane datapath; TXFMA stage diagram; TensorFMA dataflow (A × B → C accumulation over the RFs); trans sequencer FSM.
- **T:** Structs from `vpu_types.vh`, `trans_types.vh`, and `fp_types.vh`; the latency table; the rounding tables.
- **W:** Packed FMA issue/writeback; bypassed dependent op; transcendental sequence; TensorFMA waiting on TensorLoad B; TensorReduce send/receive; mask update.

---

### PART III: THE NEIGHBORHOOD

#### Chapter 11: Neighborhood Overview & Integration
- **Covers:** `neigh_top`, `neigh_channel`, `neigh_top_pwrstub`, `neigh_hi_voltage_cross`, `neigh_lo_voltage_cross`, and `neigh_hv_logic_*`.
- **Topics:**
  - Why 8 Minions share resources.
  - Block diagram and physical layout.
  - The high/low voltage split and what crosses it.
  - Power stub and isolation.
  - `neigh_top` I/O (125 ports, grouped by interface).
- **F:** Neighborhood block diagram; voltage-crossing diagram.
- **T:** I/O tables, including the CPUSS tie-off column.

#### Chapter 12: Shared Instruction Cache (L0 micro-caches + L1 ICache)
- **Covers:** `neigh_shared_icache`, `icache_top`, `icache_micro_cache`, `icache_micro_{tag,data}_array`, `icache_{tag,data,lru,tlb}_array`, `icache_pma_unit`, and the CPUSS-side `icache_data_ram_wrap` and `icache_mems`.
- **Topics:**
  - Two L0s (16-way fully associative, each shared by 4 Minions) over one 32 KB L1 (128 sets × 4 ways × 64 B).
  - Arbitration pre-stage and the fixed-latency L0 response.
  - Miss path to L1 and then ET-Link; fill-done broadcast.
  - Prefetch (the ESR-triggered prefetch facility), bypass, TLB, and PMA.
  - The L1 data RAM outside the Neighborhood (async SRAM protocol).
  - LRU policy.
  - ECC, error logging and reporting (ICACHE_ERR_* ESRs), BIST, and APB debug access (errata 1.24).
  - External configuration.
- **F:** ICache hierarchy; L0 pipeline; L1 pipeline.
- **T:** Tag entry format; error-log formats.
- **W:** L0 hit; L0 miss/L1 hit; L1 miss/ET-Link fill; simultaneous L0 requests; prefetch; ECC error.

#### Chapter 13: Neighborhood Memory Request/Response Datapath
- **Covers:** `neigh_channel` request/response logic, `neigh_miss_ff`, `neigh_evict_ff`/`_unit`, `neigh_fill_ff`, `neigh_fill_fifo`, `bpam2minions`, `mux_etl_type_b`, and the arbiters.
- **Topics:**
  - Minion request datapath and the request arbiter (policy and fairness).
  - ET-Link request pre-processing (bank/UC routing, address hashing).
  - Intermediate and output FIFOs (depths and credits).
  - Output interface: the SC_BANKS+1 ports, and how they collapse to one port in the CPUSS.
  - Response datapath: input response, fill FIFO, and Minion response routing.
  - Ordering guarantees.
- **F:** Request and response datapath diagrams.
- **T:** FIFO inventory (depth, width, entry).
- **W:** Contention among 8 Minions; FIFO full backpressure; multi-beat fill response.

#### Chapter 14: Cooperative TensorLoad
- **Covers:** `neigh_coop_tload`, `neigh_coop_tload_ports`, `neigh_coop_tload_tag_table`, and the DCache TL cooperative mode.
- **Topics:**
  - Why coalescing helps.
  - Ready logic, slave and master datapaths, the tag table, and the ET-Link response.
  - Inter-neighborhood buses (tied off in CPUSS) and intra-neighborhood behavior.
  - `esr_shire_coop_mode`.
- **F:** Coop-TL flow; tag-table state.
- **W:** Coalesced load across N Minions.

#### Chapter 15: Cooperative TensorStore
- **Covers:** `neigh_tensor_store_buffer`, `neigh_tensor_store_buffer_block`.
- **Topics:** Buffering, coalescing, and flush.
- **W:** Tensor-store coalescing and drain.

#### Chapter 16: Shared Page Table Walker
- **Covers:** `neigh_shared_ptw`, `ptw_top`.
- **Topics:** Request arbitration from 8 DCaches and the ICache TLB, walk FSM, PTE checks, and errata 2.29 (Maxion-side; noted for context).
- **F:** Walk FSM.
- **W:** Multi-level walk; fault.

#### Chapter 17: Fast Local Messaging, Barriers, IPIs and Credit Counters (Neighborhood side)
- **Covers:** `neigh_local_message_network`, `neigh_fl_barrier`, `neigh_hv_logic_ipi`, `neigh_hv_logic_fcc`, and `neigh_hv_logic_uc_fcc`.
- **Topics:** Message network topology and use by TensorReduce, and errata 1.9. The FLB neighborhood level (L1 of the and/or tree) and the IPI trigger/redirect path.
- **W:** Barrier arrival and release; IPI.

#### Chapter 18: Neighborhood PMU
- **Covers:** `neigh_pmu`.
- **Topics:** The Minion interface, events, and power-saving considerations.
- **T:** Event table.

#### Chapter 19: TBOX Router & BPAM Access
- **Covers:** `neigh_tbox_router`, `neigh_hv_logic_bpam_rc_tbox_ack`, and `bpam2minions`.
- **Topics:** Purpose in ET-SoC-1 and the CPUSS tie-off state.

#### Chapter 20: Neighborhood ESRs, APB & Debug
- **Covers:** `esr_neigh`, `neigh_ch_apb_mux`, `neigh_ch_dbg`, and `apb_ff`.
- **Topics:** The ESR list (MINION_BOOT, MPROT, VMSPAGESIZE, IPI_REDIRECT_PC, HACTRL/HASTATUS, AND_OR_TREE, PMU_CTRL, NEIGH_CHICKEN, …) and the status-monitor signal selection.

---

### PART IV: CPU SUBSYSTEM INTEGRATION (Erbium)

#### Chapter 21: CPU Subsystem Top
- **Covers:** `cpu_subsystem_top`.
- **Topics:**
  - External I/O (AXI master, APB slave, IRQs, power control, resets, clocks).
  - Integration choices.
  - The power-down request/acknowledge protocol and the UPF isolation clamp behavior.
- **F:** Updated `cpuss_diagram`.
- **T:** Full I/O table.
- **W:** Power-down handshake with and without APB activity.

#### Chapter 22: ETL2AXI Bridge
- **Covers:** `cpu_etl2axi_top`, `cpu_etl2axi_trans_table`, `cpu_etl2axi_trans_table_bank`, `cpu_etl2axi_atomic`.
- **Topics:**
  - Mapping each ET-Link opcode to AXI.
  - Transaction table: entries, banks, ID allocation, and ordering.
  - Atomic emulation (read-modify-write over AXI, or AXI exclusive).
  - CacheOps and messages on AXI (unsupported ones and their error responses).
  - Burst formation and response reassembly.
  - Error mapping (RRESP/BRESP → ET-Link error) and errata 2.11.
- **F:** Bridge block diagram; transaction-table entry lifecycle FSM.
- **W:** Read; write; outstanding reads out of order; atomic; AXI backpressure; error.

#### Chapter 23: Uncacheable Synchronization Block: FLB & FCC
- **Covers:** `uncacheable_flb`, `uncacheable_fcc`.
- **Topics:**
  - The FLB counter array and the atomic increment/compare/release protocol.
  - FCC credit counters, the CREDINC0–3 registers, and wake-up.
  - Rationale vs memory-based barriers.
- **W:** FLB request/response; FCC credit increment and consume.

#### Chapter 24: CLINT
- **Covers:** `cpu_clint`, `cpu_clint_timer`, `cpu_clint_timer_sync_in/out`, `cpu_mtip_gen`.
- **Topics:** The 10 MHz timer domain and CDC, mtime/mtimecmp, `mtime_local_target` masking, and MSIP.
- **W:** Timer crossing; MTIP assertion and clear.

#### Chapter 25: PLIC
- **Covers:** `cpu_plic`, `ios_plic`.
- **Topics:** Sources, priorities, thresholds, claim/complete, and M and S context mapping onto 16 harts.
- **W:** IRQ → claim → complete.

#### Chapter 26: APB Mux, CPU ESRs & ICache Data RAM Wrapper
- **Covers:** `cpu_apb_mux`, `esr_shire_other`, `esr_clk_gate`, `icache_data_ram_wrap`, `icache_mems`, and `apb_esr_ff`.
- **Topics:** APB decode map, CPU-level ESRs (clock-gate controls, thread enables, feature bits, prefetch control, dmctrl, status monitor), and the ICache SRAM wrapper protocol.

---

### PART V: CLOCKS, RESETS, POWER & DFT

#### Chapter 27: Clocking
- Clock sources in the CPUSS, the clock-gating hierarchy, and the clock-gate-disable ESRs.
- CDC inventory, with the synchronizer type used at each crossing.
- **ET-SoC-1 DLL delay control and estimation.** From the two DLL documents, with applicability to Erbium marked.
- F: clock tree; T: CDC table.

#### Chapter 28: Reset
- Cold, warm and debug resets (`sys_gasket_reset`, `ndmreset`), synchronizers, reset repeaters, sequencing, and per-block reset domains.
- Errata 1.14 and 1.30.
- W: reset sequences.

#### Chapter 29: Voltage Domains & Power Control
- Hi/lo voltage crossing structures (vcfifo, level shifters, semisync registers), power switches and isolation, Minion power-down requests, and logical stubbing.

#### Chapter 30: Memories, ECC, BIST & DFT hooks
- Memory macro inventory, SECDED ECC, BIST/trim, OCC/scan hooks, and TDRs.

---

### PART VI: DEBUG, TRACE & PERFORMANCE

#### Chapter 31: Debug Architecture
- Covers:
  - The RISC-V debug-mode implementation in the Minion (halt/resume, debug CSRs, triggers).
  - Hart ESRs and HACTRL/HASTATUS.
  - And-or trees (errata 1.27).
  - The resume FSM (errata 1.18).
  - The debug APB slave and access to internal state (Frontend, DCache, VPU dumps).
  - The UltraSoC-style status monitor (`sm_*` ESRs).
- F: debug access paths. W: halt → resume.

#### Chapter 32: Performance Monitoring & Tuning Guide
- Minion HPM events, neighborhood PMU events, and how to read them (errata 1.22, 1.23).
- Performance model: key latencies and throughputs in one table, plus common bottlenecks.

---

### PART VII: ET-SoC-1 SHIRE-LEVEL COMPONENTS (reference; **not in this RTL**) — *pending Q1*

#### Chapter 33: Minion Shire Organization
- 4 Neighborhoods, the Shire Channel, UC block, shire ESRs, main and debug NoC, interrupts, clocks/PLL/DLL, and resets.
- Source: *CORE-ET Minion Shire Description*.

#### Chapter 34: Shire Cache (L2 / L3 / Scratchpad)
- Condensed from the 131-page specification. Covers:
  - Partitioning and address decode.
  - Xbars, banks, Reqq/Dataq, read buffer, atomic block, coalescing buffer, and rspmux.
  - The ag…dc cache pipeline, tags/state/replacement, RAMs, ECC, and scrubbing.
  - Per-operation flows.
  - Index CacheOp FSM, ESRs, error handling, and trace.
  - Shire Cache errata 3.1–3.6.

#### Chapter 35: Mesh NoC, Memshire & SoC Integration (summary)

---

### APPENDICES
- **A. RTL Building-Block Library.** Arbiters (LRU, RR, priority and their `_data`/`_delayed`/`_held` variants, each with a behavior table and waveform), FIFOs (`gen_fifo`, `gen_valid_ready_fifo`, `gen_shared_fifo`, push/pop), latch-based register files, synchronizers and CDC, voltage-crossing FIFOs, level shifters, clock gates and muxes, reset repeaters, ECC, and the FP library.
- **B. Register reference.**
  - B.1 Custom CSRs (from `minion_csr.csr`).
  - B.2 ESRs by region (from SystemRDL).
  - B.3 PLIC and CLINT maps.
  - Each entry lists fields, reset, access, and side effects.
- **C. Consolidated data-structure reference.** Every struct from `rtl/inc/*_types.vh`, grouped by interface.
- **D. Discrepancy register.** Each entry records legacy doc, section, doc claim, RTL behavior, evidence, and resolution.
- **E. Errata cross-reference.** Each Minion, Neighborhood and CPUSS-relevant erratum, mapped to the affected section, its root cause in the micro-architecture, and whether it is still present in this RTL.
- **F. Verification & firmware checklists.** Per-chapter key invariants, coverage points, and mandatory firmware sequences (boot, cache mode change, VM enable, and barriers).
- **G. Glossary.**
- **H. References and source traceability.** Maps each section to its RTL files and legacy document sections.

---

## 3. Proposed development order

The order puts foundations first, then follows the data path outward. Each step completes before the next begins.

1. Ch 3.2 ET-Link and Ch 3.1 handshake conventions. Almost every later chapter depends on them.
2. Ch 4 Minion overview → **Ch 6 Frontend** (a diagram already exists) → Ch 7 Intpipe → Ch 8 CSR.
3. Ch 9 DCache → Ch 10 VPU.
4. Ch 11–20 Neighborhood.
5. Ch 21–26 CPUSS.
6. Ch 27–32 Clocks/Reset/Power/Debug/Perf.
7. Ch 1–2 and front matter, written last so the summaries are accurate.
8. Part VII, if in scope.
9. Appendices, generated and filled as chapters complete. The discrepancy and errata registers grow as each chapter is written.

## 4. Open questions for the user
1. **Scope of Part VII:** Should the ET-SoC-1 Shire Cache, Shire and NoC material, which has no RTL here, be carried into the new document so the old PDFs can be deleted? Or should the document cover only the Erbium CPUSS RTL?
2. **Document title and naming:** Should it be "ET-SoC-1 Micro-Architecture" or "CORE-ET CPU Subsystem (Erbium) Micro-Architecture"? The RTL and README describe the latter.
3. **Output format:** Proposed: Markdown sources (one file per chapter under `docs/uarch/`) with drawio/WaveDrom SVG figures, assembled into one HTML/PDF. The alternative is a single monolithic Markdown file.
4. **Extracted PDF text:** Should the text under `docs/gen_doc/extracted/` be kept in the repo during the effort, or kept out of it?
