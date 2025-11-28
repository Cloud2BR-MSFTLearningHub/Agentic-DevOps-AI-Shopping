import os
import logging
import json
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
    return text

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


def get_agent_processor(domain: str):
    """Return a processor (remote if available, else local) for the domain."""
    agent_id_map = {
        "interior_design": os.getenv("interior_designer"),
        "inventory": os.getenv("inventory_agent"),
        "customer_loyalty": os.getenv("customer_loyalty"),
        "cart_management": os.getenv("cart_manager"),
        "cora": os.getenv("cora")
    }

    agent_id = agent_id_map.get(domain)
    if not agent_id:
        logger.warning(f"No agent ID found for domain: {domain}; using local fallback")
        return LocalAgentProcessor(agent_id=f"asst_local_{domain}", domain=domain)

    # Prefer remote only if endpoint exists and agent id looks like a remote id
    remote_endpoint = os.getenv("AZURE_AI_AGENT_ENDPOINT") or os.getenv("AZURE_AI_PROJECT_ENDPOINT")
    if remote_endpoint and agent_id.startswith("asst_") and not agent_id.startswith("asst_local_"):
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
                    
                    # Step 2: Get appropriate agent
                    agent_processor = get_agent_processor(domain)
                    
                    if not agent_processor:
                        # Instead of reverting to single-agent (which may lack config),
                        # emit a message explaining the missing processor.
                        warning = "Multi-agent processor unavailable; please verify configuration."
                        await websocket.send_text(fast_json_dumps({
                            "answer": warning,
                            "agent": "unassigned",
                            "cart": persistent_cart
                        }))
                        conversation_history.append({"role": "assistant", "content": warning})
                        continue
                    
                    # Step 3: Prepare context for agent
                    additional_context = {
                        "cart": persistent_cart,
                        "discount": customer_discount
                    }
                    
                    if domain == "cart_management":
                        # Cart manager needs full history
                        additional_context["conversation_history"] = conversation_history
                    
                    # Step 4: Call agent and stream response
                    response_text = ""
                    for chunk in agent_processor.run_conversation_with_text_stream(
                        user_message=user_message,
                        conversation_history=conversation_history[-5:],  # Last 5 messages
                        additional_context=additional_context
                    ):
                        response_text += chunk
                    
                    # Step 5: Parse response and flatten to a human answer
                    parsed_json: Dict[str, Any] | None = None
                    try:
                        parsed_json = json.loads(response_text)
                    except Exception:
                        # Try secondary parse if nested JSON inside 'answer'
                        if response_text.strip().startswith('{'):
                            try:
                                parsed_json = json.loads(response_text.strip())
                            except Exception:
                                parsed_json = None

                    if parsed_json:
                        if "cart" in parsed_json and isinstance(parsed_json["cart"], list):
                            persistent_cart = parsed_json["cart"]
                        if "discount_percentage" in parsed_json and parsed_json["discount_percentage"]:
                            customer_discount = parsed_json["discount_percentage"]
                        flattened = _flatten_response_json(parsed_json)
                        answer_text = _extract_plain_answer(flattened)
                        
                        # Extract image URL if present
                        image_url = parsed_json.get("image_url")
                    else:
                        answer_text = _extract_plain_answer(response_text)
                        image_url = None

                    # Send natural language answer with metadata
                    response_data = {
                        "answer": answer_text,
                        "agent": domain,
                        "cart": persistent_cart,
                        "discount": customer_discount
                    }
                    
                    # Include image URL if available
                    if image_url:
                        response_data["image_url"] = image_url
                    
                    await websocket.send_text(fast_json_dumps(response_data))

                    conversation_history.append({"role": "assistant", "content": answer_text})
                    
                    logger.info(f"Response sent successfully from {domain} agent")
                    
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
                logger.error("Error during response generation", exc_info=True)
                await websocket.send_text(fast_json_dumps({
                    "answer": "I'm sorry, I encountered an error processing your request. Please try again.",
                    "error": str(e),
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
