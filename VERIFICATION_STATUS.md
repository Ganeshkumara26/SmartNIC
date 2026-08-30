# Verification Status

This document shows what we have tested and verified in our project.

- Packet Parser: Tested using random packet streams. Pass.
- Flow Classifier: Verified the routing rules. Pass.
- Queuing: Checked for data drops under heavy load. Pass.
- Control Plane: Tested reading and writing registers. Pass.

Some tests are still failing when we have too much traffic, but we are working on fixing the bottlenecks.
