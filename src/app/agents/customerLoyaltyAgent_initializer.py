import os
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv
from agent_initializer import initialize_agent
import os
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from dotenv import load_dotenv
from agent_initializer import initialize_local_agent

load_dotenv()

PROMPT_TARGET = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'prompts', 'CustomerLoyaltyAgentPrompt.txt')
if os.path.exists(PROMPT_TARGET):
    with open(PROMPT_TARGET, 'r', encoding='utf-8') as f:
        _ = f.read()

initialize_local_agent(env_var_name="customer_loyalty", name="Customer Loyalty Agent")
initialize_agent(
