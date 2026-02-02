"""
Agent processor for handling interactions with Microsoft Foundry agents.
Includes MCP (Model Context Protocol) integration for tool calling.
"""
import os
import json
from typing import List, Dict, Any
try:
    from azure.ai.projects import AIProjectClient  # type: ignore
    from azure.identity import DefaultAzureCredential  # type: ignore
    from services.azure_auth import get_default_credential, get_inference_credential  # type: ignore
    try:
        # Preferred runtime client for threads/messages/runs
        from azure.ai.agents import AgentsClient  # type: ignore
    except Exception:
        AgentsClient = None  # type: ignore
    _REMOTE_AVAILABLE = True
except Exception:
    _REMOTE_AVAILABLE = False


def create_function_tool_for_agent(agent_name: str) -> List[Dict[str, Any]]:
    """
    Create function tools for a specific agent using MCP.
    
    Args:
        agent_name: Name of the agent (e.g., 'interior_designer', 'inventory_agent')
    
    Returns:
        List of function tool definitions
    """
    # Placeholder for MCP tool integration
    # In production, this would connect to MCP servers to get available tools
    tools = []
    
    # Define tools based on agent type
    if agent_name == "interior_designer":
        tools.append({
            "type": "function",
            "function": {
                "name": "create_image",
                "description": "Create or modify images based on user requirements",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "prompt": {"type": "string", "description": "Image generation prompt"},
                        "path": {"type": "string", "description": "Path to existing image (optional)"}
                    },
                    "required": ["prompt"]
                }
            }
        })
    
    elif agent_name == "inventory_agent":
        tools.append({
            "type": "function",
            "function": {
                "name": "inventory_check",
                "description": "Check inventory levels for products",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "product_dict": {
                            "type": "object",
                            "description": "Dictionary mapping product names to product IDs"
                        }
                    },
                    "required": ["product_dict"]
                }
            }
        })
    
    elif agent_name == "customer_loyalty":
        tools.append({
            "type": "function",
            "function": {
                "name": "customer_loyalty_check",
                "description": "Check customer loyalty status and calculate discount",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "customer_id": {"type": "string", "description": "Customer ID"}
                    },
                    "required": ["customer_id"]
                }
            }
        })
    
    elif agent_name == "cora":
        # Cora (shopper agent) might have general query tools
        tools.append({
            "type": "function",
            "function": {
                "name": "search_products",
                "description": "Search for products in catalog",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search query"}
                    },
                    "required": ["query"]
                }
            }
        })
    
    return tools


class AgentProcessor:
    """Handles communication with Microsoft Foundry agents"""
    
    def __init__(self, agent_id: str, project_endpoint: str = None):
        """
        Initialize agent processor.
        
        Args:
            agent_id: The agent ID from Microsoft Foundry
            project_endpoint: Optional project endpoint (reads from env if not provided)
        """
        self.agent_id = agent_id
        self._runtime_agent_id = agent_id

        raw_endpoint = (
            project_endpoint
            or os.environ.get("AZURE_AI_AGENT_ENDPOINT")
            or os.environ.get("AZURE_AI_PROJECT_ENDPOINT")
            or os.environ.get("AZURE_AI_FOUNDRY_ENDPOINT")
        )
        if not raw_endpoint or not _REMOTE_AVAILABLE:
            raise ValueError("Remote agent support unavailable (endpoint or SDK missing)")

        # The Azure AI Projects SDK expects: https://<hub>.services.ai.azure.com/api/projects/<project>
        project_name = os.environ.get("AZURE_AI_PROJECT_NAME")
        normalized = raw_endpoint.replace("cognitiveservices.azure.com", "services.ai.azure.com")

        if "/api/projects/" in normalized:
            # Already a full project endpoint
            full_project_endpoint = normalized.rstrip("/")
        elif project_name:
            base_endpoint = normalized.split("/api/")[0].rstrip("/")
            full_project_endpoint = f"{base_endpoint}/api/projects/{project_name}"
        else:
            # Best-effort fallback (may still work if the caller provided a full endpoint)
            full_project_endpoint = normalized.rstrip("/")

        self.project_endpoint = full_project_endpoint
        self.client = AIProjectClient(endpoint=self.project_endpoint, credential=get_default_credential())

        # Best-effort: resolve the underlying OpenAI-style assistant id (asst_...)
        # when the configured id is a friendly/name-based id.
        self._runtime_agent_id = self._maybe_resolve_assistant_id(self._runtime_agent_id)

        # Some azure-ai-projects builds expose only agent-management operations on .agents.
        # In that case, use azure-ai-agents AgentsClient for thread/message/run operations.
        self._agents_api = None
        try:
            if (
                hasattr(self.client, "agents")
                and hasattr(self.client.agents, "threads")
                and hasattr(self.client.agents.threads, "create")
                and hasattr(self.client.agents, "messages")
                and hasattr(self.client.agents.messages, "create")
                and hasattr(self.client.agents, "runs")
                and hasattr(self.client.agents.runs, "create_and_process")
            ):
                self._agents_api = self.client.agents
        except Exception:
            self._agents_api = None

        if self._agents_api is None:
            if AgentsClient is None:
                raise ValueError(
                    "Remote agent support unavailable: this SDK build doesn't expose threads on AIProjectClient.agents "
                    "and azure-ai-agents is not installed."
                )
            # AgentsClient expects the project endpoint (per Microsoft docs snippets).
            self._agents_api = AgentsClient(endpoint=self.project_endpoint, credential=get_default_credential())

    def _maybe_resolve_assistant_id(self, configured_id: str) -> str:
        if not configured_id:
            return configured_id
        # Local simulation stays untouched.
        if configured_id.startswith("asst_local_"):
            return configured_id
        # Already an assistant id.
        if configured_id.startswith("asst"):
            return configured_id

        try:
            agents = getattr(self.client, "agents", None)
            if not agents or not hasattr(agents, "list"):
                return configured_id
            for agent in agents.list():
                agent_id = getattr(agent, "id", None)
                agent_name = getattr(agent, "name", None)
                if configured_id not in {agent_id, agent_name}:
                    continue
                for attr in (
                    "assistant_id",
                    "assistantId",
                    "openai_assistant_id",
                    "openaiAssistantId",
                    "assistantID",
                ):
                    value = getattr(agent, attr, None)
                    if isinstance(value, str) and value.startswith("asst"):
                        return value
                # Some SDKs only populate `id` with an assistant id.
                if isinstance(agent_id, str) and agent_id.startswith("asst"):
                    return agent_id
        except Exception:
            # Best-effort only; keep configured value.
            return configured_id

        return configured_id

    @staticmethod
    def _get_obj_id(obj: Any) -> str | None:
        if obj is None:
            return None
        # SDK models can be rich objects or MutableMapping
        if hasattr(obj, "id"):
            return getattr(obj, "id")
        if isinstance(obj, dict):
            return obj.get("id")
        return None

    def _create_thread(self):
        agents = self._agents_api
        if hasattr(agents, "threads") and hasattr(agents.threads, "create"):
            return agents.threads.create()
        if hasattr(agents, "create_thread"):
            return agents.create_thread()
        raise AttributeError("No supported thread creation method on agents client")

    def _delete_thread(self, thread_id: str) -> None:
        agents = self._agents_api
        if hasattr(agents, "threads") and hasattr(agents.threads, "delete"):
            agents.threads.delete(thread_id)
            return
        if hasattr(agents, "delete_thread"):
            agents.delete_thread(thread_id)
            return

    def _create_message(self, thread_id: str, role: str, content: str) -> None:
        agents = self._agents_api
        if hasattr(agents, "messages") and hasattr(agents.messages, "create"):
            agents.messages.create(thread_id=thread_id, role=role, content=content)
            return
        if hasattr(agents, "create_message"):
            agents.create_message(thread_id=thread_id, role=role, content=content)
            return
        raise AttributeError("No supported message creation method on agents client")

    def _run_and_process(self, thread_id: str):
        agents = self._agents_api
        runtime_id = self._runtime_agent_id
        # Preferred (azure-ai-agents style)
        if hasattr(agents, "runs") and hasattr(agents.runs, "create_and_process"):
            # Different SDK builds use either `agent_id` or `assistant_id`.
            try:
                return agents.runs.create_and_process(thread_id=thread_id, agent_id=runtime_id)
            except TypeError:
                return agents.runs.create_and_process(thread_id=thread_id, assistant_id=runtime_id)
        # Older helper naming
        if hasattr(agents, "create_and_process_run"):
            # This helper is typically OpenAI-assistants shaped.
            return agents.create_and_process_run(thread_id=thread_id, assistant_id=runtime_id)
        # Some clients expose a one-shot convenience
        if hasattr(agents, "create_thread_and_process_run"):
            try:
                return agents.create_thread_and_process_run(agent_id=runtime_id)
            except TypeError:
                return agents.create_thread_and_process_run(assistant_id=runtime_id)
        raise AttributeError("No supported run method on agents client")

    def _list_messages(self, thread_id: str):
        agents = self._agents_api
        if hasattr(agents, "messages") and hasattr(agents.messages, "list"):
            return agents.messages.list(thread_id=thread_id)
        if hasattr(agents, "list_messages"):
            return agents.list_messages(thread_id=thread_id)
        raise AttributeError("No supported message listing method on agents client")
    
    def run_conversation_with_text_stream(
        self,
        user_message: str,
        conversation_history: List[Dict[str, str]] = None,
        additional_context: Dict[str, Any] = None
    ):
        """
        Run a conversation with the agent and stream the response.
        
        Args:
            user_message: The user's message
            conversation_history: Optional conversation history
            additional_context: Additional context to provide to the agent
        
        Yields:
            Chunks of the agent's response
        """
        thread_id: str | None = None
        try:
            # Create a thread for this conversation
            thread = self._create_thread()
            thread_id = self._get_obj_id(thread)
            if not thread_id:
                raise RuntimeError("Agent thread creation returned no id")
            
            # Build the message content
            message_content = user_message
            if additional_context:
                message_content = f"Context: {json.dumps(additional_context)}\n\nUser: {user_message}"
            
            # Add message to thread
            self._create_message(thread_id=thread_id, role="user", content=message_content)
            
            # Run the agent
            self._run_and_process(thread_id=thread_id)
            
            # Get messages
            messages = self._list_messages(thread_id=thread_id)
            
            # Find the assistant's response
            for message in messages:
                if message.role == "assistant":
                    # Message content can be a list of blocks or a mapping
                    contents = getattr(message, "content", None)
                    if isinstance(message, dict) and contents is None:
                        contents = message.get("content")
                    if not contents:
                        continue
                    for content in contents:
                        # SDK content blocks commonly expose .text.value
                        if hasattr(content, "text") and hasattr(content.text, "value"):
                            yield content.text.value
                        elif isinstance(content, dict):
                            text = content.get("text")
                            if isinstance(text, dict) and isinstance(text.get("value"), str):
                                yield text["value"]
                            elif isinstance(text, str):
                                yield text
                        elif isinstance(content, str):
                            yield content
            
        except Exception as e:
            yield f"Error communicating with agent: {str(e)}"
        finally:
            if thread_id:
                try:
                    self._delete_thread(thread_id)
                except Exception:
                    # Best-effort cleanup; ignore failures
                    pass
