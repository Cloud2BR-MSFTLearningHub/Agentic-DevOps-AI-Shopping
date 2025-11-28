import os
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from dotenv import load_dotenv
from agent_initializer import initialize_local_agent

load_dotenv()

# Read prompt (retained for future remote implementation, unused in local stub)
PROMPT_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'prompts', 'ShopperAgentPrompt.txt')
if os.path.exists(PROMPT_PATH):
    with open(PROMPT_PATH, 'r', encoding='utf-8') as f:
        _ = f.read()

# Initialize local pseudo agent
initialize_local_agent(env_var_name="cora", name="Cora - Zava Shopping Assistant")
