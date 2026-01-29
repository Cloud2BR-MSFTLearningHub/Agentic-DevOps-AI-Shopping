"""
Handoff Service for routing user queries to appropriate agents.
Uses GPT with structured output to classify user intent.
"""
import os
import json
from typing import Dict, Any, Optional
from pydantic import BaseModel
from azure.ai.inference import ChatCompletionsClient
from azure.core.credentials import AzureKeyCredential
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

from services.azure_auth import get_default_credential, get_inference_credential

load_dotenv()


class IntentClassification(BaseModel):
    """Structured output for intent classification"""
    domain: str
    reasoning: str
    confidence: float


class HandoffService:
    """
    Service to classify user intent and route to appropriate agent.
    
    Domains:
    - interior_design: Product recommendations, design advice, image generation
    - inventory: Stock availability, inventory checks
    - customer_loyalty: Discounts, loyalty program
    - cart_management: Add/remove items, checkout
    - cora: General queries, greetings, other
    """
    
    def __init__(self):
        """Initialize the handoff service with GPT client"""
        endpoint = (
            os.getenv("gpt_endpoint")
            or os.getenv("AZURE_OPENAI_ENDPOINT")
            or os.getenv("AZURE_AI_FOUNDRY_ENDPOINT")
        )
        api_key = (
            os.getenv("gpt_api_key")
            or os.getenv("AZURE_OPENAI_API_KEY")
            or os.getenv("AZURE_AI_FOUNDRY_API_KEY")
        )
        deployment = (
            os.getenv("gpt_deployment")
            or os.getenv("AZURE_OPENAI_CHAT_DEPLOYMENT")
            or os.getenv("AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME")
        )

        # Endpoint + deployment are required. API key is optional when using Managed Identity/AAD.
        if not all([endpoint, deployment]):
            raise ValueError("Missing GPT configuration in environment (endpoint and deployment required)")
        
        # Convert endpoint to Azure AI Foundry format
        foundry_endpoint = endpoint.replace('.cognitiveservices.', '.services.ai.')
        if '.services.azure.com' in foundry_endpoint and '.services.ai.azure.com' not in foundry_endpoint:
            foundry_endpoint = foundry_endpoint.replace('.services.azure.com', '.services.ai.azure.com')
        if not foundry_endpoint.endswith('/models'):
            foundry_endpoint = f"{foundry_endpoint.rstrip('/')}/models"
        
        if api_key:
            credential = AzureKeyCredential(api_key)
        else:
            credential = get_inference_credential(
                api_key=None,
                default_credential=get_default_credential(),
                endpoint=foundry_endpoint,
            )
        self.client = ChatCompletionsClient(endpoint=foundry_endpoint, credential=credential)
        self.deployment = deployment
    
    def classify_intent(
        self,
        user_message: str,
        conversation_history: Optional[list] = None
    ) -> Dict[str, Any]:
        """
        Classify user intent to determine which agent should handle the request.
        
        Args:
            user_message: The user's message
            conversation_history: Optional conversation context
        
        Returns:
            Dictionary with domain, reasoning, and confidence
        """
        # Build context from conversation history
        context = ""
        if conversation_history:
            recent_messages = conversation_history[-5:]  # Last 5 messages
            context = "\n".join([
                f"{'User' if msg.get('role') == 'user' else 'Assistant'}: {msg.get('content', '')}"
                for msg in recent_messages
            ])
        
        # Classification prompt
        system_prompt = """You are a routing assistant for Zava's multi-agent shopping system.
        
Classify user messages into one of these domains:

1. **interior_design**: 
   - Product recommendations (paint, furniture, decor)
   - Design advice, color suggestions
   - Room styling, DIY project help
   - Image-related requests
   
2. **inventory**:
   - Stock availability questions
   - "Do you have...", "Is X in stock?"
   - Inventory checks
   
3. **customer_loyalty**:
   - Discount inquiries
   - Loyalty program questions
   - "What discount do I get?"
   
4. **cart_management**:
   - Add/remove items from cart
   - "Add to cart", "Remove from cart"
   - View cart, checkout
   - Quantity updates
   
5. **cora** (general):
   - Greetings, chitchat
   - General company info
   - Anything not fitting above categories

Return your classification with reasoning and confidence (0.0-1.0).
"""
        
        user_prompt = f"""Conversation context:
{context if context else 'No previous context'}

Current user message: "{user_message}"

Classify this message into the appropriate domain."""
        
        try:
            # Call GPT for classification
            response = self.client.complete(
                model=self.deployment,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt}
                ],
                max_tokens=200,
                temperature=0.3
            )
            
            # Parse response
            response_text = response.choices[0].message.content.strip()
            
            # Simple parsing - look for domain keywords
            response_lower = response_text.lower()
            
            if "interior" in response_lower or "design" in response_lower:
                domain = "interior_design"
            elif "inventory" in response_lower or "stock" in response_lower:
                domain = "inventory"
            elif "loyalty" in response_lower or "discount" in response_lower:
                domain = "customer_loyalty"
            elif "cart" in response_lower or "checkout" in response_lower:
                domain = "cart_management"
            else:
                domain = "cora"
            
            return {
                "domain": domain,
                "reasoning": response_text,
                "confidence": 0.85
            }
            
        except Exception as e:
            # Default to cora on error
            return {
                "domain": "cora",
                "reasoning": f"Error during classification: {str(e)}",
                "confidence": 0.5
            }
