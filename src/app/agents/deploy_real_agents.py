"""
Deploy real agents to Azure AI Foundry using the AI Projects SDK.
This creates 5 actual agents in the AI Foundry project.
"""
import os
import sys
import json
import hashlib
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.core.credentials import AzureKeyCredential
from dotenv import load_dotenv

load_dotenv()

# Debug environment variables
print(f"DEBUG: AZURE_SUBSCRIPTION_ID={os.getenv('AZURE_SUBSCRIPTION_ID')}")
print(f"DEBUG: AZURE_RESOURCE_GROUP={os.getenv('AZURE_RESOURCE_GROUP')}")
print(f"DEBUG: AZURE_AI_PROJECT_NAME={os.getenv('AZURE_AI_PROJECT_NAME')}")
print(f"DEBUG: AZURE_LOCATION={os.getenv('AZURE_LOCATION')}")

def _hash_instructions(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()

def deploy_agents():
    """Deploy or update agents idempotently, emitting structured JSON for Terraform."""

    project_endpoint = os.getenv("AZURE_AI_PROJECT_ENDPOINT") or os.getenv("AZURE_AI_FOUNDRY_ENDPOINT")
    if not project_endpoint:
        print("ERROR: AZURE_AI_PROJECT_ENDPOINT / AZURE_AI_FOUNDRY_ENDPOINT not configured")
        sys.exit(0)  # Do not hard fail; allow Terraform run to proceed

    print("=" * 70)
    print("Idempotent Multi-Agent Provisioning - Azure AI Foundry")
    print("=" * 70)
    print(f"Project Endpoint: {project_endpoint}")
    print()

    # Try to construct connection string if available
    project_connection_string = os.getenv("AZURE_AI_PROJECT_CONNECTION_STRING")
    if not project_connection_string:
        sub_id = os.getenv("AZURE_SUBSCRIPTION_ID")
        rg = os.getenv("AZURE_RESOURCE_GROUP")
        project_name = os.getenv("AZURE_AI_PROJECT_NAME")
        location = os.getenv("AZURE_LOCATION")
        
        if sub_id and rg and project_name and location:
            project_connection_string = f"{location}.api.azureml.ms;subscription_id={sub_id};resource_group={rg};project_name={project_name}"
            print(f"Constructed connection string: {project_connection_string}")

    # Agent config definitions
    agents_config = [
        {
            "name": "Cora - Shopping Assistant",
            "env_var": "cora",
            "instructions": (
                "You are Cora, a knowledgeable and helpful shopping assistant for Zava, a home improvement and hardware store. "
                "Your role is to help customers find products, answer questions about inventory, provide recommendations, and assist with general shopping needs. "
                "Be friendly, professional, and informative. Keep answers concise and helpful."
            ),
            "model": "gpt-4o-mini"
        },
        {
            "name": "Interior Design Specialist",
            "env_var": "interior_designer",
            "instructions": (
                "You are an expert interior designer at Zava. Help customers with color schemes, room layout, product combinations, and style advice (modern, rustic, minimalist, etc.). "
                "Provide creative, practical advice with specific product recommendations when possible."
            ),
            "model": "gpt-4o-mini"
        },
        {
            "name": "Inventory Manager",
            "env_var": "inventory_agent",
            "instructions": (
                "You are the inventory specialist at Zava. Help customers check product availability, provide stock levels, suggest alternatives if items are out of stock, and estimate restock timelines. "
                "Be factual and helpful about inventory status."
            ),
            "model": "gpt-4o-mini"
        },
        {
            "name": "Customer Loyalty Specialist",
            "env_var": "customer_loyalty",
            "instructions": (
                "You are the customer loyalty and rewards specialist at Zava. Help customers understand their loyalty tier and benefits, calculate applicable discounts, learn about rewards programs, and maximize their savings. "
                "Be enthusiastic about helping customers save money."
            ),
            "model": "gpt-4o-mini"
        },
        {
            "name": "Cart Management Assistant",
            "env_var": "cart_manager",
            "instructions": (
                "You are the shopping cart assistant at Zava. Help customers add items to their cart, remove items, review cart contents, and proceed to checkout. "
                "Be efficient and confirm all cart operations clearly."
            ),
            "model": "gpt-4o-mini"
        }
    ]

    # Load prior state (instruction hashes) if present
    state_path = os.path.join(os.path.dirname(__file__), "agents_state.json")
    prior_state = {}
    if os.path.exists(state_path):
        try:
            with open(state_path, "r", encoding="utf-8") as sf:
                prior_state = json.load(sf)
        except Exception:
            prior_state = {}

    deployed_agents = {}
    statuses = {}

    try:
        # Define a Scoped Credential to force the correct scope for AI Foundry
        class ScopedCredential:
            def __init__(self, credential, scope):
                self.credential = credential
                self.scope = scope
            
            def get_token(self, *scopes, **kwargs):
                # Ignore requested scopes and use the forced one
                return self.credential.get_token(self.scope, **kwargs)

        print("Using DefaultAzureCredential with forced scope: https://ai.azure.com/.default")
        base_credential = DefaultAzureCredential()
        credential = ScopedCredential(base_credential, "https://ai.azure.com/.default")
        
        # Use the constructor directly with all required arguments
        sub_id = os.getenv("AZURE_SUBSCRIPTION_ID")
        rg = os.getenv("AZURE_RESOURCE_GROUP")
        project_name = os.getenv("AZURE_AI_PROJECT_NAME")
        
        # Fix endpoint domain if needed (Cognitive Services -> AI Services)
        if project_endpoint and "cognitiveservices.azure.com" in project_endpoint:
            print(f"Adjusting endpoint domain from cognitiveservices.azure.com to services.ai.azure.com")
            project_endpoint = project_endpoint.replace("cognitiveservices.azure.com", "services.ai.azure.com")
            
        if sub_id and rg and project_name:
            # Append project path if not present
            if "/api/projects/" not in project_endpoint:
                 project_endpoint = f"{project_endpoint.rstrip('/')}/api/projects/{project_name}"
                 
            print(f"Initializing AIProjectClient with endpoint={project_endpoint}")
            # AIProjectClient(endpoint, credential, **kwargs)
            project_client = AIProjectClient(
                endpoint=project_endpoint,
                credential=credential,
                subscription_id=sub_id,
                resource_group_name=rg,
                project_name=project_name
            )
        else:
             raise ValueError("Missing required environment variables for AIProjectClient")
            
        existing_agents = {a.name: a for a in project_client.agents.list_agents()}
    except Exception as e:
        print(f"⚠ Unable to query existing agents: {e}")
        existing_agents = {}

    for cfg in agents_config:
        name = cfg["name"]
        env_var = cfg["env_var"]
        instr = cfg["instructions"]
        instr_hash = _hash_instructions(instr)
        prior_hash = prior_state.get(env_var, {}).get("hash")

        # Idempotent logic
        if name in existing_agents:
            agent_obj = existing_agents[name]
            agent_id = getattr(agent_obj, "id", None) or getattr(agent_obj, "agentId", f"unknown-{env_var}")
            # Attempt update if instructions changed
            if prior_hash and prior_hash != instr_hash:
                print(f"🔄 Updating agent (instructions changed): {name}")
                try:
                    # Try native update if available
                    try:
                        project_client.agents.update_agent(agent_id=agent_id, instructions=instr)
                        statuses[env_var] = "updated"
                    except Exception:
                        # Fallback recreate strategy
                        try:
                            project_client.agents.delete_agent(agent_id)
                        except Exception:
                            pass
                        new_agent = project_client.agents.create_agent(model=cfg["model"], name=name, instructions=instr)
                        agent_id = new_agent.id
                        statuses[env_var] = "recreated"
                    print(f"✅ Agent updated: {agent_id}")
                except Exception as ue:
                    print(f"⚠ Failed to update {name}: {ue}")
                    statuses[env_var] = "existing-no-update"
                deployed_agents[env_var] = agent_id
            else:
                print(f"↩ Reusing existing agent: {name} ({agent_id})")
                deployed_agents[env_var] = agent_id
                statuses[env_var] = "existing"
            continue

        # Create new agent
        print(f"📦 Creating agent: {name}")
        try:
            agent = project_client.agents.create_agent(model=cfg["model"], name=name, instructions=instr)
            agent_id = agent.id
            deployed_agents[env_var] = agent_id
            statuses[env_var] = "created"
            print(f"✅ Created: {name} -> {agent_id}")
        except Exception as ce:
            print(f"❌ Failed to create {name}: {ce}")
            fallback_id = f"asst_local_{env_var}"
            deployed_agents[env_var] = fallback_id
            statuses[env_var] = "fallback-local"
            print(f"   Using fallback local simulation: {fallback_id}")

    # Persist state (hash + id)
    new_state = {}
    for cfg in agents_config:
        ev = cfg["env_var"]
        new_state[ev] = {
            "id": deployed_agents.get(ev),
            "hash": _hash_instructions(cfg["instructions"]),
            "status": statuses.get(ev)
        }
    try:
        with open(state_path, "w", encoding="utf-8") as sf:
            json.dump(new_state, sf, indent=2)
        print(f"📝 State file updated: {state_path}")
    except Exception as se:
        print(f"⚠ Failed to write state file: {se}")

    # Update .env with real agent IDs (early propagation)
    env_path = os.path.join(os.path.dirname(__file__), '..', '..', '.env')
    if os.path.exists(env_path):
        try:
            with open(env_path, 'r', encoding='utf-8') as f:
                lines = f.readlines()
            with open(env_path, 'w', encoding='utf-8') as f:
                for line in lines:
                    wrote = False
                    for var, aid in deployed_agents.items():
                        if line.startswith(f"{var}="):
                            f.write(f"{var}={aid}\n")
                            wrote = True
                            break
                    if not wrote:
                        f.write(line)
            print(f"✅ Updated .env with agent IDs: {env_path}")
        except Exception as ee:
            print(f"⚠ Failed to update .env: {ee}")
    else:
        print("ℹ .env file not found for agent ID propagation")

    print("\nSummary:")
    for k, v in deployed_agents.items():
        print(f"  {k}: {v} ({statuses.get(k)})")

    # Emit structured JSON sentinel block for Terraform parsing
    payload = {"agents": deployed_agents, "statuses": statuses}
    print("===AGENTS_JSON_START===")
    print(json.dumps(payload, indent=2))
    print("===AGENTS_JSON_END===")

    return deployed_agents

if __name__ == "__main__":
    deploy_agents()
