"""Domain-specific agent instruction consolidation.

Uses Cora (shopper) prompt as baseline and applies lightweight
specialization for each additional domain.
"""
import os

PROMPTS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'prompts')

def _read(name: str) -> str:
    path = os.path.join(PROMPTS_DIR, name)
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            return f.read().strip()
    return ""

BASE_CORA = _read('ShopperAgentPrompt.txt') or "You are Cora, a helpful shopping assistant for Zava DIY."

AGENT_INSTRUCTIONS = {
    'cora': BASE_CORA,
    'interior_design': _read('InteriorDesignAgentPrompt.txt') or "Provide interior design guidance tied to product suggestions.",
    'inventory': _read('InventoryAgentPrompt.txt') or "Report mock inventory status with concise JSON if feasible.",
    'customer_loyalty': _read('CustomerLoyaltyAgentPrompt.txt') or "Determine a loyalty discount (default 10%).",
    'cart_management': _read('CartManagerAgentPrompt.txt') or "Maintain a cart list; support 'add <item>' and 'remove <item>'."
}
