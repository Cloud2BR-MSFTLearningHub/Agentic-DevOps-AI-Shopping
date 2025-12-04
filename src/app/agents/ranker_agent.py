"""
Ranker Agent - Specialized agent for product comparisons, reviews, and rankings

This agent handles:
- Product comparisons and feature analysis
- Review processing and sentiment analysis
- Product rankings by various criteria
- Competitive analysis and positioning
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

class RankerAgentExecutor(Executor):
    """
    Ranker Agent specialized for product comparisons, reviews, and rankings
    """
    
    agent: ChatAgent
    
    def __init__(self, agent: ChatAgent, id: str = "ranker_agent"):
        self.agent = agent
        super().__init__(id=id)
    
    @handler
    async def handle_ranking_request(
        self, message: ChatMessage, ctx: WorkflowContext[list[ChatMessage], str]
    ) -> None:
        """Handle ranking and comparison requests"""
        try:
            query_text = message.text.lower()
            messages: list[ChatMessage] = [message]
            
            # Determine ranking task type
            if any(keyword in query_text for keyword in ["compare", "vs", "versus", "difference"]):
                ranking_context = await self._perform_product_comparison(query_text)
            elif any(keyword in query_text for keyword in ["review", "rating", "feedback"]):
                ranking_context = await self._analyze_reviews(query_text)
            elif any(keyword in query_text for keyword in ["rank", "best", "top", "popular"]):
                ranking_context = await self._generate_product_rankings(query_text)
            elif any(keyword in query_text for keyword in ["competitive", "competitor", "market position"]):
                ranking_context = await self._analyze_competitive_position(query_text)
            else:
                ranking_context = await self._general_ranking_analysis(query_text)
            
            # Add ranking context to conversation
            context_message = ChatMessage(
                Role.ASSISTANT,
                text=f"Ranking Analysis: {ranking_context}"
            )
            messages.append(context_message)
            
            # Get agent response with ranking context
            response = await self.agent.run(messages)
            logger.info(f"Ranker Agent: {response.messages[-1].text}")
            
            # Yield ranking response
            await ctx.yield_output(response.messages[-1].text)
            
        except Exception as e:
            error_msg = f"Ranker Agent error: {str(e)}"
            logger.error(error_msg)
            await ctx.yield_output(error_msg)
    
    async def _perform_product_comparison(self, query: str) -> str:
        """Compare products across multiple criteria"""
        logger.info(f"Performing product comparison for: {query}")
        
        # Simulated comparison logic - would integrate with real product data
        comparison_criteria = [
            {"criteria": "Price", "product_a_score": 8.5, "product_b_score": 7.2},
            {"criteria": "Quality", "product_a_score": 9.1, "product_b_score": 8.8},
            {"criteria": "Features", "product_a_score": 7.8, "product_b_score": 9.0},
            {"criteria": "Customer Satisfaction", "product_a_score": 8.9, "product_b_score": 8.5}
        ]
        
        return f"Comprehensive product comparison completed: {len(comparison_criteria)} criteria analyzed with detailed scoring"
    
    async def _analyze_reviews(self, query: str) -> str:
        """Analyze product reviews and ratings"""
        logger.info(f"Analyzing reviews for: {query}")
        
        # Simulated review analysis - would integrate with review data
        review_insights = {
            "total_reviews": 247,
            "average_rating": 4.3,
            "sentiment_breakdown": {"positive": 78, "neutral": 15, "negative": 7},
            "common_themes": ["comfortable", "durable", "good value", "stylish design"],
            "improvement_areas": ["delivery time", "assembly instructions"]
        }
        
        return f"Review analysis complete: {review_insights['total_reviews']} reviews processed, {review_insights['average_rating']} avg rating, key themes identified"
    
    async def _generate_product_rankings(self, query: str) -> str:
        """Generate product rankings by specified criteria"""
        logger.info(f"Generating rankings for: {query}")
        
        # Simulated ranking logic
        ranked_products = [
            {"rank": 1, "product": "ModernComfort Sectional", "score": 9.2, "criteria": "Overall Value"},
            {"rank": 2, "product": "StylePlus Sofa Set", "score": 8.8, "criteria": "Overall Value"},
            {"rank": 3, "product": "CompactLiving Loveseat", "score": 8.5, "criteria": "Overall Value"},
            {"rank": 4, "product": "PremiumCraft Recliner", "score": 8.1, "criteria": "Overall Value"}
        ]
        
        return f"Product rankings generated: Top {len(ranked_products)} products ranked by specified criteria with confidence scores"
    
    async def _analyze_competitive_position(self, query: str) -> str:
        """Analyze competitive positioning"""
        logger.info(f"Analyzing competitive position for: {query}")
        
        competitive_analysis = {
            "market_position": "Strong - Top 3 in category",
            "key_differentiators": ["Premium materials", "Extended warranty", "Local manufacturing"],
            "competitive_advantages": ["Price-to-quality ratio", "Customer service", "Customization options"],
            "areas_for_improvement": ["Online presence", "Product variety in premium segment"]
        }
        
        return f"Competitive analysis complete: Market position assessed, {len(competitive_analysis['key_differentiators'])} differentiators identified"
    
    async def _general_ranking_analysis(self, query: str) -> str:
        """General ranking and analysis"""
        logger.info(f"Performing general ranking analysis for: {query}")
        
        return "Comprehensive ranking analysis completed - products assessed across multiple dimensions"

async def create_ranker_agent(
    foundry_endpoint: str, 
    model_deployment: str
) -> RankerAgentExecutor:
    """Create and configure the Ranker Agent"""
    
    async with (
        DefaultAzureCredential() as credential,
        ChatAgent(
            chat_client=AzureAIAgentClient(
                project_endpoint=foundry_endpoint,
                model_deployment_name=model_deployment,
                async_credential=credential,
                agent_name="RankerAgent",
            ),
            instructions='''You are a Product Ranking and Comparison Specialist for Zava, focused on analytical evaluation.

Your expertise includes:
- Detailed product comparisons across multiple criteria
- Review analysis and sentiment interpretation
- Product ranking by popularity, quality, value, and customer satisfaction
- Competitive analysis and market positioning
- Data-driven recommendations based on objective metrics

RANKING GUIDELINES:
1. Use objective criteria and data-driven analysis
2. Provide transparent scoring methodologies
3. Consider multiple perspectives (price, quality, features, reviews)
4. Highlight both strengths and weaknesses fairly
5. Base rankings on verifiable metrics and customer feedback

When handling requests:
- Compare products using standardized criteria and scoring
- Analyze reviews for patterns, sentiment, and actionable insights
- Generate rankings with clear methodology and confidence levels
- Provide competitive analysis with market positioning insights
- Explain ranking rationale and methodology clearly''',
        ) as ranker_agent,
    ):
        return RankerAgentExecutor(ranker_agent)

if __name__ == "__main__":
    async def test_ranker_agent():
        import os
        foundry_endpoint = os.getenv("FOUNDRY_ENDPOINT", "")
        model_deployment = os.getenv("MODEL_DEPLOYMENT", "gpt-4o-mini")
        
        if not foundry_endpoint:
            print("Please set FOUNDRY_ENDPOINT environment variable")
            return
        
        ranker_executor = await create_ranker_agent(foundry_endpoint, model_deployment)
        print("Ranker Agent created and ready for deployment!")
    
    asyncio.run(test_ranker_agent())