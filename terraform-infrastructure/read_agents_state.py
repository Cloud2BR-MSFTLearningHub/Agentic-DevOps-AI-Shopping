#!/usr/bin/env python
import json, os, sys

# Terraform external data source requires a flat map of strings.
# We will flatten the agents_state.json into keys like "agent_NAME_id" and "agent_NAME_status".

# Read from .terraform directory (temporary location)
state_path = os.path.join(os.path.dirname(__file__), '.terraform', 'agents_state.json')
result = {}

try:
    if os.path.exists(state_path):
        with open(state_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        # Flatten the data
        for agent_name, agent_data in data.items():
            # Ensure values are strings
            result[f"agent_{agent_name}_id"] = str(agent_data.get('id', ''))
            result[f"agent_{agent_name}_status"] = str(agent_data.get('status', ''))
            
    else:
        result["status"] = "state_file_missing"

except Exception as e:
    result['error'] = str(e)

# Ensure we output valid JSON
print(json.dumps(result))