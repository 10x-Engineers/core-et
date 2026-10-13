# Copyright (c) 2026 Ainekko
# SPDX-License-Identifier: Apache-2.0
#
# Standalone simulation of icache_micro_cache driven by icache_micro_cache_tb.
#
# Every target takes TB=<testbench module> (the .sv suffix is optional):
#   icache_micro_cache_tb         prefetch FSM lost-request directed test
#   icache_micro_cache_simple_tb  two minion misses then a prefetch
#   neigh_shared_icache_tb        shared icache: two minions miss, sleep and retry
#
# Open-source flow (default):
#   make TB=<tb>           build with Verilator and run, writes <tb>.vcd
#   make TB=<tb> waves     open <tb>.vcd in GTKWave (runs the sim first if needed)
#   make TB=<tb> lint      Verilator lint of the testbench and DUT
# Commercial flow:
#   make TB=<tb> vcs       build with VCS and run (needs vcs on PATH)
#
# REPOROOT and RTLROOT default to this checkout so no environment is needed.
#
# Icarus Verilog is not supported: the DUT and its headers use struct
# assignment patterns, "inside" set membership and SVA properties that
# iverilog 12 rejects. Verilator compiles the same RTL unchanged.

REPOROOT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
RTLROOT  ?= $(REPOROOT)/rtl
export REPOROOT RTLROOT

BUILD_DIR ?= .

# Piped recipes (tee) must still fail when the tool fails
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

all: sim

DESIGN    := icache_micro_cache
TEST_DIR  := $(REPOROOT)/dv/standalone/$(DESIGN)

# TB is required. A path or a .sv suffix is tolerated so tab completion works.
ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(strip $(TB)),)
$(error TB is not set. Use: make TB=icache_micro_cache_simple_tb [sim|waves|lint|vcs])
endif
endif
override TB := $(basename $(notdir $(TB)))
TB_TOP    := $(TB)
DUMP_TOP  := $(DESIGN)_dump
BUILD_LOG := $(BUILD_DIR)/build.log
SIMV_LOG  := $(BUILD_DIR)/simv.log
VCD       := $(BUILD_DIR)/$(TB).vcd
GTKW      := $(TEST_DIR)/$(TB).gtkw

# ET_USE_ASIC_MEMS is deliberately left undefined so the generic behavioural
# models under rtl/libs/rf_latches are used for the micro tag and micro data
# arrays.
# No concurrent assertions in this testbench; the lost-request check is procedural.

# neigh_top_rtl.f brings in libs (rf_latch_1r_1w_par, rf_latch_1r_1w_dec),
# neigh_channel (-y over shire/neigh/icache), esr and minion (tlb_top).
# The .f files reference $RTLROOT, which both VCS and Verilator expand.
# neigh_channel_hm_behav.f adds the behavioural models of the hard macros
# (icache_tag_data_array, icache_lru_state_array) that icache_top needs.
FILE_LIST := -f $(RTLROOT)/shire/neigh/neigh_top_rtl.f \
             -f $(RTLROOT)/shire/neigh/neigh_top_vcs_defines.f \
             -f $(RTLROOT)/shire/neigh/neigh_channel_hm_behav.f \
             +incdir+$(RTLROOT)/inc +incdir+$(REPOROOT) +libext+.v+.sv

TB_SRCS   := $(TEST_DIR)/$(TB_TOP).sv

# ---------------------------------------------------------------------------
# Verilator + GTKWave
# ---------------------------------------------------------------------------
VL_DIR    := $(BUILD_DIR)/obj_dir/$(TB)
VL_SIMV   := $(VL_DIR)/simv
VL_JOBS   ?= $(shell nproc 2>/dev/null || echo 4)

# --timing      testbench uses #delays and @(posedge clock)
# --trace       enables $dumpvars in icache_micro_cache_dump (VCD)
# MULTITOP      icache_micro_cache_dump is a deliberate second top
# MULTIDRIVEN   rf_latch write and reset blocks on different clocking, by design
# TIMESCALEMOD  only the testbench carries a timescale
VL_OPTS   := --binary --timing --trace --trace-structs \
             --timescale 1ns/1ps -j $(VL_JOBS) \
             -Wno-fatal -Wno-lint -Wno-style \
             -Wno-MULTITOP -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
             +define+TB_TOP=$(TB_TOP) $(DEFINES)

VL_SRCS   := $(FILE_LIST) $(TB_SRCS) $(TEST_DIR)/$(DUMP_TOP).sv

$(VL_SIMV): FORCE
	mkdir -p $(VL_DIR)
	verilator $(VL_OPTS) --Mdir $(VL_DIR) -o simv $(VL_SRCS) 2>&1 | tee $(BUILD_LOG)

verilate: $(VL_SIMV)

sim: $(VL_SIMV)
	cd $(BUILD_DIR) && ./obj_dir/$(TB)/simv +dumpfile=$(TB).vcd $(PLUSARGS) 2>&1 | tee simv.log
	@echo "Waveform written to $(VCD)"
	@echo "View it with:  make TB=$(TB) waves   (or: gtkwave $(VCD))"

# Opens the saved signal layout when one exists next to the testbench.
# Save your own with File > Write Save File in GTKWave.
waves: $(VCD)
	gtkwave $(VCD) $(wildcard $(GTKW)) &

$(VCD):
	$(MAKE) sim

# Reports every warning but never fails: the pre-existing width and case
# findings in tlb_top.v and uc_types.vh belong to the RTL, not to this test.
lint:
	verilator --lint-only --timing --timescale 1ns/1ps -Wno-fatal \
	  -Wno-MULTITOP -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD +define+TB_TOP=$(TB_TOP) $(DEFINES) \
	  $(VL_SRCS)

# ---------------------------------------------------------------------------
# VCS (legacy flow)
# ---------------------------------------------------------------------------
TRACE := -kdb -lca -debug_access+all
TRACE += +vcs+fsdbon # verdi -ssf novas.fsdb &
TRACE += +vcs+vcdpluson # dve -full64 -vpd vcdplus.vpd

VCS_OPTS := -sverilog -full64 $(DEFINES) $(TRACE) -timescale=1ns/1ps +lint=PCWM

$(BUILD_DIR)/simv: FORCE
	vcs $(VCS_OPTS) $(TB_SRCS) $(FILE_LIST) -o $(BUILD_DIR)/simv -Mdir=$(BUILD_DIR)/csrc > $(BUILD_LOG)

vcs: $(BUILD_DIR)/simv
	$(BUILD_DIR)/simv | tee $(SIMV_LOG)

# slang version 9.1.214+68cad5ea0
# export PATH="/home/alilic/tools/slang/build/bin:$PATH"
slang:
	slang --top $(TB_TOP) $(TB_SRCS) +incdir+$(RTLROOT)/inc +libext+.v+.sv \
	  $(RTLROOT)/shire/neigh/icache/*.v \
	  -Wno-unconnected-port -Wno-duplicate-definition --std 1800-2017 --error-limit=1000

FORCE:

.PHONY: all FORCE verilate sim waves lint vcs slang clean

clean:
	rm -rf $(BUILD_DIR)/obj_dir $(BUILD_DIR)/*.vcd $(BUILD_DIR)/csrc/ $(BUILD_DIR)/simv $(BUILD_DIR)/simv.daidir/ $(BUILD_DIR)/verdi_config_file $(BUILD_DIR)/DVEfiles/ $(BUILD_DIR)/dve_report* $(BUILD_DIR)/novas* $(BUILD_DIR)/ucli.key $(BUILD_DIR)/vcdplus.vpd $(BUILD_DIR)/novas.fsdb $(BUILD_DIR)/verdiLog/ $(SIMV_LOG) $(BUILD_LOG)
