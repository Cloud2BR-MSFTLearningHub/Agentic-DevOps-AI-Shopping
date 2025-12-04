"""
Marketing Agent - Specialized agent for product recommendations and marketing tasks

This agent handles:
- Product recommendations and personalization
- Upselling and cross-selling strategies  
- Product description improvements
- Marketing analysis and campaigns
"""
import asyncio
import logging
from typing import Dict, List, Optional
from datetime import datetime

from agent_framework import (
    ChatAgent,
    ChatMessage,
    Executor,
    Role,
    WorkflowContext,
    handler,
)
from agent_framework_azure_ai import AzureAIAgentClient
from azure.identity.aio import DefaultAzureCredential

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class MarketingAgentExecutor(Executor):
    """
    Marketing Agent specialized for recommendations, upselling, and marketing tasks
    """
    
    agent: ChatAgent
    
    def __init__(self, agent: ChatAgent, id: str = "marketing_agent"):
        self.agent = agent
        super().__init__(id=id)
    
    @handler
    async def handle_marketing_request(
        self, message: ChatMessage, ctx: WorkflowContext[list[ChatMessage], str]
    ) -> None:
        """Handle marketing-related requests"""
        try:
            query_text = message.text.lower()
            messages: list[ChatMessage] = [message]
            
            # Determine marketing task type
            if any(keyword in query_text for keyword in ["recommend", "suggest", "advice"]):
                marketing_context = await self._generate_recommendations(query_text)
            elif any(keyword in query_text for keyword in ["upsell", "upgrade", "premium"]):
                marketing_context = await self._generate_upselling_strategy(query_text)
            elif any(keyword in query_text for keyword in ["cross-sell", "complement", "goes with"]):
                marketing_context = await self._generate_cross_selling_strategy(query_text)
            elif any(keyword in query_text for keyword in ["description", "improve", "enhance"]):
                marketing_context = await self._improve_product_description(query_text)
            else:
                marketing_context = await self._general_marketing_analysis(query_text)
            
            # Add marketing context to conversation
            context_message = ChatMessage(
                Role.ASSISTANT,
                text=f"Marketing Analysis: {marketing_context}"
            )
            messages.append(context_message)
            
            # Get agent response with marketing context
            response = await self.agent.run(messages)
            logger.info(f"Marketing Agent: {response.messages[-1].text}")
            
            # Yield marketing response
            await ctx.yield_output(response.messages[-1].text)
            
        except Exception as e:
            error_msg = f"Marketing Agent error: {str(e)}"
            logger.error(error_msg)
            await ctx.yield_output(error_msg)
    
    async def _generate_recommendations(self, query: str) -> str:
        """Generate personalized product recommendations"""
        logger.info(f"Generating recommendations for: {query}")
        
        # Simulated recommendation logic - would integrate with real data
        recommendations = [
            {"product": "Modern Sectional Sofa", "reason": "Perfect for large families", "confidence": 0.9},
            {"product": "Coffee Table Set", "reason": "Complements modern furniture style", "confidence": 0.85},
            {"product": "Floor Lamps", "reason": "Enhances room lighting", "confidence": 0.78}
        ]
        
        return f"Personalized recommendations generated: {len(recommendations)} products identified with high confidence scores"
    
    async def _generate_upselling_strategy(self, query: str) -> str:
        """Generate upselling strategies for products"""
        logger.info(f"Generating upselling strategy for: {query}")
        
        upsell_options = [
            "Premium fabric upgrade (+$200) - Stain resistant and longer warranty",
            "Extended warranty package (+$150) - 5-year coverage vs standard 2-year",
            "Professional assembly service (+$99) - White glove delivery and setup"
        ]
        
        return f"Upselling opportunities identified: {len(upsell_options)} premium options available"
    
    async def _generate_cross_selling_strategy(self, query: str) -> str:
        """Generate cross-selling strategies"""
        logger.info(f"Generating cross-selling strategy for: {query}")
        
        cross_sell_items = [
            "Accent pillows and throws - 25% off when bought together",
            "Side tables to match your sofa style",
            "Rugs that complement your color scheme"
        ]
        
        return f"Cross-selling opportunities: {len(cross_sell_items)} complementary items identified"
    
    async def _improve_product_description(self, query: str) -> str:
        """Improve product descriptions for better marketing"""
        logger.info(f"Improving product description for: {query}")
        
        improvements = [
            "Added emotional appeal and lifestyle benefits",
            "Highlighted unique selling propositions",
            "Included technical specifications in customer-friendly language",
            "Added social proof elements"
        ]
        
        return f"Product description improvements: {len(improvements)} enhancements applied"
    
    async def _general_marketing_analysis(self, query: str) -> str:
        """General marketing analysis"""
        logger.info(f"Performing marketing analysis for: {query}")
        
        return "Comprehensive marketing analysis completed - customer segments identified, positioning strategy developed"

async def create_marketing_agent(
    foundry_endpoint: str, 
    model_deployment: str
) -> MarketingAgentExecutor:
    """Create and configure the Marketing Agent"""
    
    async with (
        DefaultAzureCredential() as credential,
        ChatAgent(
            chat_client=AzureAIAgentClient(
                project_endpoint=foundry_endpoint,
                model_deployment_name=model_deployment,
                async_credential=credential,
                agent_name="MarketingAgent",
            ),
            instructions='''You are a Marketing Specialist for Zava, focused on product recommendations and sales optimization.

Your expertise includes:
- Personalized product recommendations based on customer preferences
- Upselling strategies to premium products and services
- Cross-selling complementary products and accessories
- Product description enhancement for better customer appeal
- Market analysis and customer segmentation

MARKETING GUIDELINES:
1. Always focus on customer value and satisfaction
2. Provide specific, actionable recommendations with clear reasoning
3. Use persuasive but honest marketing language
4. Highlight unique selling propositions and competitive advantages
5. Consider customer lifecycle and purchase history for personalization

When handling requests:
- Generate personalized recommendations with confidence scores
- Suggest upselling opportunities that add genuine value
- Identify cross-selling items that complement purchases
- Improve product descriptions with emotional and technical appeals
- Provide marketing insights based on current trends''',
        ) as marketing_agent,
    ):
        return MarketingAgentExecutor(marketing_agent)

if __name__ == "__main__":
    async def test_marketing_agent():
        import os
        foundry_endpoint = os.getenv("FOUNDRY_ENDPOINT", "")
        model_deployment = os.getenv("MODEL_DEPLOYMENT", "gpt-4o-mini")
        
        if not foundry_endpoint:
            print("Please set FOUNDRY_ENDPOINT environment variable")
            return
        
        marketing_executor = await create_marketing_agent(foundry_endpoint, model_deployment)
        print("Marketing Agent created and ready for deployment!")
    
    asyncio.run(test_marketing_agent())