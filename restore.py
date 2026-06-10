import subprocess
import re
import os

files = [
    ("Chapter_1_smartnic_pkg.md", "01_smartnic_pkg.md"),
    ("Chapter_2_packet_parser.md", "02_packet_parser.md"),
    ("Chapter_3_flow_classifier.md", "03_flow_classifier.md"),
    ("Chapter_4_axi_stream_fifo.md", "04_axi_stream_fifo.md"),
    ("Chapter_5_queue_manager.md", "05_queue_manager.md"),
    ("Chapter_6_priority_scheduler.md", "06_priority_scheduler.md"),
    ("Chapter_7_token_bucket.md", "07_token_bucket.md"),
    ("Chapter_8_axilite_csr.md", "08_axilite_csr.md")
]

for old_name, new_name in files:
    # 1. Fetch old content
    result = subprocess.run(["git", "show", f"49f496f:docs/{old_name}"], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error fetching {old_name}")
        continue
    content = result.stdout
    
    # 2. Strip sections 9 and 10, or 7 Exercises
    content = re.sub(r"\n## 9\. Common Beginner Confusions.*", "", content, flags=re.DOTALL)
    content = re.sub(r"\n## 10\. Exercises.*", "", content, flags=re.DOTALL)
    content = re.sub(r"\n## 7\. Exercises.*", "", content, flags=re.DOTALL)
    
    # 3. Strip textbook persona phrases
    content = content.replace("The author explicitly chose", "The architecture uses")
    content = content.replace("The author explicitly designed", "The architecture was designed")
    content = content.replace("The author chose", "The architecture uses")
    content = content.replace("The author implemented", "The module implements")
    content = content.replace("The author", "The designer")
    content = content.replace("In this chapter, we will", "This document will")
    content = content.replace("we will", "the architecture will")
    content = re.sub(r"^# Chapter \d+: ", "# ", content, flags=re.MULTILINE)
    
    # 4. Write back to the new file
    with open(f"docs/{new_name}", "w", encoding="utf-8") as f:
        f.write(content)
        
print("Rewrite complete.")
