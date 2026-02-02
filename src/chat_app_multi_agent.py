import os
import logging
import json
import uuid
import traceback
from typing import Any, Dict
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv
import orjson

try:
    from app.tools.singleAgentExample import generate_response as single_agent_generate_response
    SINGLE_AGENT_AVAILABLE = True
except Exception:
    SINGLE_AGENT_AVAILABLE = False

from services.handoff_service import HandoffService
from app.agents.agent_processor import AgentProcessor
from app.agents.local_agent_processor import LocalAgentProcessor

# Load environment variables
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def _debug_enabled() -> bool:
    return os.getenv("A2A_DEBUG", "").lower() in {"1", "true", "yes"}


def _format_exception_for_client(error_id: str, exc: Exception) -> str:
    parts: list[str] = [f"error_id={error_id}", f"exception_type={type(exc).__name__}", f"exception={str(exc)}"]
    if _debug_enabled():
        parts.append("traceback=\n" + traceback.format_exc())
    return "\n".join(parts)

# Initialize FastAPI app
app = FastAPI(title="Zava AI Shopping Assistant")

# Mount templates
templates = Jinja2Templates(directory="app/templates")

# Lazy initialization for handoff service
_handoff_service = None

def get_handoff_service():
    global _handoff_service
    if _handoff_service is None:
        try:
            _handoff_service = HandoffService()
        except Exception as e:
            logger.error(f"Failed to initialize HandoffService: {e}")
            return None
    return _handoff_service

# Fast JSON serialization
def fast_json_dumps(obj):
    return orjson.dumps(obj).decode("utf-8")


def _extract_plain_answer(raw: str) -> str:
    """Return a human-friendly answer string.

    If raw looks like JSON with an 'answer' field, extract it. Otherwise
    return raw unchanged. Also strips wrapping quotes and braces.
    """
    text = raw.strip()
    if text.startswith('{') and '"answer"' in text:
        try:
            parsed = json.loads(text)
            inner = parsed.get('answer')
            if isinstance(inner, str):
                return inner.strip()
        except Exception:
            pass

    # Support legacy non-JSON "answer: ...\nimage_output: ...\nproducts: ..." blocks.
    legacy = _parse_legacy_kv_block(text)
    if legacy and isinstance(legacy.get("answer"), str):
        return legacy["answer"].strip()
    return text


def _parse_legacy_kv_block(text: str) -> Dict[str, Any] | None:
    """Parse legacy key-value blocks emitted by older prompts.

    Example input:
      answer: hello there
      image_output: []
      products: []

    Returns a dict with keys when recognized, else None.
    """
    if not text:
        return None

    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines:
        return None

    # Quick reject: must contain at least an answer line.
    has_answer = any(ln.lower().startswith("answer:") for ln in lines)
    if not has_answer:
        return None

    parsed: Dict[str, Any] = {}
    for line in lines:
        # Only parse simple "key: value" lines.
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        value = value.strip().rstrip(",")

        if key in {"answer", "image_output", "products"}:
            if key == "answer":
                parsed["answer"] = value
                continue

            # Try to JSON-decode arrays/objects, otherwise keep as string.
            try:
                parsed[key] = json.loads(value)
            except Exception:
                parsed[key] = value

    return parsed or None

def _flatten_response_json(response_json: Dict[str, Any]) -> str:
    """Derive a single natural language answer from structured fields."""
    base = response_json.get('answer') or ''
    parts = [base.strip()] if isinstance(base, str) else []
    # Append discount info if present
    discount = response_json.get('discount') or response_json.get('discount_percentage')
    if discount:
        parts.append(f"Loyalty discount available: {discount}%.")
    # Summarize cart if present
    cart = response_json.get('cart')
    if isinstance(cart, list) and cart:
        items = ', '.join([c.get('product','?') for c in cart])
        parts.append(f"Cart items: {items}.")
    # Summarize products list if provided
    products = response_json.get('products')
    if isinstance(products, list) and products:
        names = ', '.join([p.get('name') or p.get('ProductName') or 'item' for p in products][:5])
        parts.append(f"Suggested products: {names}.")
    # Join and clean double spaces
    final = ' '.join([p for p in parts if p]).strip()
    return final or '(No response)'


def _get_env_any(*names: str) -> str | None:
    for name in names:
        value = os.getenv(name)
        if value:
            return value
    return None


def _plan_handoff_sequence(domain: str, user_message: str) -> list[str]:
    """Plan a minimal agent handoff sequence.

    This is the missing piece for "agents talking to each other" in the chat UI.
    The UI still sends a single user message, but the server can delegate to
    multiple specialist agents and pass context forward.
    """
    msg = (user_message or "").lower()

    # Always start with the classified domain.
    sequence: list[str] = [domain]

    # Product discovery and comparison are best handled by product management.
    if any(k in msg for k in ["recommend", "recommendation", "find", "search", "compare", "best", "popular", "spec", "specification"]):
        if "product_management" not in sequence:
            sequence.append("product_management")

    # Design requests often benefit from product discovery afterwards.
    if any(k in msg for k in ["design", "interior", "room", "layout", "style", "color", "paint", "decor", "furniture"]):
        if "interior_design" not in sequence:
            sequence.append("interior_design")
        if "product_management" not in sequence:
            sequence.append("product_management")

    # Purchase intent: check inventory then cart.
    if any(k in msg for k in ["buy", "purchase", "checkout", "order", "add to cart", "add this", "add it", "remove from cart"]):
        if "inventory" not in sequence:
            sequence.append("inventory")
        if "cart_management" not in sequence:
            sequence.append("cart_management")

    # Discounts: consult loyalty.
    if any(k in msg for k in ["discount", "loyalty", "points", "member", "reward", "promo", "promotion", "deal"]):
        if "customer_loyalty" not in sequence:
            sequence.append("customer_loyalty")

    # Cap to avoid runaway chains.
    return sequence[:4]


def get_agent_processor(domain: str):
    """Return a processor (remote if available, else local) for the domain."""
    agent_id_map = {
        "interior_design": _get_env_any("interior_designer", "AGENT_INTERIOR_DESIGNER_ID"),
        "inventory": _get_env_any("inventory_agent", "AGENT_INVENTORY_AGENT_ID"),
        "customer_loyalty": _get_env_any("customer_loyalty", "AGENT_CUSTOMER_LOYALTY_ID"),
        "cart_management": _get_env_any("cart_manager", "AGENT_CART_MANAGER_ID"),
        "cora": _get_env_any("cora", "AGENT_CORA_ID"),
        "product_management": _get_env_any("product_management", "AGENT_PRODUCT_MANAGEMENT_ID"),
    }

    agent_id = agent_id_map.get(domain)
    if not agent_id:
        logger.warning(f"No agent ID found for domain: {domain}; using local fallback")
        return LocalAgentProcessor(agent_id=f"asst_local_{domain}", domain=domain)

    # Prefer remote only if endpoint exists and agent id looks like a remote id
    remote_endpoint = os.getenv("AZURE_AI_AGENT_ENDPOINT") or os.getenv("AZURE_AI_PROJECT_ENDPOINT")
    # Real Foundry agent IDs are not guaranteed to start with "asst_" (some SDKs/services use
    # a name-based ID). Treat only explicit "asst_local_*" as local simulation.
    if remote_endpoint and not agent_id.startswith("asst_local_"):
        try:
            return AgentProcessor(agent_id=agent_id, project_endpoint=remote_endpoint)
        except Exception as e:
            logger.warning(f"Remote agent init failed for {domain}: {e}; falling back to local")
            return LocalAgentProcessor(agent_id=agent_id, domain=domain)
    else:
        return LocalAgentProcessor(agent_id=agent_id, domain=domain)


@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    """Serve the main chat interface"""
    return templates.TemplateResponse("index.html", {"request": request})


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time chat"""
    await websocket.accept()
    logger.info("WebSocket connection established")
    
    # Session state
    persistent_cart = []
    conversation_history = []
    customer_discount = None
    # Default to multi-agent; only disable if explicitly set to false
    use_multi_agent = os.getenv("USE_MULTI_AGENT", "true").lower() != "false"
    
    try:
        # Check if we should use multi-agent mode
        if use_multi_agent:
            logger.info("Multi-agent mode enabled (local simulation if remote unavailable)")
            
            # Initialize customer loyalty check in background
            try:
                loyalty_agent = get_agent_processor("customer_loyalty")
                if loyalty_agent:
                    customer_id = os.getenv("CUSTOMER_ID", "CUST001")
                    logger.info(f"Checking loyalty for customer: {customer_id}")
                    # This would run the loyalty check - simplified for now
                    customer_discount = "10"  # Placeholder
            except Exception as e:
                logger.error(f"Error checking customer loyalty: {e}")
        else:
            logger.info("Single-agent mode (legacy)")
        
        while True:
            # Receive message from client
            data = await websocket.receive_text()
            user_message = data.strip()
            
            if not user_message:
                continue
            
            logger.info(f"Received message: {user_message}")
            
            # Add to conversation history
            conversation_history.append({"role": "user", "content": user_message})
            
            try:
                if use_multi_agent:
                    # === MULTI-AGENT MODE ===
                    
                    # Step 1: Classify intent
                    svc = get_handoff_service()
                    if not svc:
                        logger.warning("HandoffService unavailable; defaulting to 'cora'")
                        classification = {"domain": "cora", "confidence": 1.0, "reasoning": "HandoffService unavailable"}
                    else:
                        classification = svc.classify_intent(
                            user_message=user_message,
                            conversation_history=conversation_history
                        )
                    
                    domain = classification["domain"]
                    logger.info(f"Classified as domain: {domain} (confidence: {classification['confidence']})")

                    # Step 2: Plan handoffs and execute sequence
                    sequence = _plan_handoff_sequence(domain, user_message)
                    logger.info(f"Multi-agent handoff sequence: {sequence}")

                    agent_outputs: list[dict[str, Any]] = []
                    last_parsed_json: Dict[str, Any] | None = None
                    last_domain = domain

                    for step_idx, step_domain in enumerate(sequence):
                        agent_processor = get_agent_processor(step_domain)
                        if not agent_processor:
                            raise RuntimeError(f"No agent processor available for domain={step_domain}")

                        additional_context = {
                            "cart": persistent_cart,
                            "discount": customer_discount,
                            "handoff": {
                                "step": step_idx + 1,
                                "sequence": sequence,
                                "previous_outputs": agent_outputs[-3:],
                            },
                        }
                        if step_domain == "cart_management":
                            additional_context["conversation_history"] = conversation_history

                        response_text = ""
                        for chunk in agent_processor.run_conversation_with_text_stream(
                            user_message=user_message,
                            conversation_history=conversation_history[-5:],
                            additional_context=additional_context,
                        ):
                            response_text += chunk

                        parsed_json: Dict[str, Any] | None = None
                        try:
                            parsed_json = json.loads(response_text)
                        except Exception:
                            parsed_json = None

                        if parsed_json and isinstance(parsed_json, dict):
                            # Lift nested JSON if present.
                            if isinstance(parsed_json.get("answer"), str):
                                legacy = _parse_legacy_kv_block(parsed_json["answer"])
                                if legacy:
                                    parsed_json.update({k: v for k, v in legacy.items() if v is not None})
                            if "cart" in parsed_json and isinstance(parsed_json["cart"], list):
                                persistent_cart = parsed_json["cart"]
                            if "discount_percentage" in parsed_json and parsed_json["discount_percentage"]:
                                customer_discount = parsed_json["discount_percentage"]
                            last_parsed_json = parsed_json

                        agent_outputs.append({
                            "agent": step_domain,
                            "raw": response_text,
                            "parsed": parsed_json,
                        })
                        last_domain = step_domain

                    # Step 3: Build final response from last agent result
                    if last_parsed_json:
                        flattened = _flatten_response_json(last_parsed_json)
                        answer_text = _extract_plain_answer(flattened)
                        image_url = last_parsed_json.get("image_url")
                    else:
                        answer_text = _extract_plain_answer(agent_outputs[-1]["raw"] if agent_outputs else "")
                        image_url = None

                    response_data = {
                        "answer": answer_text,
                        "agent": last_domain,
                        "cart": persistent_cart,
                        "discount": customer_discount,
                    }

                    # Forward structured fields if present.
                    if last_parsed_json:
                        if "products" in last_parsed_json:
                            response_data["products"] = last_parsed_json.get("products")
                        if "image_output" in last_parsed_json:
                            response_data["image_output"] = last_parsed_json.get("image_output")
                        if isinstance(last_parsed_json.get("error"), str):
                            response_data["error"] = last_parsed_json["error"]
                        if last_parsed_json.get("error_id") is not None:
                            response_data["error_id"] = last_parsed_json.get("error_id")
                    if image_url:
                        response_data["image_url"] = image_url

                    await websocket.send_text(fast_json_dumps(response_data))
                    conversation_history.append({"role": "assistant", "content": answer_text})
                    logger.info(f"Response sent successfully (final agent={last_domain})")
                    
                else:
                    # === SINGLE-AGENT MODE (Legacy) ===
                    response = single_agent_generate_response(user_message)
                    await websocket.send_text(fast_json_dumps({
                        "answer": response,
                        "agent": "single",
                        "cart": persistent_cart
                    }))
                    conversation_history.append({"role": "assistant", "content": response})
                    logger.info("Response sent successfully from single agent")
                    
            except Exception as e:
                error_id = uuid.uuid4().hex
                logger.error("Error during response generation (error_id=%s)", error_id, exc_info=True)
                await websocket.send_text(fast_json_dumps({
                    "answer": f"I'm sorry, I encountered an error processing your request. Please try again. (error_id={error_id})",
                    "error": _format_exception_for_client(error_id, e),
                    "cart": persistent_cart
                }))
                
    except WebSocketDisconnect:
        logger.info("WebSocket connection closed")
    except Exception as e:
        logger.error(f"WebSocket error: {e}", exc_info=True)


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    mode = "multi-agent" if os.getenv("USE_MULTI_AGENT", "false").lower() == "true" else "single-agent"
    return {
        "status": "healthy",
        "service": "Zava AI Shopping Assistant",
        "mode": mode,
        "agent_endpoint_configured": bool(os.getenv("AZURE_AI_AGENT_ENDPOINT"))
    }

@app.get("/agents")
async def agents_info():
    """Diagnostic endpoint listing active (local or remote) agent IDs."""
    agent_vars = ["cora", "interior_designer", "inventory_agent", "customer_loyalty", "cart_manager"]
    agents = {k: os.getenv(k) for k in agent_vars}
    return {
        "mode": "multi-agent" if os.getenv("USE_MULTI_AGENT", "false").lower() == "true" else "single-agent",
        "remote_endpoint": os.getenv("AZURE_AI_AGENT_ENDPOINT") or os.getenv("AZURE_AI_PROJECT_ENDPOINT"),
        "agents": agents,
        "all_present": all(agents.values()),
        "note": "Local pseudo agents are used if IDs start with asst_local_"
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
