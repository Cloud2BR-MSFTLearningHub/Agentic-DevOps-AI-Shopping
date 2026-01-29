"""
Deploy real agents to MSFT Foundry using the AI Projects SDK.
This creates 6 specialized agents in the MSFT Foundry project with enhanced A2A protocol support.
"""
import os
import sys
import json
import hashlib
from typing import Optional
from azure.ai.projects import AIProjectClient
from dotenv import load_dotenv


_dotenv_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".env"))
if os.path.exists(_dotenv_path):
    load_dotenv(dotenv_path=_dotenv_path)
else:
    # Fall back to default search behavior for local/dev environments.
    load_dotenv()

def get_env(name: str, default: Optional[str] = None) -> Optional[str]:
    """Read an environment variable with APPSETTING_ fallback."""
    value = os.getenv(name)
    if value:
        return value
    prefixed = os.getenv(f"APPSETTING_{name}")
    if prefixed:
        return prefixed
    return default


# Debug environment variables
print(f"DEBUG: AZURE_SUBSCRIPTION_ID={get_env('AZURE_SUBSCRIPTION_ID')}")
print(f"DEBUG: AZURE_RESOURCE_GROUP={get_env('AZURE_RESOURCE_GROUP')}")
print(f"DEBUG: AZURE_AI_PROJECT_NAME={get_env('AZURE_AI_PROJECT_NAME')}")
print(f"DEBUG: AZURE_LOCATION={get_env('AZURE_LOCATION')}")

def _hash_instructions(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _resolve_model_name(model: str) -> str:
    """Resolve model name to the exact Azure AI Foundry deployment name."""
    model_map = {
        "model_router": "model-router",
        "gpt_4o": "gpt-4o",
        "gpt_4o_mini": "gpt-4o-mini",
        "text_embedding_3_small": "text-embedding-3-small",
        "model-router": "model-router",
        "gpt-4o": "gpt-4o",
        "gpt-4o-mini": "gpt-4o-mini",
        "text-embedding-3-small": "text-embedding-3-small",
    }
    resolved = model_map.get(model, model)
    if resolved == model and "_" in model:
        resolved = model.replace("_", "-")
    return resolved


def _sanitize_agent_name(name: str) -> str:
    """Sanitize agent name for API constraints (lowercase, hyphens, <=63 chars)."""
    import re

    name = name.replace(" ", "-")
    name = re.sub(r"[^a-zA-Z0-9-]", "", name)
    name = re.sub(r"-+", "-", name)
    name = name[:63]
    name = name.strip("-")
    return name.lower()


def _create_agent(project_client: AIProjectClient, *, model: str, name: str, instructions: str):
    """Create an agent with SDK-version fallback support."""
    agents = project_client.agents

    if hasattr(agents, "create_agent"):
        return agents.create_agent(model=model, name=name, instructions=instructions)

    if hasattr(agents, "create"):
        # Try a simple kwargs signature first
        try:
            return agents.create(model=model, name=name, instructions=instructions)
        except TypeError:
            pass

        # Fall back to SDK model definitions
        try:
            from azure.ai.projects.models import PromptAgentDefinition

            agent_def = PromptAgentDefinition(model=model, name=name, instructions=instructions)
            return agents.create(agent_def)
        except Exception:
            pass

        try:
            from azure.ai.projects.models import AgentDefinition

            agent_def = AgentDefinition(model=model, name=name, instructions=instructions)
            return agents.create(agent_def)
        except Exception:
            pass

        # Last resort: pass a dict payload
        return agents.create({"model": model, "name": name, "instructions": instructions})

    if hasattr(agents, "create_prompt_agent"):
        return agents.create_prompt_agent(model=model, name=name, instructions=instructions)

    raise AttributeError("No supported agent creation method found in Azure AI Projects SDK")


from services.azure_auth import get_default_credential

def deploy_agents():
    """Deploy or update agents idempotently, emitting structured JSON for Terraform."""

    project_endpoint = get_env("AZURE_AI_PROJECT_ENDPOINT") or get_env("AZURE_AI_FOUNDRY_ENDPOINT")
    if not project_endpoint:
        foundry_name = get_env("AZURE_AI_FOUNDRY_NAME")
        project_name = get_env("AZURE_AI_PROJECT_NAME")
        if foundry_name and project_name:
            project_endpoint = f"https://{foundry_name}.services.ai.azure.com/api/projects/{project_name}"
        else:
            print("ERROR: AZURE_AI_PROJECT_ENDPOINT / AZURE_AI_FOUNDRY_ENDPOINT not configured")
            sys.exit(0)  # Do not hard fail; allow Terraform run to proceed

    print("=" * 70)
    print("Idempotent Multi-Agent Provisioning - Azure AI Foundry")
    print("=" * 70)
    print(f"Project Endpoint: {project_endpoint}")
    print()

    # Try to construct connection string if available
    project_connection_string = get_env("AZURE_AI_PROJECT_CONNECTION_STRING")
    if not project_connection_string:
        sub_id = get_env("AZURE_SUBSCRIPTION_ID")
        rg = get_env("AZURE_RESOURCE_GROUP")
        project_name = get_env("AZURE_AI_PROJECT_NAME")
        location = get_env("AZURE_LOCATION")
        
        if sub_id and rg and project_name and location:
            project_connection_string = f"{location}.api.azureml.ms;subscription_id={sub_id};resource_group={rg};project_name={project_name}"
            print(f"Constructed connection string: {project_connection_string}")

    # Agent config definitions
    model_deployment = (
        get_env("AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME")
        or get_env("AZURE_OPENAI_CHAT_DEPLOYMENT")
        or get_env("MODEL_DEPLOYMENT_NAME")
        or "model-router"
    )
    model_deployment = _resolve_model_name(model_deployment)

    agent_model_map = {}
    try:
        agent_model_map = json.loads(get_env("AGENT_MODEL_MAP", "{}") or "{}")
    except Exception:
        agent_model_map = {}

    agents_config = [
        {
            "name": "Cora - Shopping Assistant",
            "env_var": "cora",
            "instructions": (
                "You are Cora, a knowledgeable and helpful shopping assistant for Zava, a home improvement and hardware store. "
                "Your role is to help customers find products, answer questions about inventory, provide recommendations, and assist with general shopping needs. "
                "Be friendly, professional, and informative. Keep answers concise and helpful."
            ),
            "model": agent_model_map.get("cora", model_deployment)
        },
        {
            "name": "Interior Design Specialist",
            "env_var": "interior_designer",
            "instructions": (
                "You are an expert interior designer at Zava. Help customers with color schemes, room layout, product combinations, and style advice (modern, rustic, minimalist, etc.). "
                "Provide creative, practical advice with specific product recommendations when possible."
            ),
            "model": agent_model_map.get("interior_designer", model_deployment)
        },
        {
            "name": "Inventory Manager",
            "env_var": "inventory_agent",
            "instructions": (
                "You are the inventory specialist at Zava. Help customers check product availability, provide stock levels, suggest alternatives if items are out of stock, and estimate restock timelines. "
                "Be factual and helpful about inventory status."
            ),
            "model": agent_model_map.get("inventory_agent", model_deployment)
        },
        {
            "name": "Customer Loyalty Specialist",
            "env_var": "customer_loyalty",
            "instructions": (
                "You are the customer loyalty and rewards specialist at Zava. Help customers understand their loyalty tier and benefits, calculate applicable discounts, learn about rewards programs, and maximize their savings. "
                "Be enthusiastic about helping customers save money."
            ),
            "model": agent_model_map.get("customer_loyalty", model_deployment)
        },
        {
            "name": "Cart Management Assistant",
            "env_var": "cart_manager",
            "instructions": (
                "You are the shopping cart assistant at Zava. Help customers add items to their cart, remove items, review cart contents, and proceed to checkout. "
                "Be efficient and confirm all cart operations clearly."
            ),
            "model": agent_model_map.get("cart_manager", model_deployment)
        },
        {
            "name": "Product Management Specialist",
            "env_var": "product_management",
            "instructions": (
                "You are the Product Management Specialist for Zava, coordinating with specialized plugins for comprehensive product services. "
                "Your expertise includes product catalog search and management, personalized recommendations through AI analysis, "
                "market trend analysis and insights, product ranking and popularity metrics, and inventory coordination. "
                "You work with ProductPlugin for catalog operations, MarketingPlugin for recommendations and trends, "
                "and RankingPlugin for popularity analysis. Coordinate with other agents when queries involve design (interior_designer), "
                "purchasing (cart_manager), loyalty benefits (customer_loyalty), or availability (inventory_agent). "
                "Always provide accurate product information with specific names, prices, and availability. "
                "Use A2A protocol patterns to ensure seamless handoffs to appropriate specialists."
            ),
            "model": agent_model_map.get("product_management", model_deployment)
        }
    ]

    # Load prior state (instruction hashes) if present
    # Write to terraform temp directory instead of src/app/agents
    terraform_dir = os.path.join(os.path.dirname(__file__), "..", "..", "..", "terraform-infrastructure")
    state_path = os.path.join(terraform_dir, ".terraform", "agents_state.json")
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
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
        print("Initializing Azure AI Project Client...")
        
        # Use managed identity when available (AZURE_CLIENT_ID), otherwise fall back
        credential = get_default_credential()
        
        # Get required environment variables
        sub_id = get_env("AZURE_SUBSCRIPTION_ID")
        rg = get_env("AZURE_RESOURCE_GROUP")
        project_name = get_env("AZURE_AI_PROJECT_NAME")
        
        if not all([sub_id, rg, project_name]):
            raise ValueError("Missing required environment variables: AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_AI_PROJECT_NAME")
        
        # Fix endpoint domain if needed (Cognitive Services -> AI Services)
        if project_endpoint and "cognitiveservices.azure.com" in project_endpoint:
            print(f"Converting endpoint domain: cognitiveservices.azure.com -> services.ai.azure.com")
            project_endpoint = project_endpoint.replace("cognitiveservices.azure.com", "services.ai.azure.com")
            os.environ["AZURE_AI_PROJECT_ENDPOINT"] = project_endpoint
        
        # Construct proper project endpoint: https://<hub>.services.ai.azure.com/api/projects/<project>
        # Remove any existing path segments first
        base_endpoint = project_endpoint.split("/api/")[0]  # Get just the base URL
        base_endpoint = base_endpoint.rstrip('/')
        
        # Now add the proper API path with project name
        full_project_endpoint = f"{base_endpoint}/api/projects/{project_name}"
        
        print(f"Project Endpoint (base): {base_endpoint}")
        print(f"Project Endpoint (full): {full_project_endpoint}")
        print(f"Subscription: {sub_id}")
        print(f"Resource Group: {rg}")
        print(f"Project Name: {project_name}")
        
        # Initialize AIProjectClient with connection string when supported (newer SDKs),
        # otherwise fall back to the project endpoint.
        if project_connection_string and hasattr(AIProjectClient, "from_connection_string"):
            project_client = AIProjectClient.from_connection_string(
                credential=credential,
                conn_str=project_connection_string,
            )
        else:
            # The SDK requires the full project endpoint
            project_client = AIProjectClient(endpoint=full_project_endpoint, credential=credential)
        
        print("Successfully initialized AIProjectClient")
        print("Fetching existing agents...")
        
        existing_agents = {}
        try:
            if hasattr(project_client.agents, "list"):
                agent_list = list(project_client.agents.list())
            else:
                agent_list = list(project_client.agents.list_agents())
            existing_agents = {a.name: a for a in agent_list}
            for a in agent_list:
                existing_agents[_sanitize_agent_name(a.name)] = a
            print(f"Found {len(existing_agents)} existing agent(s)")
        except Exception as list_err:
            print(f"Could not list existing agents (may be first run): {list_err}")
            existing_agents = {}
            
    except Exception as e:
        print(f"ERROR initializing AIProjectClient: {e}")
        import traceback
        traceback.print_exc()
        print("\nFalling back to local pseudo-agents...")
        existing_agents = {}
        # Don't exit - continue with fallback IDs
        project_client = None

    for cfg in agents_config:
        name = cfg["name"]
        env_var = cfg["env_var"]
        instr = cfg["instructions"]
        sanitized_name = _sanitize_agent_name(name)
        instr_hash = _hash_instructions(instr)
        prior_hash = prior_state.get(env_var, {}).get("hash")

        # Skip if no project client available
        if project_client is None:
            print(f"[{env_var}] No project client - using fallback ID")
            fallback_id = f"asst_local_{env_var}"
            deployed_agents[env_var] = fallback_id
            statuses[env_var] = "fallback-no-client"
            continue

        # Idempotent logic - check if agent already exists
        existing_agent = existing_agents.get(name) or existing_agents.get(sanitized_name)
        if existing_agent:
            agent_obj = existing_agent
            agent_id = (
                getattr(agent_obj, "id", None)
                or getattr(agent_obj, "agent_id", None)
                or getattr(agent_obj, "agentId", None)
                or f"unknown-{env_var}"
            )
            
            # Attempt update if instructions changed
            if prior_hash and prior_hash != instr_hash:
                print(f"[{env_var}] Recreating agent (instructions changed): {name}")
                try:
                    try:
                        if hasattr(project_client.agents, "delete_agent"):
                            project_client.agents.delete_agent(agent_id=agent_id)
                        else:
                            project_client.agents.delete(agent_id)
                    except Exception:
                        pass

                    new_agent = _create_agent(
                        project_client,
                        model=_resolve_model_name(cfg["model"]),
                        name=sanitized_name,
                        instructions=instr,
                    )
                    agent_id = (
                        getattr(new_agent, "id", None)
                        or getattr(new_agent, "agent_id", None)
                        or getattr(new_agent, "agentId", None)
                        or agent_id
                    )
                    statuses[env_var] = "recreated"
                    print(f"[{env_var}] Successfully recreated: {agent_id}")
                except Exception as ue:
                    print(f"[{env_var}] Failed to recreate {name}: {ue}")
                    statuses[env_var] = "existing-no-update"

                deployed_agents[env_var] = agent_id
            else:
                print(f"[{env_var}] Reusing existing agent: {name} ({agent_id})")
                deployed_agents[env_var] = agent_id
                statuses[env_var] = "existing"
            continue

        # Create new agent
        print(f"[{env_var}] Creating new agent: {name}")
        try:
            agent = _create_agent(
                project_client,
                model=_resolve_model_name(cfg["model"]),
                name=sanitized_name,
                instructions=instr,
            )
            agent_id = (
                getattr(agent, "id", None)
                or getattr(agent, "agent_id", None)
                or getattr(agent, "agentId", None)
                or f"unknown-{env_var}"
            )
            deployed_agents[env_var] = agent_id
            statuses[env_var] = "created"
            print(f"[{env_var}] SUCCESS - Created agent: {agent_id}")
        except Exception as ce:
            print(f"[{env_var}] FAILED to create {name}: {ce}")
            import traceback
            traceback.print_exc()
            
            # Use fallback local ID
            fallback_id = f"asst_local_{env_var}"
            deployed_agents[env_var] = fallback_id
            statuses[env_var] = "fallback-creation-failed"
            print(f"[{env_var}] Using fallback local simulation: {fallback_id}")

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
        print(f"[STATE] State file updated: {state_path}")
    except Exception as se:
        print(f"WARNING: Failed to write state file: {se}")

    # Update src/.env with real agent IDs (early propagation)
    # NOTE: Terraform generates ../src/.env (workspace-relative), not ../src/app/.env.
    env_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..', '.env'))
    if os.path.exists(env_path):
        try:
            import re

            with open(env_path, 'r', encoding='utf-8') as f:
                content = f.read()

            # Normalize Agents endpoint domains (cognitiveservices -> services.ai)
            content = content.replace("cognitiveservices.azure.com", "services.ai.azure.com")

            # Replace or append each agent ID
            for var, aid in deployed_agents.items():
                pattern = rf'^{re.escape(var)}=.*$'
                replacement = f'{var}={aid}'
                if re.search(pattern, content, flags=re.MULTILINE):
                    content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
                else:
                    # Append if the key is missing (supports older .env templates)
                    if not content.endswith("\n"):
                        content += "\n"
                    content += f"{replacement}\n"

            with open(env_path, 'w', encoding='utf-8') as f:
                f.write(content)

            print(f"Updated .env with agent IDs: {env_path}")
            print("Agent IDs written:")
            for var, aid in deployed_agents.items():
                print(f"  {var}: {aid}")
        except Exception as ee:
            print(f"WARNING: Failed to update .env: {ee}")
            import traceback
            traceback.print_exc()
    else:
        print(f"INFO: .env file not found for agent ID propagation: {env_path}")

    print("\n" + "=" * 70)
    print("DEPLOYMENT SUMMARY")
    print("=" * 70)
    for k, v in deployed_agents.items():
        status = statuses.get(k, "unknown")
        print(f"  {k}: {v} [{status}]")

    # Emit structured JSON sentinel block for Terraform parsing
    payload = {"agents": deployed_agents, "statuses": statuses}
    print("===AGENTS_JSON_START===")
    print(json.dumps(payload, indent=2))
    print("===AGENTS_JSON_END===")

    return deployed_agents

if __name__ == "__main__":
    deploy_agents()
