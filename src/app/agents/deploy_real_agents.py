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
try:
    # Prefer this for runtime agent IDs (asst_...)
    from azure.ai.agents import AgentsClient  # type: ignore
except Exception:
    AgentsClient = None  # type: ignore
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


def _resolve_agents_client_model(model: str) -> str:
    """Resolve model for AgentsClient.create_agent/update_agent.

    The Agents runtime API rejects special/router deployments like "model-router".
    Default to a concrete chat model deployment (env override supported).
    """
    resolved = _resolve_model_name(model)
    if resolved in ("model-router", "model_router"):
        return get_env("AZURE_AI_AGENT_MODEL_DEPLOYMENT", "gpt-4o-mini") or "gpt-4o-mini"
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

        # Preferred: pass name + definition explicitly (newer SDK signature)
        try:
            from azure.ai.projects.models import PromptAgentDefinition, AgentKind

            agent_def = PromptAgentDefinition(
                kind=AgentKind.PROMPT,
                model=model,
                instructions=instructions,
            )
            return agents.create(name=name, definition=agent_def, description=name)
        except Exception:
            pass

        # Fall back to SDK model definitions
        try:
            from azure.ai.projects.models import PromptAgentDefinition, AgentKind

            agent_def = PromptAgentDefinition(
                kind=AgentKind.PROMPT,
                model=model,
                instructions=instructions,
            )
            return agents.create(agent_def)
        except Exception:
            pass

        try:
            from azure.ai.projects.models import AgentDefinition, AgentKind

            agent_def = AgentDefinition(kind=str(AgentKind.PROMPT))
            return agents.create(agent_def)
        except Exception:
            pass

        # Try AgentCreateRequest with explicit definition
        try:
            from azure.ai.projects.models import AgentCreateRequest, PromptAgentDefinition, AgentKind

            agent_def = PromptAgentDefinition(
                kind=AgentKind.PROMPT,
                model=model,
                instructions=instructions,
            )
            request = AgentCreateRequest(definition=agent_def, name=name, description=name)
            return agents.create(request)
        except Exception:
            pass

        # Some SDKs require a "definition" wrapper in the payload
        payload = {
            "name": name,
            "kind": "prompt",
            "definition": {
                "model": model,
                "instructions": instructions,
            },
        }
        return agents.create(payload)

    if hasattr(agents, "create_prompt_agent"):
        return agents.create_prompt_agent(model=model, name=name, instructions=instructions)

    raise AttributeError("No supported agent creation method found in Azure AI Projects SDK")


def _extract_agent_resource_id(agent_obj) -> str | None:
    """Return the Azure AI Foundry agent resource id (used for manage/list/delete)."""
    if agent_obj is None:
        return None
    for attr in ("id", "agent_id", "agentId"):
        value = getattr(agent_obj, attr, None)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _extract_assistant_id(agent_obj) -> str | None:
    """Return the OpenAI-style assistant id (asst_...) when present.

    Some SDK surfaces expose both a Foundry agent resource id and the underlying
    assistant id used by the threads/runs API.
    """
    if agent_obj is None:
        return None
    for attr in (
        "assistant_id",
        "assistantId",
        "openai_assistant_id",
        "openaiAssistantId",
        "assistantID",
    ):
        value = getattr(agent_obj, attr, None)
        if isinstance(value, str) and value.strip().startswith("asst"):
            return value.strip()
    # Some SDKs only populate `id` with an assistant id.
    value = getattr(agent_obj, "id", None)
    if isinstance(value, str) and value.strip().startswith("asst"):
        return value.strip()
    return None


def _extract_runtime_id(agent_obj, env_var: str) -> str:
    """Select the id that the runtime (threads/runs) API expects."""
    assistant_id = _extract_assistant_id(agent_obj)
    if assistant_id:
        return assistant_id
    resource_id = _extract_agent_resource_id(agent_obj)
    if resource_id:
        return resource_id
    return f"unknown-{env_var}"


def _get_agent_details(project_client: AIProjectClient, resource_id: str):
    """Best-effort fetch of full agent details.

    List operations sometimes return a lightweight object without `assistant_id`.
    This tries common SDK shapes to retrieve a fuller representation.
    """
    if not project_client or not resource_id:
        return None

    agents = getattr(project_client, "agents", None)
    if agents is None:
        return None

    # Newer SDKs
    if hasattr(agents, "get_agent"):
        try:
            return agents.get_agent(agent_id=resource_id)
        except Exception:
            pass

    # Generic get
    if hasattr(agents, "get"):
        try:
            return agents.get(resource_id)
        except Exception:
            pass

    return None


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
            "model": agent_model_map.get("cora", "model-router")
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
    deployed_resource_ids: dict[str, str] = {}
    statuses = {}

    # Preferred path: provision runtime agents via AgentsClient (OpenAI-style asst_* IDs).
    # This matches what the threads/runs API expects at runtime.
    if AgentsClient is not None:
        try:
            print("Initializing AgentsClient (runtime threads/runs API)...")

            credential = get_default_credential()
            project_name = get_env("AZURE_AI_PROJECT_NAME")
            if not project_name:
                raise ValueError("Missing required environment variable: AZURE_AI_PROJECT_NAME")

            if project_endpoint and "cognitiveservices.azure.com" in project_endpoint:
                print("Converting endpoint domain: cognitiveservices.azure.com -> services.ai.azure.com")
                project_endpoint = project_endpoint.replace("cognitiveservices.azure.com", "services.ai.azure.com")
                os.environ["AZURE_AI_PROJECT_ENDPOINT"] = project_endpoint

            base_endpoint = project_endpoint.split("/api/")[0].rstrip("/")
            full_project_endpoint = f"{base_endpoint}/api/projects/{project_name}"
            print(f"Project Endpoint (full): {full_project_endpoint}")

            agents_client = AgentsClient(endpoint=full_project_endpoint, credential=credential)

            print("Fetching existing runtime agents (asst_* IDs)...")
            existing_agents = {}
            try:
                agent_list = list(agents_client.list_agents())
                for a in agent_list:
                    name = getattr(a, "name", None)
                    if isinstance(name, str) and name:
                        existing_agents[name] = a
                        existing_agents[_sanitize_agent_name(name)] = a
                print(f"Found {len(agent_list)} runtime agent(s)")
            except Exception as list_err:
                print(f"Could not list runtime agents: {list_err}")
                agent_list = []

            for cfg in agents_config:
                name = cfg["name"]
                env_var = cfg["env_var"]
                instr = cfg["instructions"]
                sanitized_name = _sanitize_agent_name(name)
                instr_hash = _hash_instructions(instr)
                prior_hash = prior_state.get(env_var, {}).get("hash")

                existing = existing_agents.get(sanitized_name) or existing_agents.get(name)
                if existing:
                    agent_id = getattr(existing, "id", None) or f"unknown-{env_var}"

                    if prior_hash and prior_hash != instr_hash:
                        print(f"[{env_var}] Updating runtime agent (instructions changed): {sanitized_name}")
                        try:
                            updated = agents_client.update_agent(
                                agent_id,
                                model=_resolve_agents_client_model(cfg["model"]),
                                name=sanitized_name,
                                description=name,
                                instructions=instr,
                            )
                            agent_id = getattr(updated, "id", None) or agent_id
                            statuses[env_var] = "updated"
                        except Exception as ue:
                            print(f"[{env_var}] Failed to update agent {sanitized_name}: {ue}")
                            statuses[env_var] = "existing-no-update"
                    else:
                        print(f"[{env_var}] Reusing existing runtime agent: {sanitized_name} ({agent_id})")
                        statuses[env_var] = "existing"

                    deployed_agents[env_var] = str(agent_id)
                    deployed_resource_ids[env_var] = str(agent_id)
                    continue

                print(f"[{env_var}] Creating new runtime agent: {sanitized_name}")
                created = agents_client.create_agent(
                    model=_resolve_agents_client_model(cfg["model"]),
                    name=sanitized_name,
                    description=name,
                    instructions=instr,
                )
                agent_id = getattr(created, "id", None) or f"unknown-{env_var}"
                deployed_agents[env_var] = str(agent_id)
                deployed_resource_ids[env_var] = str(agent_id)
                statuses[env_var] = "created"
                print(f"[{env_var}] SUCCESS - Created runtime agent: {agent_id}")

            # Persist state (hash + id)
            new_state = {}
            for cfg in agents_config:
                ev = cfg["env_var"]
                new_state[ev] = {
                    "id": deployed_agents.get(ev),
                    "resource_id": deployed_resource_ids.get(ev),
                    "hash": _hash_instructions(cfg["instructions"]),
                    "status": statuses.get(ev)
                }
            try:
                with open(state_path, "w", encoding="utf-8") as sf:
                    json.dump(new_state, sf, indent=2)
                print(f"[STATE] State file updated: {state_path}")
            except Exception as se:
                print(f"WARNING: Failed to write state file: {se}")

            # Update src/.env with runtime agent IDs
            env_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..', 'src', '.env'))
            if os.path.exists(env_path):
                try:
                    import re

                    with open(env_path, 'r', encoding='utf-8') as f:
                        content = f.read()

                    content = content.replace("cognitiveservices.azure.com", "services.ai.azure.com")

                    for var, aid in deployed_agents.items():
                        pattern = rf'^{re.escape(var)}=.*$'
                        replacement = f'{var}={aid}'
                        if re.search(pattern, content, flags=re.MULTILINE):
                            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
                        else:
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
            else:
                print(f"INFO: .env file not found for agent ID propagation: {env_path}")

            print("\n" + "=" * 70)
            print("DEPLOYMENT SUMMARY")
            print("=" * 70)
            for k, v in deployed_agents.items():
                status = statuses.get(k, "unknown")
                print(f"  {k}: {v} [{status}]")

            payload = {"agents": deployed_agents, "statuses": statuses}
            print("===AGENTS_JSON_START===")
            print(json.dumps(payload, indent=2))
            print("===AGENTS_JSON_END===")

            return deployed_agents

        except Exception as e:
            print(
                "WARNING: AgentsClient provisioning failed; falling back to AIProjectClient path: "
                f"{e}. If this is '(unsupported_model)', ensure your AI Foundry has a real chat model "
                "deployment (e.g., 'gpt-4o-mini') and set AZURE_AI_AGENT_MODEL_DEPLOYMENT accordingly."
            )

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
            deployed_resource_ids[env_var] = fallback_id
            statuses[env_var] = "fallback-no-client"
            continue

        # Idempotent logic - check if agent already exists
        existing_agent = existing_agents.get(name) or existing_agents.get(sanitized_name)
        if existing_agent:
            agent_obj = existing_agent
            resource_id = _extract_agent_resource_id(agent_obj) or f"unknown-{env_var}"

            # Try to fetch full details to discover assistant_id (asst_...).
            detailed = _get_agent_details(project_client, resource_id)
            runtime_id = _extract_runtime_id(detailed or agent_obj, env_var)
            deployed_resource_ids[env_var] = resource_id
            
            # Attempt update if instructions changed
            if prior_hash and prior_hash != instr_hash:
                print(f"[{env_var}] Recreating agent (instructions changed): {name}")
                try:
                    try:
                        if hasattr(project_client.agents, "delete_agent"):
                            project_client.agents.delete_agent(agent_id=resource_id)
                        else:
                            project_client.agents.delete(resource_id)
                    except Exception:
                        pass

                    new_agent = _create_agent(
                        project_client,
                        model=_resolve_model_name(cfg["model"]),
                        name=sanitized_name,
                        instructions=instr,
                    )
                    resource_id = _extract_agent_resource_id(new_agent) or resource_id

                    detailed = _get_agent_details(project_client, resource_id)
                    runtime_id = _extract_runtime_id(detailed or new_agent, env_var)
                    deployed_resource_ids[env_var] = resource_id
                    statuses[env_var] = "recreated"
                    print(f"[{env_var}] Successfully recreated: runtime_id={runtime_id} resource_id={resource_id}")
                except Exception as ue:
                    print(f"[{env_var}] Failed to recreate {name}: {ue}")
                    statuses[env_var] = "existing-no-update"

                deployed_agents[env_var] = runtime_id
            else:
                print(f"[{env_var}] Reusing existing agent: {name} (runtime_id={runtime_id} resource_id={resource_id})")
                deployed_agents[env_var] = runtime_id
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
            resource_id = _extract_agent_resource_id(agent) or f"unknown-{env_var}"

            detailed = _get_agent_details(project_client, resource_id)
            runtime_id = _extract_runtime_id(detailed or agent, env_var)
            deployed_agents[env_var] = runtime_id
            deployed_resource_ids[env_var] = resource_id
            statuses[env_var] = "created"
            print(f"[{env_var}] SUCCESS - Created agent: runtime_id={runtime_id} resource_id={resource_id}")
        except Exception as ce:
            print(f"[{env_var}] FAILED to create {name}: {ce}")
            import traceback
            traceback.print_exc()
            
            # Use fallback local ID
            fallback_id = f"asst_local_{env_var}"
            deployed_agents[env_var] = fallback_id
            deployed_resource_ids[env_var] = fallback_id
            statuses[env_var] = "fallback-creation-failed"
            print(f"[{env_var}] Using fallback local simulation: {fallback_id}")

    # Persist state (hash + id)
    new_state = {}
    for cfg in agents_config:
        ev = cfg["env_var"]
        new_state[ev] = {
            "id": deployed_agents.get(ev),
            # Best-effort: keep the Foundry agent resource id for management/verification.
            # If we only have a runtime id, this may be the same value.
            "resource_id": deployed_resource_ids.get(ev),
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
    # NOTE: Terraform generates ../src/.env (workspace-relative).
    env_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..', 'src', '.env'))
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
