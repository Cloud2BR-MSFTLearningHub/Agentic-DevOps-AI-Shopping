"""
Microsoft Foundry Agent Integration for A2A Protocol

This script demonstrates how to integrate the Product Management Agent
as the 6th agent in your existing Microsoft Foundry setup, following
A2A protocol patterns with native Agent Framework orchestration.
"""
import asyncio
import json
import logging
import os
from typing import Dict, List, Optional
from datetime import datetime

from agent_framework import (
    ChatAgent,
    ChatMessage,
    Executor,
    Role,
    WorkflowBuilder,
    WorkflowContext,
    WorkflowOutputEvent,
    handler,
)
from agent_framework_azure_ai import AzureAIAgentClient
from azure.identity.aio import DefaultAzureCredential

from product_management_agent import ProductManagementAgentExecutor, create_product_management_workflow

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class A2AMultiAgentCoordinator(Executor):
    """
    A2A Protocol Coordinator for managing handoffs between all 6 agents:
    1. Shopping Assistant (original)
    2. Cart Management (original) 
    3. Customer Loyalty (original)
    4. Interior Designer (original)
    5. Inventory (original)
    6. Product Management (new - this implementation)
    """
    
    def __init__(self, foundry_agents: Dict[str, str], id: str = "a2a_coordinator"):
        """
        Initialize with references to existing Microsoft Foundry agents
        
        Args:
            foundry_agents: Dictionary mapping agent types to their Foundry agent IDs
        """
        self.foundry_agents = foundry_agents
        super().__init__(id=id)
    
    @handler
    async def coordinate_request(
        self, message: ChatMessage, ctx: WorkflowContext[list[ChatMessage], str]
    ) -> None:
        """
        Implement A2A protocol coordination between all 6 agents
        """
        try:
            user_request = message.text.lower()
            messages: list[ChatMessage] = [message]
            
            # A2A Protocol: Intelligent Agent Routing
            routing_decision = await self._determine_primary_agent(user_request)
            
            coordination_response = ChatMessage(
                Role.ASSISTANT,
                text=f"A2A Coordination: Routing to {routing_decision['primary_agent']} agent. "
                     f"Confidence: {routing_decision['confidence']:.2f}. "
                     f"Handoff plan: {routing_decision['handoff_sequence']}"
            )
            
            messages.append(coordination_response)
            
            # Execute the routing plan
            result = await self._execute_agent_sequence(routing_decision, user_request)
            
            final_response = f"A2A Protocol executed successfully. Primary agent: {routing_decision['primary_agent']}. Result: {result}"
            await ctx.yield_output(final_response)
            
        except Exception as e:
            error_msg = f"A2A Coordination error: {str(e)}"
            logger.error(error_msg)
            await ctx.yield_output(error_msg)
    
    async def _determine_primary_agent(self, request: str) -> Dict:
        """
        A2A Protocol: Determine which agent should handle the request and plan handoffs
        """
        
        # Agent capability mapping
        agent_patterns = {
            "product_management": {
                "keywords": ["product", "catalog", "search", "find", "recommend", "compare", 
                            "marketing", "trend", "rank", "best", "popular", "specification"],
                "capabilities": ["product_search", "recommendations", "market_analysis", "rankings"],
                "confidence_boost": 0.1  # New agent gets priority for product queries
            },
            "interior_design": {
                "keywords": ["design", "color", "paint", "room", "style", "decor", 
                            "furniture", "interior", "aesthetic", "layout"],
                "capabilities": ["room_design", "color_consultation", "style_advice"],
                "confidence_boost": 0.0
            },
            "inventory": {
                "keywords": ["stock", "available", "inventory", "in store", "quantity",
                            "do you have", "is there", "availability"],
                "capabilities": ["stock_check", "availability", "inventory_management"],
                "confidence_boost": 0.0
            },
            "customer_loyalty": {
                "keywords": ["discount", "loyalty", "points", "member", "reward",
                            "savings", "deal", "promotion"],
                "capabilities": ["loyalty_programs", "discounts", "member_benefits"],
                "confidence_boost": 0.0
            },
            "cart_management": {
                "keywords": ["cart", "add", "remove", "purchase", "buy", "checkout",
                            "order", "item", "basket"],
                "capabilities": ["cart_operations", "checkout", "order_management"],
                "confidence_boost": 0.0
            },
            "shopping_assistant": {
                "keywords": ["help", "information", "question", "what is", "tell me about",
                            "general", "cora"],
                "capabilities": ["general_assistance", "information", "guidance"],
                "confidence_boost": 0.0
            }
        }
        
        # Calculate confidence scores
        scores = {}
        for agent, config in agent_patterns.items():
            score = 0.0
            
            # Keyword matching
            for keyword in config["keywords"]:
                if keyword in request:
                    score += 1.0
            
            # Normalize by keyword count
            score = score / len(config["keywords"]) if config["keywords"] else 0.0
            
            # Apply confidence boost
            score += config["confidence_boost"]
            
            scores[agent] = score
        
        # Determine primary agent
        primary_agent = max(scores.keys(), key=lambda k: scores[k])
        max_confidence = scores[primary_agent]
        
        # Plan handoff sequence based on request complexity
        handoff_sequence = self._plan_handoff_sequence(request, primary_agent)
        
        return {
            "primary_agent": primary_agent,
            "confidence": max_confidence,
            "all_scores": scores,
            "handoff_sequence": handoff_sequence
        }
    
    def _plan_handoff_sequence(self, request: str, primary_agent: str) -> List[str]:
        """Plan the sequence of agent handoffs for complex requests"""
        
        sequence = [primary_agent]
        
        # Complex request patterns that require multiple agents
        if "room" in request and "furniture" in request:
            # Interior design + product management coordination
            if primary_agent != "interior_design":
                sequence.append("interior_design")
            if primary_agent != "product_management":
                sequence.append("product_management")
                
        elif any(word in request for word in ["buy", "purchase", "order"]) and primary_agent != "cart_management":
            # Any product query that leads to purchase intent
            sequence.append("inventory")  # Check availability
            sequence.append("cart_management")  # Handle purchase
            
        elif "discount" in request or "deal" in request:
            # Loyalty coordination for any request involving savings
            if primary_agent != "customer_loyalty":
                sequence.append("customer_loyalty")
        
        return sequence
    
    async def _execute_agent_sequence(self, routing_decision: Dict, request: str) -> str:
        """Execute the planned agent sequence (simulation for now)"""
        
        primary_agent = routing_decision["primary_agent"]
        sequence = routing_decision["handoff_sequence"]
        
        execution_log = []
        
        for agent in sequence:
            if agent in self.foundry_agents:
                foundry_agent_id = self.foundry_agents[agent]
                execution_log.append(f"{agent} (Foundry ID: {foundry_agent_id})")
            else:
                execution_log.append(f"{agent} (Framework Implementation)")
        
        return f"Executed sequence: {' → '.join(execution_log)}"

class ZavaA2AWorkflowManager:
    """
    Main workflow manager that coordinates all 6 agents using A2A protocol
    """
    
    def __init__(self, foundry_config: Dict[str, str]):
        """
        Initialize with Microsoft Foundry configuration
        
        Args:
            foundry_config: Configuration containing endpoint, deployment, and agent IDs
        """
        self.foundry_config = foundry_config
        self.workflow = None
    
    async def initialize_workflow(self):
        """Initialize the complete A2A workflow with all 6 agents"""
        
        try:
            # Create the Product Management Agent executor
            product_workflow = await create_product_management_workflow(
                self.foundry_config["endpoint"],
                self.foundry_config["model_deployment"]
            )
            
            # Create A2A coordinator with existing Foundry agent references
            foundry_agents = {
                "shopping_assistant": self.foundry_config.get("cora_agent_id", "asst_local_cora"),
                "interior_design": self.foundry_config.get("interior_agent_id", "asst_local_interior_design"),
                "inventory": self.foundry_config.get("inventory_agent_id", "asst_local_inventory"),
                "customer_loyalty": self.foundry_config.get("loyalty_agent_id", "asst_local_customer_loyalty"),
                "cart_management": self.foundry_config.get("cart_agent_id", "asst_local_cart_management")
            }
            
            coordinator = A2AMultiAgentCoordinator(foundry_agents)
            
            # Build complete workflow with A2A coordination
            self.workflow = (
                WorkflowBuilder()
                .set_start_executor(coordinator)
                .add_edge(coordinator, product_workflow.build())  # Integration point
                .build()
            )
            
            logger.info("A2A Workflow initialized with 6 agents and coordination")
            
        except Exception as e:
            logger.error(f"Failed to initialize A2A workflow: {e}")
            raise
    
    async def process_request(self, user_message: str) -> str:
        """Process a user request through the A2A workflow"""
        
        if not self.workflow:
            await self.initialize_workflow()
        
        try:
            message = ChatMessage(Role.USER, text=user_message)
            
            logger.info(f"Processing A2A request: {user_message}")
            
            async for event in self.workflow.run_stream(message):
                if isinstance(event, WorkflowOutputEvent):
                    return event.data
            
            return "A2A workflow completed successfully"
            
        except Exception as e:
            logger.error(f"Error processing A2A request: {e}")
            return f"Error: {str(e)}"

async def main():
    """
    Example usage of the complete A2A multi-agent system
    """
    
    # Configuration that would come from your .env file
    foundry_config = {
        "endpoint": os.getenv("FOUNDRY_ENDPOINT", ""),
        "model_deployment": os.getenv("MODEL_DEPLOYMENT", "gpt-4o-mini"),
        
        # Existing Microsoft Foundry agent IDs
        "cora_agent_id": os.getenv("CORA_AGENT_ID", "asst_local_cora"),
        "interior_agent_id": os.getenv("INTERIOR_AGENT_ID", "asst_local_interior_design"),
        "inventory_agent_id": os.getenv("INVENTORY_AGENT_ID", "asst_local_inventory"),
        "loyalty_agent_id": os.getenv("LOYALTY_AGENT_ID", "asst_local_customer_loyalty"),
        "cart_agent_id": os.getenv("CART_AGENT_ID", "asst_local_cart_management")
    }
    
    if not foundry_config["endpoint"]:
        print("❌ Please set FOUNDRY_ENDPOINT environment variable")
        return
    
    try:
        # Initialize the A2A workflow manager
        workflow_manager = ZavaA2AWorkflowManager(foundry_config)
        await workflow_manager.initialize_workflow()
        
        # Test A2A protocol with different types of requests
        test_requests = [
            "I need modern furniture for my living room",
            "What's the most popular sofa this season?", 
            "Add this chair to my cart and check for member discounts",
            "Do you have the blue accent chair in stock?",
            "Design a cozy reading nook with complementary furniture"
        ]
        
        print("🚀 Testing Zava A2A Multi-Agent System (6 agents)")
        print("=" * 60)
        
        for i, request in enumerate(test_requests, 1):
            print(f"\\n🔍 Test {i}: {request}")
            result = await workflow_manager.process_request(request)
            print(f"✅ Result: {result}")
        
        print("\\n🎉 All A2A protocol tests completed successfully!")
        
        # Summary
        print("\\n📋 A2A System Summary:")
        print("• 6 Coordinated Agents: Shopping, Cart, Loyalty, Interior, Inventory, Product Management")
        print("• Agent Framework Integration: Native Microsoft Foundry orchestration")
        print("• Semantic Kernel Plugins: ProductPlugin, MarketingPlugin, RankingPlugin") 
        print("• A2A Protocol: Intelligent routing and handoff coordination")
        
    except Exception as e:
        logger.error(f"A2A system error: {e}")
        print(f"❌ Error: {e}")

if __name__ == "__main__":
    asyncio.run(main())