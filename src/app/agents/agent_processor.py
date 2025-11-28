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
        self.project_endpoint = project_endpoint or os.environ.get("AZURE_AI_AGENT_ENDPOINT")
        
        if not self.project_endpoint or not _REMOTE_AVAILABLE:
            raise ValueError("Remote agent support unavailable (endpoint or SDK missing)")
        self.client = AIProjectClient(endpoint=self.project_endpoint, credential=DefaultAzureCredential())
    
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
        try:
            # Create a thread for this conversation
            thread = self.client.agents.create_thread()
            
            # Build the message content
            message_content = user_message
            if additional_context:
                message_content = f"Context: {json.dumps(additional_context)}\n\nUser: {user_message}"
            
            # Add message to thread
            self.client.agents.create_message(
                thread_id=thread.id,
                role="user",
                content=message_content
            )
            
            # Run the agent
            run = self.client.agents.create_and_process_run(
                thread_id=thread.id,
                assistant_id=self.agent_id
            )
            
            # Get messages
            messages = self.client.agents.list_messages(thread_id=thread.id)
            
            # Find the assistant's response
            for message in messages:
                if message.role == "assistant":
                    for content in message.content:
                        if hasattr(content, 'text'):
                            yield content.text.value
            
            # Clean up
            self.client.agents.delete_thread(thread.id)
            
        except Exception as e:
            yield f"Error communicating with agent: {str(e)}"
