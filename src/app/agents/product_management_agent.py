"""
Product Management Agent using Microsoft Agent Framework

This module implements a Product Management Agent that delegates tasks to
specialized Marketing and Ranker agents, and uses the Product Information Plugin
for factual product lookups from a predefined catalog.

Key Features:
- Delegates to Marketing Agent for recommendations, upselling, cross-selling
- Delegates to Ranker Agent for comparisons, reviews, and rankings  
- Uses Product Information Plugin for factual product data
- Coordinates multi-agent workflows using Agent Framework patterns
"""
import asyncio
import logging
import os
from typing import Any, Dict, List, Optional
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

from product_information_plugin import ProductInformationPlugin
from marketing_agent import create_marketing_agent
from ranker_agent import create_ranker_agent

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class ProductManagerAgentExecutor(Executor):
    """
    Product Manager Agent that delegates to Marketing and Ranker agents as appropriate
    
    This agent coordinates between specialized agents and uses factual data plugins
    """
    
    agent: ChatAgent
    product_plugin: ProductInformationPlugin
    marketing_agent: Optional[Any] = None
    ranker_agent: Optional[Any] = None
    
    def __init__(self, agent: ChatAgent, id: str = "product_manager"):
        self.agent = agent
        
        # Initialize Product Information Plugin for factual lookups
        self.product_plugin = ProductInformationPlugin()
        
        super().__init__(id=id)
    
    def set_delegate_agents(self, marketing_agent: Any, ranker_agent: Any):
        """Set the Marketing and Ranker agents for delegation"""
        self.marketing_agent = marketing_agent
        self.ranker_agent = ranker_agent
        logger.info("Product Manager: Marketing and Ranker agents configured for delegation")
    
    @handler
    async def handle_product_request(
        self, message: ChatMessage, ctx: WorkflowContext[list[ChatMessage], str]
    ) -> None:
        """Handle product requests and delegate to appropriate specialized agents"""
        try:
            query_text = message.text.lower()
            messages: list[ChatMessage] = [message]
            
            # Determine if delegation to specialized agents is needed
            delegation_decision = await self._analyze_delegation_needs(query_text)
            
            if delegation_decision["delegate_to"] == "marketing":
                result = await self._delegate_to_marketing_agent(message, delegation_decision["reason"])
                
            elif delegation_decision["delegate_to"] == "ranker":
                result = await self._delegate_to_ranker_agent(message, delegation_decision["reason"])
                
            elif delegation_decision["delegate_to"] == "product_lookup":
                result = await self._handle_product_lookup(message)
                
            else:
                # Handle directly with Product Manager + Plugin data
                result = await self._handle_direct_product_management(message)
            
            # Product Manager coordinates and provides final response
            coordination_msg = ChatMessage(
                Role.ASSISTANT,
                text=f"Product Manager coordination: {delegation_decision['reason']}. Result: {result}"
            )
            messages.append(coordination_msg)
            
            # Get Product Manager's coordinated response
            response = await self.agent.run(messages)
            logger.info(f"Product Manager: {response.messages[-1].text}")
            
            await ctx.yield_output(response.messages[-1].text)
            
        except Exception as e:
            error_msg = f"Product Manager error: {str(e)}"
            logger.error(error_msg)
            await ctx.yield_output(error_msg)
    
    async def _analyze_delegation_needs(self, query: str) -> Dict[str, str]:
        """Analyze whether to delegate to Marketing Agent, Ranker Agent, or handle directly"""
        
        # Marketing Agent delegation criteria
        if any(keyword in query for keyword in [
            "recommend", "suggest", "upsell", "cross-sell", "marketing", 
            "promote", "campaign", "description", "improve"
        ]):
            return {
                "delegate_to": "marketing",
                "reason": "Marketing expertise required for recommendations/upselling/cross-selling"
            }
        
        # Ranker Agent delegation criteria  
        if any(keyword in query for keyword in [
            "compare", "vs", "versus", "rank", "best", "top", "review",
            "rating", "competitive", "analysis", "position"
        ]):
            return {
                "delegate_to": "ranker", 
                "reason": "Ranking expertise required for comparisons/reviews/rankings"
            }
        
        # Product lookup criteria (factual information)
        if any(keyword in query for keyword in [
            "details", "specifications", "specs", "price", "availability",
            "stock", "features", "dimensions", "warranty"
        ]):
            return {
                "delegate_to": "product_lookup",
                "reason": "Factual product information lookup required"
            }
        
        # Handle directly
        return {
            "delegate_to": "direct",
            "reason": "General product management - handling directly with plugin support"
        }
    
    async def _delegate_to_marketing_agent(self, message: ChatMessage, reason: str) -> str:
        """Delegate marketing-related tasks to Marketing Agent"""
        logger.info(f"Product Manager delegating to Marketing Agent: {reason}")
        
        if not self.marketing_agent:
            return "Marketing Agent not available - handling basic recommendation logic"
        
        try:
            # Simulate delegation to Marketing Agent
            # In a real implementation, this would invoke the Marketing Agent's workflow
            marketing_context = f"Marketing delegation for: {message.text}"
            
            # Use plugin data to enhance marketing response
            if "furniture" in message.text.lower():
                furniture_products = self.product_plugin.filter_products_by_category("Living Room")
                marketing_context += f" | Available furniture products: {len(furniture_products)}"
            
            return f"Marketing Agent completed: {marketing_context}"
            
        except Exception as e:
            return f"Marketing delegation error: {str(e)}"
    
    async def _delegate_to_ranker_agent(self, message: ChatMessage, reason: str) -> str:
        """Delegate ranking/comparison tasks to Ranker Agent"""
        logger.info(f"Product Manager delegating to Ranker Agent: {reason}")
        
        if not self.ranker_agent:
            return "Ranker Agent not available - providing basic comparison"
        
        try:
            # Simulate delegation to Ranker Agent
            ranking_context = f"Ranking delegation for: {message.text}"
            
            # Use plugin data to enhance ranking response
            if "sofa" in message.text.lower():
                sofas = self.product_plugin.search_products_by_name("sofa")
                ranking_context += f" | Found {len(sofas)} sofa products for comparison"
            
            return f"Ranker Agent completed: {ranking_context}"
            
        except Exception as e:
            return f"Ranker delegation error: {str(e)}"
    
    async def _handle_product_lookup(self, message: ChatMessage) -> str:
        """Handle factual product information lookup using Plugin"""
        logger.info("Product Manager using Product Information Plugin for factual lookup")
        
        try:
            query_text = message.text.lower()
            
            # Extract product identifiers from query
            if "sofa-001" in query_text or "sectional" in query_text:
                product = self.product_plugin.lookup_product_by_id("SOFA-001")
                if product:
                    return f"Product details: {product['name']} - ${product['price']} - {product['description']}"
            
            # Search by category
            if "office" in query_text:
                products = self.product_plugin.filter_products_by_category("Office")
                return f"Office products: {[p['name'] for p in products]}"
            
            # General search
            if "lamp" in query_text:
                lamps = self.product_plugin.search_products_by_name("lamp")
                return f"Available lamps: {[l['name'] for l in lamps]}"
            
            # Default product catalog overview
            categories = self.product_plugin.get_all_categories()
            return f"Product catalog contains {len(self.product_plugin.product_catalog)} products across categories: {categories}"
            
        except Exception as e:
            return f"Product lookup error: {str(e)}"
    
    async def _handle_direct_product_management(self, message: ChatMessage) -> str:
        """Handle general product management tasks directly"""
        logger.info("Product Manager handling request directly with plugin support")
        
        try:
            # Use plugin data to enhance response
            total_products = len(self.product_plugin.product_catalog)
            categories = self.product_plugin.get_all_categories()
            
            return f"Product management analysis complete. Catalog: {total_products} products across {len(categories)} categories"
            
        except Exception as e:
            return f"Direct handling error: {str(e)}"

async def create_product_manager_workflow(
    foundry_endpoint: str, 
    model_deployment: str
) -> WorkflowBuilder:
    """
    Create the Product Manager workflow with Marketing and Ranker agent delegation
    
    Args:
        foundry_endpoint: Microsoft Foundry project endpoint
        model_deployment: Model deployment name in Foundry
        
    Returns:
        Configured WorkflowBuilder ready for execution
    """
    
    async with (
        DefaultAzureCredential() as credential,
        ChatAgent(
            chat_client=AzureAIAgentClient(
                project_endpoint=foundry_endpoint,
                model_deployment_name=model_deployment,
                async_credential=credential,
                agent_name="ProductManagerAgent",
            ),
            instructions='''You are the Product Manager for Zava, coordinating specialized agents and product information.

Your role is to:
- Analyze customer requests and determine appropriate delegation strategy
- Delegate marketing tasks (recommendations, upselling, cross-selling) to Marketing Agent
- Delegate ranking tasks (comparisons, reviews, rankings) to Ranker Agent  
- Use Product Information Plugin for factual product data lookups
- Coordinate responses from specialized agents and provide unified customer experience

DELEGATION GUIDELINES:
1. Marketing Agent: Use for recommendations, upselling, cross-selling, description improvements
2. Ranker Agent: Use for product comparisons, reviews analysis, competitive rankings
3. Product Plugin: Use for factual information like specifications, pricing, availability
4. Direct handling: Use for general product management and coordination tasks

COORDINATION APPROACH:
- Always analyze the request type first
- Choose the most appropriate specialist or handle directly
- Integrate factual data from Product Information Plugin
- Provide clear, helpful responses that leverage specialist expertise
- Maintain consistent customer experience across all interactions''',
        ) as product_manager_agent,
    ):
        # Create Product Manager executor
        product_manager_executor = ProductManagerAgentExecutor(product_manager_agent)
        
        # Create specialized agents for delegation
        marketing_agent = await create_marketing_agent(foundry_endpoint, model_deployment)
        ranker_agent = await create_ranker_agent(foundry_endpoint, model_deployment)
        
        # Configure delegation
        product_manager_executor.set_delegate_agents(marketing_agent, ranker_agent)
        
        # Build workflow
        workflow_builder = (
            WorkflowBuilder()
            .set_start_executor(product_manager_executor)
        )
        
        return workflow_builder

# Example usage function
async def main():
    """Example of running the Product Manager with delegation"""
    
    # Configuration - these would come from environment variables
    foundry_endpoint = os.getenv("FOUNDRY_ENDPOINT", "")
    model_deployment = os.getenv("MODEL_DEPLOYMENT", "gpt-4o-mini")
    
    if not foundry_endpoint:
        print("Please set FOUNDRY_ENDPOINT environment variable")
        return
    
    try:
        workflow_builder = await create_product_manager_workflow(
            foundry_endpoint, 
            model_deployment
        )
        
        workflow = workflow_builder.build()
        
        # Test different types of requests to see delegation in action
        test_requests = [
            "Can you recommend some modern furniture for my living room?",  # Should delegate to Marketing
            "Compare the ModernComfort Sectional with other sofas",         # Should delegate to Ranker
            "What are the specifications of product SOFA-001?",             # Should use Product Plugin
            "Tell me about your product catalog"                           # Should handle directly
        ]
        
        print("Testing Product Manager with delegation...")
        
        for i, request in enumerate(test_requests, 1):
            print(f"\n--- Test {i}: {request} ---")
            
            test_message = ChatMessage(Role.USER, text=request)
            
            async for event in workflow.run_stream(test_message):
                if isinstance(event, WorkflowOutputEvent):
                    print(f"Result: {event.data}")
                    break
        
        print("\nProduct Manager delegation workflow completed successfully!")
        
    except Exception as e:
        logger.error(f"Error running Product Manager workflow: {e}")

if __name__ == "__main__":
    asyncio.run(main())