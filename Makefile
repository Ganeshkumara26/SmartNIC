# ============================================================================
# SmartNIC Simulation Makefile
# ============================================================================
# Targets:
#   make parser     - Compile & run Packet Parser testbench
#   make classifier - Compile & run Flow Classifier testbench
#   make queue      - Compile & run Queue Manager testbench
#   make scheduler  - Compile & run Scheduler + Queue Manager testbench
#   make all        - Run all testbenches
#   make clean      - Remove simulation artifacts
#
# Prerequisites: Icarus Verilog (iverilog, vvp) must be on PATH
# ============================================================================

# Tool configuration
IVERILOG = iverilog
VVP      = vvp
PYTHON   = python

# Directory layout
RTL_DIR  = rtl
TB_DIR   = tb
SIM_DIR  = sim
SCRIPT_DIR = scripts

# Include paths (for `include directives)
INC_FLAGS = -I$(RTL_DIR)/common

# Common RTL files
COMMON_RTL = $(RTL_DIR)/common/axi_stream_fifo.v

# ============================================================================
# Packet Parser
# ============================================================================
PARSER_RTL = $(RTL_DIR)/parser/packet_parser.v
PARSER_TB  = $(TB_DIR)/parser/tb_packet_parser.v

parser: $(SIM_DIR)
	$(IVERILOG) -o $(SIM_DIR)/parser_sim.vvp $(INC_FLAGS) \
		$(PARSER_RTL) $(PARSER_TB)
	cd $(SIM_DIR) && $(VVP) parser_sim.vvp

# ============================================================================
# Flow Classifier
# ============================================================================
CLASSIFIER_RTL = $(RTL_DIR)/classifier/flow_classifier.v
CLASSIFIER_TB  = $(TB_DIR)/classifier/tb_flow_classifier.v

classifier: $(SIM_DIR)
	$(IVERILOG) -o $(SIM_DIR)/classifier_sim.vvp $(INC_FLAGS) \
		$(CLASSIFIER_RTL) $(CLASSIFIER_TB)
	cd $(SIM_DIR) && $(VVP) classifier_sim.vvp

# ============================================================================
# Queue Manager
# ============================================================================
QUEUE_RTL = $(RTL_DIR)/queue/queue_manager.v
QUEUE_TB  = $(TB_DIR)/queue/tb_queue_manager.v

queue: $(SIM_DIR)
	$(IVERILOG) -o $(SIM_DIR)/queue_sim.vvp $(INC_FLAGS) \
		$(QUEUE_RTL) $(QUEUE_TB)
	cd $(SIM_DIR) && $(VVP) queue_sim.vvp

# ============================================================================
# Priority Scheduler (includes Queue Manager)
# ============================================================================
SCHEDULER_RTL = $(RTL_DIR)/scheduler/priority_scheduler.v $(RTL_DIR)/queue/queue_manager.v
SCHEDULER_TB  = $(TB_DIR)/scheduler/tb_priority_scheduler.v

scheduler: $(SIM_DIR)
	$(IVERILOG) -o $(SIM_DIR)/scheduler_sim.vvp $(INC_FLAGS) \
		$(SCHEDULER_RTL) $(SCHEDULER_TB)
	cd $(SIM_DIR) && $(VVP) scheduler_sim.vvp

# ============================================================================
# Full Pipeline Integration
# ============================================================================
PIPELINE_RTL = $(RTL_DIR)/parser/packet_parser.v \
               $(RTL_DIR)/classifier/flow_classifier.v \
               $(RTL_DIR)/queue/queue_manager.v \
               $(RTL_DIR)/scheduler/priority_scheduler.v
PIPELINE_TB  = $(TB_DIR)/integration/tb_smartnic_pipeline.v

pipeline: $(SIM_DIR)
	$(IVERILOG) -o $(SIM_DIR)/pipeline_sim.vvp $(INC_FLAGS) \
		$(PIPELINE_RTL) $(PIPELINE_TB)
	cd $(SIM_DIR) && $(VVP) pipeline_sim.vvp

# ============================================================================
# Utilities
# ============================================================================
genpackets:
	$(PYTHON) $(SCRIPT_DIR)/gen_packets.py --output $(SIM_DIR) --count 20

all: parser classifier queue scheduler

$(SIM_DIR):
	mkdir -p $(SIM_DIR)

clean:
	rm -rf $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd $(SIM_DIR)/*.hex $(SIM_DIR)/*.json

.PHONY: parser classifier queue scheduler pipeline genpackets all clean
