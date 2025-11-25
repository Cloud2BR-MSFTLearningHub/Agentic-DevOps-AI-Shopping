import os
import logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from dotenv import load_dotenv
import orjson
from app.tools.singleAgentExample import generate_response

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

# Fast JSON serialization
def fast_json_dumps(obj):
    return orjson.dumps(obj).decode("utf-8")

@app.get("/", response_class=HTMLResponse)
async def read_root(request: Request):
    """Serve the main chat interface"""
    return templates.TemplateResponse("index.html", {"request": request})

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    """WebSocket endpoint for real-time chat"""
    await websocket.accept()
    logger.info("WebSocket connection established")
    
    # Initialize persistent cart for the session
    persistent_cart = []
    
    try:
        while True:
            # Receive message from client
            data = await websocket.receive_text()
            user_message = data.strip()
            
            if not user_message:
                continue
            
            logger.info(f"Received message: {user_message}")
            
            # Single-agent example
            try:
                response = generate_response(user_message)
                await websocket.send_text(fast_json_dumps({"answer": response, "agent": "single", "cart": persistent_cart}))
                logger.info("Response sent successfully")
            except Exception as e:
                logger.error("Error during single-agent response generation", exc_info=True)
                await websocket.send_text(fast_json_dumps({"answer": "Error during single-agent response generation", "error": str(e), "cart": persistent_cart}))
                
    except WebSocketDisconnect:
        logger.info("WebSocket connection closed")
    except Exception as e:
        logger.error(f"WebSocket error: {e}", exc_info=True)

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "service": "Zava AI Shopping Assistant"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
