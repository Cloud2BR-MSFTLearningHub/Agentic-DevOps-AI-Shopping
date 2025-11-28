"""
Verify that real agents exist in Azure AI Foundry.
"""
import os
import sys
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()

def verify_agents():
    """List all agents in the Azure AI Foundry project."""
    
    project_endpoint = os.getenv("AZURE_AI_PROJECT_ENDPOINT")
    
    if not project_endpoint:
        print("ERROR: AZURE_AI_PROJECT_ENDPOINT not configured")
        sys.exit(1)
    
    print("=" * 70)
    print("Verifying Agents in Azure AI Foundry")
    print("=" * 70)
    print(f"Project Endpoint: {project_endpoint}")
    print()
    
    try:
        credential = DefaultAzureCredential()
        project_client = AIProjectClient(
            endpoint=project_endpoint,
            credential=credential
        )
        
        # List all agents
        print("Fetching agents from Foundry...")
        agents = project_client.agents.list_agents()
        
        agent_list = list(agents)
        
        if not agent_list:
            print("⚠️  No agents found in the project")
            return
        
        print(f"✅ Found {len(agent_list)} agent(s):\n")
        
        for idx, agent in enumerate(agent_list, 1):
            print(f"{idx}. {agent.name}")
            print(f"   ID: {agent.id}")
            print(f"   Model: {agent.model}")
            print(f"   Created: {agent.created_at}")
            print()
        
        # Check expected agents from .env
        expected_agents = {
            "cora": os.getenv("cora"),
            "interior_designer": os.getenv("interior_designer"),
            "inventory_agent": os.getenv("inventory_agent"),
            "customer_loyalty": os.getenv("customer_loyalty"),
            "cart_manager": os.getenv("cart_manager")
        }
        
        print("=" * 70)
        print("Environment Variable Check:")
        print("=" * 70)
        
        for var, agent_id in expected_agents.items():
            if agent_id:
                is_local = agent_id.startswith("asst_local_")
                status = "❌ LOCAL SIMULATION" if is_local else "✅ REAL AGENT"
                print(f"{var:20s} = {agent_id:30s} {status}")
            else:
                print(f"{var:20s} = <NOT SET> ❌")
        
        print()
        
    except Exception as e:
        print(f"❌ Failed to verify agents: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    verify_agents()
