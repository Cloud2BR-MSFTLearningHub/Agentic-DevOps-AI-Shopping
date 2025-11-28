import json
import os
from typing import List, Dict, Any, Generator
from azure.ai.inference import ChatCompletionsClient
from azure.core.credentials import AzureKeyCredential

try:
    from app.agents.agents_config import AGENT_INSTRUCTIONS
except Exception:
    # Fallback if agents_config has issues
    AGENT_INSTRUCTIONS = {
        'cora': 'You are Cora, a knowledgeable and helpful shopping assistant for Zava, a home improvement and hardware store.',
        'interior_design': 'You are an interior design specialist at Zava. Provide creative design advice and product recommendations.',
        'inventory': 'You are an inventory specialist at Zava. Help customers check product availability and stock levels.',
        'customer_loyalty': 'You are a customer loyalty specialist at Zava. Help customers understand their rewards and discounts.',
        'cart_management': 'You are a shopping cart assistant at Zava. Help customers manage their cart items.'
    }

try:
    from services.image_service import get_image_service
    IMAGE_SERVICE_AVAILABLE = True
except Exception:
    IMAGE_SERVICE_AVAILABLE = False

class LocalAgentProcessor:
    """Local agent implementation using GPT with domain-specific prompts.

    Each agent uses the same GPT model but with different system prompts,
    creating distinct personas for different shopping domains.
    """
    def __init__(self, agent_id: str, domain: str):
        self.agent_id = agent_id
        self.domain = domain
        
        # Initialize GPT client (shared across all agents)
        endpoint = os.getenv("gpt_endpoint", "")
        api_key = os.getenv("gpt_api_key", "")
        deployment = os.getenv("gpt_deployment", "gpt-4o-mini")
        
        # Convert endpoint to Foundry format if needed
        if endpoint:
            foundry_endpoint = endpoint.replace('.cognitiveservices.', '.services.ai.')
            if '.services.azure.com' in foundry_endpoint and '.services.ai.azure.com' not in foundry_endpoint:
                foundry_endpoint = foundry_endpoint.replace('.services.azure.com', '.services.ai.azure.com')
            if not foundry_endpoint.endswith('/models'):
                foundry_endpoint = f"{foundry_endpoint.rstrip('/')}/models"
        
        self.use_gpt = bool(endpoint and api_key)
        if self.use_gpt:
            try:
                self.client = ChatCompletionsClient(
                    endpoint=foundry_endpoint,
                    credential=AzureKeyCredential(api_key)
                )
                self.model = deployment
            except Exception:
                self.use_gpt = False

    def _call_gpt(self, user_message: str, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> str:
        """Call GPT with domain-specific system prompt."""
        if not self.use_gpt:
            return f"I'm your {self.domain.replace('_', ' ')} assistant. {user_message[:50]}... (GPT unavailable)"
        
        try:
            # Build system prompt
            system_prompt = AGENT_INSTRUCTIONS.get(self.domain, "You are a helpful assistant.")
            
            # Add context if available
            if additional_context:
                if additional_context.get("cart"):
                    system_prompt += f"\n\nCurrent cart: {json.dumps(additional_context['cart'])}"
                if additional_context.get("discount"):
                    system_prompt += f"\nCustomer discount: {additional_context['discount']}%"
            
            # Build messages
            messages = [{"role": "system", "content": system_prompt}]
            
            # Add conversation history (last few messages)
            if conversation_history:
                messages.extend(conversation_history[-5:])
            
            # Add current message
            messages.append({"role": "user", "content": user_message})
            
            # Call GPT
            response = self.client.complete(
                messages=messages,
                model=self.model,
                temperature=0.7,
                max_tokens=500
            )
            
            return response.choices[0].message.content
        except Exception as e:
            return f"I'm having trouble connecting right now. Error: {str(e)[:100]}"
    
    def _interior_design(self, user_message: str, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        # Check if this is an image generation request
        lower_msg = user_message.lower()
        image_keywords = ['generate image', 'create image', 'visualize', 'show me', 'design image', 'picture of']
        
        should_generate_image = any(keyword in lower_msg for keyword in image_keywords)
        
        # Get text answer from GPT
        answer = self._call_gpt(user_message, conversation_history, additional_context)
        
        result = {"answer": answer}
        
        # Generate image if requested and service is available
        if should_generate_image and IMAGE_SERVICE_AVAILABLE:
            try:
                image_service = get_image_service()
                if image_service.is_configured():
                    # Create image prompt from user message and GPT response
                    image_prompt = f"{user_message}. {answer[:200]}"
                    image_result = image_service.generate_image(image_prompt)
                    
                    if image_result['success']:
                        result['image_url'] = image_result['blob_url'] or image_result['image_url']
                        result['image_prompt'] = image_result['prompt']
                        # Append image info to answer
                        result['answer'] = f"{answer}\n\n🖼️ I've generated a visualization for you!"
            except Exception as e:
                # Don't fail the whole request if image generation fails
                result['answer'] = f"{answer}\n\n(Note: Image generation unavailable at the moment)"
        
        return result

    def _inventory(self, user_message: str, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        answer = self._call_gpt(user_message, conversation_history, additional_context)
        return {"answer": answer}

    def _customer_loyalty(self, customer_id: str | None, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        user_message = f"Check loyalty benefits for customer {customer_id or 'current customer'}"
        answer = self._call_gpt(user_message, conversation_history, additional_context)
        return {"answer": answer, "discount_percentage": "10"}

    def _cart_management(self, user_message: str, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        cart = additional_context.get("cart", []) if additional_context else []
        lower_msg = user_message.lower()
        
        # Handle cart operations
        if lower_msg.startswith("add "):
            item = user_message[4:].strip()
            if item:
                cart.append({"product": item, "qty": 1})
        elif lower_msg.startswith("remove "):
            item = user_message[7:].strip()
            cart = [c for c in cart if c.get("product") != item]
        
        # Get GPT response about the cart action
        answer = self._call_gpt(user_message, conversation_history, {"cart": cart})
        return {"answer": answer, "cart": cart}

    def _cora(self, user_message: str, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        answer = self._call_gpt(user_message, conversation_history, additional_context)
        return {"answer": answer}

    def run_conversation_with_text_stream(
        self,
        user_message: str,
        conversation_history: List[Dict[str, str]] | None = None,
        additional_context: Dict[str, Any] | None = None
    ) -> Generator[str, None, None]:
        """Yield response chunks (single chunk for local processor)."""
        additional_context = additional_context or {}
        try:
            if self.domain == "interior_design":
                payload = self._interior_design(user_message, conversation_history, additional_context)
            elif self.domain == "inventory":
                payload = self._inventory(user_message, conversation_history, additional_context)
            elif self.domain == "customer_loyalty":
                payload = self._customer_loyalty(additional_context.get("customer_id"), conversation_history, additional_context)
            elif self.domain == "cart_management":
                payload = self._cart_management(user_message, conversation_history, additional_context)
            else:  # cora or unknown
                payload = self._cora(user_message, conversation_history, additional_context)
            yield json.dumps(payload)
        except Exception as e:
            yield json.dumps({"answer": f"I apologize, but I'm having trouble right now. Please try again. ({str(e)[:50]})"})
