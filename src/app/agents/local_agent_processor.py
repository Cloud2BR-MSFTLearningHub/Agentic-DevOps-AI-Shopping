import json
import os
import logging
import traceback
import uuid
from typing import List, Dict, Any, Generator
from azure.ai.inference import ChatCompletionsClient
from azure.core.credentials import AzureKeyCredential
from azure.identity import DefaultAzureCredential

from services.azure_auth import get_default_credential, get_inference_credential

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
        self.logger = logging.getLogger("local_agent_processor")
        self._debug = os.getenv("A2A_DEBUG", "").lower() in {"1", "true", "yes"}
        self._last_error_id: str | None = None
        self._last_error_detail: str | None = None
        if self._debug:
            self.logger.setLevel(logging.DEBUG)
        
        # Initialize GPT client (shared across all agents)
        endpoint = (
            os.getenv("gpt_endpoint")
            or os.getenv("AZURE_OPENAI_ENDPOINT")
            or os.getenv("AZURE_AI_FOUNDRY_ENDPOINT")
            or ""
        )
        api_key = (
            os.getenv("gpt_api_key")
            or os.getenv("AZURE_OPENAI_API_KEY")
            or os.getenv("AZURE_AI_FOUNDRY_API_KEY")
            or ""
        )
        deployment = (
            os.getenv("gpt_deployment")
            or os.getenv("AZURE_OPENAI_CHAT_DEPLOYMENT")
            or os.getenv("AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME")
            or "gpt-4o-mini"
        )

        self.use_gpt = False
        self.client = None
        self.model = deployment
        self._inference_endpoint: str | None = None
        self._using_key_auth: bool = False

        # Default to managed identity / Entra ID auth in Azure.
        # Only use key-based auth when explicitly enabled.
        self._prefer_aad: bool = os.getenv("A2A_PREFER_AAD", "true").lower() in {"1", "true", "yes"}
        self._allow_key_auth: bool = os.getenv("A2A_USE_KEY_AUTH", "").lower() in {"1", "true", "yes"}

        if endpoint and deployment:
            # Convert endpoint to Foundry format if needed
            foundry_endpoint = endpoint.replace('.cognitiveservices.', '.services.ai.')
            if '.services.azure.com' in foundry_endpoint and '.services.ai.azure.com' not in foundry_endpoint:
                foundry_endpoint = foundry_endpoint.replace('.services.azure.com', '.services.ai.azure.com')
            if not foundry_endpoint.endswith('/models'):
                foundry_endpoint = f"{foundry_endpoint.rstrip('/')}/models"

            self._inference_endpoint = foundry_endpoint

            try:
                # Prefer token-based auth (Managed Identity in cloud).
                # Keys are often disabled (disableLocalAuth) and should be opt-in.
                if api_key and self._allow_key_auth and not self._prefer_aad:
                    credential = AzureKeyCredential(api_key)
                    self._using_key_auth = True
                else:
                    credential = get_inference_credential(
                        api_key=None,
                        default_credential=get_default_credential(),
                        endpoint=foundry_endpoint,
                    )
                    self._using_key_auth = False
                self.client = ChatCompletionsClient(endpoint=foundry_endpoint, credential=credential)
                self.use_gpt = True
            except Exception:
                self.logger.exception("Failed to initialize ChatCompletionsClient (endpoint=%s, deployment=%s)", foundry_endpoint, deployment)
                self.use_gpt = False

    def _format_exception_detail(self, error_id: str, exc: Exception) -> str:
        """Format a detailed, UI-safe error message for troubleshooting."""
        parts: list[str] = []
        parts.append(f"error_id={error_id}")
        parts.append(f"agent_domain={self.domain}")
        parts.append(f"model={self.model}")
        parts.append(f"endpoint={self._inference_endpoint}")
        parts.append(f"auth_mode={'key' if self._using_key_auth else 'aad'}")

        # Helpful identity context when running on Azure
        azure_client_id = os.getenv("AZURE_CLIENT_ID")
        if azure_client_id:
            parts.append(f"AZURE_CLIENT_ID={azure_client_id}")

        parts.append(f"exception_type={type(exc).__name__}")
        parts.append(f"exception={str(exc)}")

        # Try to extract HTTP response details if present
        response = getattr(exc, "response", None)
        if response is not None:
            status_code = getattr(response, "status_code", None)
            if status_code is not None:
                parts.append(f"http_status={status_code}")

            headers = getattr(response, "headers", None) or {}
            for header_name in ("x-ms-request-id", "x-ms-client-request-id", "x-ms-correlation-request-id"):
                header_value = headers.get(header_name)
                if header_value:
                    parts.append(f"{header_name}={header_value}")

        status_code = getattr(exc, "status_code", None)
        if status_code is not None and "http_status=" not in "\n".join(parts):
            parts.append(f"http_status={status_code}")

        # Include traceback only in debug mode
        if self._debug:
            parts.append("traceback=\n" + traceback.format_exc())

        return "\n".join(parts)

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
            self._last_error_id = None
            self._last_error_detail = None
            return response.choices[0].message.content
        except Exception as e:
            # If we attempted key auth and the resource has local auth disabled,
            # transparently retry once with Entra ID (managed identity) auth.
            if self._using_key_auth and self._inference_endpoint:
                try:
                    error_code = getattr(e, "error", None)
                    if hasattr(e, "response") and getattr(getattr(e, "response", None), "status_code", None) == 403:
                        # Heuristic: the common case we see is AuthenticationTypeDisabled.
                        msg = str(e) or ""
                        if "AuthenticationTypeDisabled" in msg or "Key based authentication is disabled" in msg:
                            self.logger.warning(
                                "Key auth disabled for inference endpoint; retrying with AAD (domain=%s, endpoint=%s)",
                                self.domain,
                                self._inference_endpoint,
                            )
                            aad_cred = get_inference_credential(
                                api_key=None,
                                default_credential=get_default_credential(),
                                endpoint=self._inference_endpoint,
                            )
                            self.client = ChatCompletionsClient(endpoint=self._inference_endpoint, credential=aad_cred)
                            self._using_key_auth = False
                            retry = self.client.complete(
                                messages=messages,
                                model=self.model,
                                temperature=0.7,
                                max_tokens=500,
                            )
                            self._last_error_id = None
                            self._last_error_detail = None
                            return retry.choices[0].message.content
                except Exception:
                    # Fall through to normal error handling
                    pass

            error_id = uuid.uuid4().hex
            self._last_error_id = error_id
            self._last_error_detail = self._format_exception_detail(error_id, e)
            self.logger.exception(
                "GPT call failed (error_id=%s, domain=%s, endpoint=%s, model=%s)",
                error_id,
                self.domain,
                self._inference_endpoint,
                self.model,
            )
            return f"I'm having trouble connecting right now. (error_id={error_id})"
    
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
                        result['answer'] = f"{answer}\n\n[IMAGE] I've generated a visualization for you!"
            except Exception as e:
                # Don't fail the whole request if image generation fails
                result['answer'] = f"{answer}\n\n(Note: Image generation unavailable at the moment)"
        
        return result

    def _inventory(self, user_message: str, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        answer = self._call_gpt(user_message, conversation_history, additional_context)
        result: Dict[str, Any] = {"answer": answer}
        if self._last_error_detail:
            result["error"] = self._last_error_detail
            result["error_id"] = self._last_error_id
        return result

    def _customer_loyalty(self, customer_id: str | None, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        user_message = f"Check loyalty benefits for customer {customer_id or 'current customer'}"
        answer = self._call_gpt(user_message, conversation_history, additional_context)
        result: Dict[str, Any] = {"answer": answer, "discount_percentage": "10"}
        if self._last_error_detail:
            result["error"] = self._last_error_detail
            result["error_id"] = self._last_error_id
        return result

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
        result: Dict[str, Any] = {"answer": answer, "cart": cart}
        if self._last_error_detail:
            result["error"] = self._last_error_detail
            result["error_id"] = self._last_error_id
        return result

    def _cora(self, user_message: str, conversation_history: List[Dict[str, str]] | None = None, additional_context: Dict[str, Any] | None = None) -> Dict[str, Any]:
        answer = self._call_gpt(user_message, conversation_history, additional_context)
        result: Dict[str, Any] = {"answer": answer}
        if self._last_error_detail:
            result["error"] = self._last_error_detail
            result["error_id"] = self._last_error_id
        return result

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
