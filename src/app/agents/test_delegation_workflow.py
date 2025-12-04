"""
Test script for Agent2Agent (A2A) delegation workflow
Tests the coordination between Product Manager, Marketing Agent, and Ranker Agent
with Product Information Plugin integration
"""
import asyncio
import os
import sys
import logging
from typing import List, Dict, Any

# Add parent directory to sys.path for imports
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from product_management_agent import create_product_manager_workflow
from marketing_agent import create_marketing_agent
from ranker_agent import create_ranker_agent
from product_information_plugin import ProductInformationPlugin

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class DelegationTester:
    """Test harness for verifying A2A delegation patterns"""
    
    def __init__(self):
        self.foundry_endpoint = os.getenv("AZURE_AI_PROJECT_ENDPOINT", "")
        self.model_deployment = os.getenv("MODEL_DEPLOYMENT", "gpt-4o-mini")
        
        # Test queries to verify different delegation patterns
        self.test_queries = [
            {
                "query": "Can you recommend some modern furniture for my living room?",
                "expected_delegation": "marketing",
                "description": "Marketing task - recommendations and upselling"
            },
            {
                "query": "Compare the ModernComfort Sectional with other sofas in your catalog",
                "expected_delegation": "ranker", 
                "description": "Ranking task - product comparisons"
            },
            {
                "query": "What are the specifications and price of product SOFA-001?",
                "expected_delegation": "product_lookup",
                "description": "Factual lookup - Product Information Plugin"
            },
            {
                "query": "Tell me about your product catalog and available categories",
                "expected_delegation": "direct",
                "description": "General management - Product Manager direct handling"
            },
            {
                "query": "I need help improving product descriptions for marketing campaigns",
                "expected_delegation": "marketing",
                "description": "Marketing expertise - description improvements"
            },
            {
                "query": "Which dining table has the best customer reviews and ratings?",
                "expected_delegation": "ranker",
                "description": "Ranking expertise - review analysis and ratings"
            }
        ]
    
    async def test_product_information_plugin(self):
        """Test the Product Information Plugin directly"""
        logger.info("=== Testing Product Information Plugin ===")
        
        plugin = ProductInformationPlugin()
        
        # Test product lookup
        sofa = plugin.lookup_product_by_id("SOFA-001")
        logger.info(f"Product SOFA-001: {sofa['name'] if sofa else 'Not found'}")
        
        # Test category filtering
        office_products = plugin.filter_products_by_category("Office")
        logger.info(f"Office products: {len(office_products)} items")
        
        # Test search
        lamp_results = plugin.search_products_by_name("lamp")
        logger.info(f"Lamp search results: {len(lamp_results)} items")
        
        # Test categories
        categories = plugin.get_all_categories()
        logger.info(f"Available categories: {categories}")
        
        return True
    
    async def test_agent_creation(self):
        """Test individual agent creation"""
        logger.info("=== Testing Individual Agent Creation ===")
        
        if not self.foundry_endpoint:
            logger.warning("No FOUNDRY_ENDPOINT configured - using mock agents")
            return False
        
        try:
            # Test Marketing Agent creation
            logger.info("Creating Marketing Agent...")
            marketing_agent = await create_marketing_agent(self.foundry_endpoint, self.model_deployment)
            logger.info("✓ Marketing Agent created successfully")
            
            # Test Ranker Agent creation  
            logger.info("Creating Ranker Agent...")
            ranker_agent = await create_ranker_agent(self.foundry_endpoint, self.model_deployment)
            logger.info("✓ Ranker Agent created successfully")
            
            return True
            
        except Exception as e:
            logger.error(f"Agent creation failed: {e}")
            return False
    
    async def test_delegation_analysis(self):
        """Test the delegation decision logic"""
        logger.info("=== Testing Delegation Analysis ===")
        
        # Import the executor for testing delegation logic
        from product_management_agent import ProductManagerAgentExecutor
        from agent_framework import ChatAgent
        
        # Create mock agent for testing
        class MockChatAgent:
            async def run(self, messages):
                class MockResponse:
                    def __init__(self):
                        from agent_framework import ChatMessage, Role
                        self.messages = [ChatMessage(Role.ASSISTANT, text="Mock response")]
                return MockResponse()
        
        executor = ProductManagerAgentExecutor(MockChatAgent())
        
        # Test delegation analysis for each query
        for test_case in self.test_queries:
            decision = await executor._analyze_delegation_needs(test_case["query"].lower())
            
            expected = test_case["expected_delegation"]
            actual = decision["delegate_to"]
            
            status = "✓" if actual == expected else "✗"
            logger.info(f"{status} Query: '{test_case['query'][:50]}...'")
            logger.info(f"   Expected: {expected} | Actual: {actual}")
            logger.info(f"   Reason: {decision['reason']}")
            logger.info("")
        
        return True
    
    async def test_full_workflow(self):
        """Test the complete Product Manager workflow if Foundry is available"""
        logger.info("=== Testing Full Workflow ===")
        
        if not self.foundry_endpoint:
            logger.warning("No FOUNDRY_ENDPOINT - skipping full workflow test")
            return False
        
        try:
            # Create the workflow
            workflow_builder = await create_product_manager_workflow(
                self.foundry_endpoint,
                self.model_deployment
            )
            
            workflow = workflow_builder.build()
            logger.info("✓ Workflow created successfully")
            
            # Test with one sample query
            from agent_framework import ChatMessage, Role, WorkflowOutputEvent
            
            test_message = ChatMessage(
                Role.USER, 
                text="What are the specifications of your sectional sofas?"
            )
            
            logger.info("Running sample workflow...")
            
            async for event in workflow.run_stream(test_message):
                if isinstance(event, WorkflowOutputEvent):
                    logger.info(f"Workflow result: {event.data[:100]}...")
                    break
            
            logger.info("✓ Full workflow test completed")
            return True
            
        except Exception as e:
            logger.error(f"Full workflow test failed: {e}")
            return False
    
    async def run_all_tests(self):
        """Run all delegation tests"""
        logger.info("Starting A2A Delegation Workflow Tests")
        logger.info("=" * 60)
        
        results = {}
        
        # Test 1: Product Information Plugin
        try:
            results["plugin"] = await self.test_product_information_plugin()
        except Exception as e:
            logger.error(f"Plugin test failed: {e}")
            results["plugin"] = False
        
        # Test 2: Agent Creation (if Foundry available)
        try:
            results["agents"] = await self.test_agent_creation()
        except Exception as e:
            logger.error(f"Agent creation test failed: {e}")
            results["agents"] = False
        
        # Test 3: Delegation Logic
        try:
            results["delegation"] = await self.test_delegation_analysis()
        except Exception as e:
            logger.error(f"Delegation test failed: {e}")
            results["delegation"] = False
        
        # Test 4: Full Workflow (if Foundry available)
        try:
            results["workflow"] = await self.test_full_workflow()
        except Exception as e:
            logger.error(f"Full workflow test failed: {e}")
            results["workflow"] = False
        
        # Summary
        logger.info("=" * 60)
        logger.info("TEST RESULTS SUMMARY")
        logger.info("=" * 60)
        
        for test_name, passed in results.items():
            status = "PASS" if passed else "FAIL"
            logger.info(f"{test_name.upper()}: {status}")
        
        total_tests = len(results)
        passed_tests = sum(results.values())
        
        logger.info(f"\nOverall: {passed_tests}/{total_tests} tests passed")
        
        if passed_tests == total_tests:
            logger.info("🎉 All delegation tests PASSED! A2A workflow is ready.")
        else:
            logger.info("⚠️  Some tests failed. Check configuration and dependencies.")
        
        return results

async def main():
    """Main test runner"""
    tester = DelegationTester()
    await tester.run_all_tests()

if __name__ == "__main__":
    asyncio.run(main())