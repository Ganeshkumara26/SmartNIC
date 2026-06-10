# Flow Classifier (`flow_classifier.v`)

## 1. Purpose of the File
`rtl/classifier/flow_classifier.v` performs wire-speed routing. It analyzes the IP/Port metadata extracted by the Packet Parser, matches it against a set of programmable rules, and assigns the packet to a specific 5G Network Slice (Queue ID).

## 2. TCAM Emulation
In enterprise routers, rule matching is done using Ternary Content-Addressable Memory (TCAM). Because standard FPGAs lack native TCAM blocks, this module emulates TCAM using massively parallel combinatorial logic.
- Each rule contains a Value (e.g., IP address) and a Mask (e.g., Subnet).
- The hardware simultaneously compares the packet's metadata against all `MAX_RULES` (16) rules in a single clock cycle.
- Masking is performed using bitwise logic: `(packet_ip & rule_mask) == (rule_ip & rule_mask)`.

## 3. Priority Encoder Resolution
Because a single packet might match multiple rules (e.g., a specific IP rule and a generic Catch-All subnet rule), the classifier uses a Priority Encoder.
- A `for` loop evaluates matches from Rule 0 down to Rule 15.
- The lowest-indexed matching rule takes precedence. 
- If no rules match, the packet is assigned to a default Catch-All slice.

## 4. Software Configuration Port
The routing rules are dynamically programmable. The module exposes a configuration port (`cfg_wr_en`, `cfg_rule_id`, etc.) that allows the Control Plane to update rules on-the-fly without interrupting the active 100 Gbps datapath.
