# L0 micro-cache 2 MB superpage alias testbench (Verilator)
#   make        build and run
#   make wave   open the waveform in GTKWave (runs the test first if needed)
#   make clean  remove build outputs

REPOROOT ?= $(abspath ../../..)
RTLROOT  ?= $(REPOROOT)/rtl
export REPOROOT RTLROOT

TB   := icache_l0_superpage_alias_tb
MDIR := obj_dir/$(TB)

VFLAGS := --binary --timing --trace --trace-structs --timescale 1ns/1ps -j 12 \
          -Wno-fatal -Wno-lint -Wno-style -Wno-MULTITOP -Wno-MULTIDRIVEN \
          -Wno-TIMESCALEMOD -Wno-PINMISSING

VFILES := -f $(RTLROOT)/shire/neigh/neigh_top_rtl.f \
          -f $(RTLROOT)/shire/neigh/neigh_top_vcs_defines.f \
          -f $(RTLROOT)/shire/neigh/neigh_channel_hm_behav.f \
          -y $(RTLROOT)/shire/shire_channel/icache \
          +incdir+$(RTLROOT)/inc +incdir+$(REPOROOT) +libext+.v+.sv \
          $(CURDIR)/$(TB).sv $(CURDIR)/icache_l0_superpage_alias_dump.sv

VCD  := $(TB).vcd
GTKW := $(TB).gtkw

.PHONY: all run build wave clean
all: run

build:
	mkdir -p $(MDIR)
	verilator $(VFLAGS) --Mdir $(MDIR) -o simv $(VFILES) > build.log 2>&1 || (tail -40 build.log; exit 1)

run: build
	./$(MDIR)/simv | tee simv.log

$(VCD):
	$(MAKE) run

wave: $(VCD)
	gtkwave $(VCD) $(GTKW) > /dev/null 2>&1 &

clean:
	rm -rf obj_dir build.log simv.log $(TB).vcd
