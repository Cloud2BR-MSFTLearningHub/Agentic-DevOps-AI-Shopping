"""
Quick verification that agents exist and are accessible via the correct endpoint.
This script uses .services.ai.azure.com endpoint.
"""
import os
import json
from pathlib import Path
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()


def _extract_agent_resource_id(agent_obj) -> str | None:
    if agent_obj is None:
        return None
    for attr in ("id", "agent_id", "agentId"):
        value = getattr(agent_obj, attr, None)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _extract_assistant_id(agent_obj) -> str | None:
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
    value = getattr(agent_obj, "id", None)
    if isinstance(value, str) and value.strip().startswith("asst"):
        return value.strip()
    return None

def verify_agents():
    """Verify agents are accessible via the correct endpoint"""
    
    # Get configuration
    project_endpoint = os.getenv("AZURE_AI_PROJECT_ENDPOINT") or os.getenv("AZURE_AI_FOUNDRY_ENDPOINT")
    sub_id = os.getenv("AZURE_SUBSCRIPTION_ID")
    rg = os.getenv("AZURE_RESOURCE_GROUP")
    project_name = os.getenv("AZURE_AI_PROJECT_NAME")
    
    if not project_endpoint:
        print("ERROR: AZURE_AI_PROJECT_ENDPOINT / AZURE_AI_FOUNDRY_ENDPOINT not configured")
        return False
    
    if not all([sub_id, rg, project_name]):
        print("ERROR: Missing required environment variables")
        print(f"  AZURE_SUBSCRIPTION_ID: {sub_id}")
        print(f"  AZURE_RESOURCE_GROUP: {rg}")
        print(f"  AZURE_AI_PROJECT_NAME: {project_name}")
        return False
    
    # Ensure we're using the correct domain
    if "cognitiveservices.azure.com" in project_endpoint:
        print("WARNING: Endpoint uses .cognitiveservices.azure.com")
        print(f"   Converting to .services.ai.azure.com for Agents API...")
        project_endpoint = project_endpoint.replace("cognitiveservices.azure.com", "services.ai.azure.com")
    
    # Construct proper project endpoint: https://<hub>.services.ai.azure.com/api/projects/<project>
    base_endpoint = project_endpoint.split("/api/")[0]  # Get just the base URL
    base_endpoint = base_endpoint.rstrip('/')
    full_project_endpoint = f"{base_endpoint}/api/projects/{project_name}"
    
    print("=" * 70)
    print("Verifying Multi-Agent Deployment")
    print("=" * 70)
    print(f"Endpoint (base): {base_endpoint}")
    print(f"Endpoint (full): {full_project_endpoint}")
    print()
    
    # Read expected agents from state file.
    # deploy_real_agents.py writes to terraform-infrastructure/.terraform/agents_state.json
    # but older versions of this script expected a local agents_state.json.
    candidates = [
        Path(__file__).resolve().parent / "agents_state.json",
        Path(__file__).resolve().parents[3] / "terraform-infrastructure" / ".terraform" / "agents_state.json",
    ]
    state_path = next((p for p in candidates if p.exists()), None)
    if not state_path:
        print("ERROR: No agents state file found. Tried:")
        for p in candidates:
            print(f"  - {p}")
        return False

    with open(state_path, 'r', encoding='utf-8') as f:
        expected_agents = json.load(f)
    
    print(f"Expected agents (from state file): {len(expected_agents)}")
    for name, data in expected_agents.items():
        rid = data.get("resource_id")
        aid = data.get("id")
        print(f"  - {name}: runtime_id={aid} resource_id={rid} ({data.get('status')})")
    print()
    
    # Try to connect and list agents
    try:
        credential = DefaultAzureCredential()
        
        # Create client with correct endpoint
        project_client = AIProjectClient(
            endpoint=full_project_endpoint,
            credential=credential
        )
        
        print("Fetching agents from Azure AI Foundry...")
        agents_list = list(project_client.agents.list())
        
        print(f"\nFound {len(agents_list)} agent(s) in Azure AI Foundry:")
        
        if len(agents_list) == 0:
            print("\nWARNING: No agents found!")
            print("   This could mean:")
            print("   1. Agents were not created successfully")
            print("   2. Wrong endpoint/credentials")
            print("   3. Agents exist but API permissions issue")
            return False
        
        # Display found agents
        for agent in agents_list:
            agent_resource_id = _extract_agent_resource_id(agent) or 'unknown'
            assistant_id = _extract_assistant_id(agent)
            agent_name = getattr(agent, 'name', 'unnamed')
            print(f"  [OK] {agent_name}")
            print(f"       resource_id: {agent_resource_id}")
            if assistant_id:
                print(f"       assistant_id: {assistant_id}")
        
        # Compare with expected
        found_resource_ids = set(_extract_agent_resource_id(a) or '' for a in agents_list)
        found_assistant_ids = set(_extract_assistant_id(a) or '' for a in agents_list)

        expected_runtime_ids = set(str(d.get('id', '') or '') for d in expected_agents.values())
        expected_resource_ids = set(str(d.get('resource_id', '') or '') for d in expected_agents.values())

        found_resource_ids.discard('')
        found_assistant_ids.discard('')
        expected_runtime_ids.discard('')
        expected_resource_ids.discard('')
        
        print("\nComparison:")
        print(f"  Expected runtime IDs:  {len(expected_runtime_ids)}")
        print(f"  Expected resource IDs: {len(expected_resource_ids)}")
        print(f"  Found assistant IDs:   {len(found_assistant_ids)}")
        print(f"  Found resource IDs:    {len(found_resource_ids)}")
        
        # An expected runtime id (often asst_*) should match found assistant ids.
        missing_runtime = expected_runtime_ids - found_assistant_ids
        # An expected resource id should match found resource ids.
        missing_resource = expected_resource_ids - found_resource_ids

        # Extra reporting (best-effort)
        extra_assistants = found_assistant_ids - expected_runtime_ids
        extra_resources = found_resource_ids - expected_resource_ids
        
        if missing_runtime:
            print(f"\nWARNING: Missing assistant/runtime IDs: {missing_runtime}")

        if missing_resource:
            print(f"WARNING: Missing agent resource IDs: {missing_resource}")
        
        if extra_assistants:
            print(f"\n  Extra assistant IDs found: {extra_assistants}")

        if extra_resources:
            print(f"  Extra resource IDs found: {extra_resources}")
        
        if not missing_runtime and not missing_resource:
            print("\n[SUCCESS] All expected agents are present!")
            return True
        else:
            print("\nWARNING: Agent count mismatch")
            # Pass if we've found at least all expected runtime IDs or all expected resource IDs.
            return (
                (expected_runtime_ids.issubset(found_assistant_ids) if expected_runtime_ids else True)
                and (expected_resource_ids.issubset(found_resource_ids) if expected_resource_ids else True)
            )
        
    except Exception as e:
        print(f"\nERROR: Failed to verify agents: {e}")
        import traceback
        traceback.print_exc()
        print("\nTroubleshooting:")
        print("  1. Check that Azure AI Foundry endpoint is correct")
        print("  2. Verify Azure CLI login: az login")
        print("  3. Check subscription and resource group settings")
        print(f"  4. Try accessing the portal directly:")
        print(f"     https://ai.azure.com/")
        return False

if __name__ == "__main__":
    success = verify_agents()
    
    if not success:
        print("\n" + "=" * 70)
        print("Agents may exist but are not accessible via the API.")
        print("Check the Azure AI Foundry portal manually:")
        print(f"  https://ai.azure.com/")
        print("=" * 70)
        exit(1)
    else:
        print("\n" + "=" * 70)
        print("[SUCCESS] Verification successful!")
        print("All agents are accessible and working.")
        print("=" * 70)
        exit(0)
