import os
import time
from azure.ai.inference import ChatCompletionsClient
from azure.core.credentials import AzureKeyCredential
from dotenv import load_dotenv

# Load environment variables (Azure endpoint, deployment, keys, etc.)
load_dotenv()

# Retrieve credentials from .env file or environment
endpoint = os.getenv("gpt_endpoint")
api_key = os.getenv("gpt_api_key")
deployment = os.getenv("gpt_deployment")

# Global client instance
client = None

def get_client():
    """Lazily initialize and return the Azure AI Foundry client"""
    global client
    if client is None:
        if not all([endpoint, api_key]):
            raise ValueError(
                f"Missing required environment variables. "
                f"endpoint={bool(endpoint)}, "
                f"api_key={bool(api_key)}"
            )
        # Use .services.ai.azure.com/models endpoint for Azure AI Foundry
        # Convert cognitiveservices to services.ai if needed
        foundry_endpoint = endpoint.replace('.cognitiveservices.', '.services.ai.')
        
        # Ensure it has .ai. in the domain
        if '.services.azure.com' in foundry_endpoint and '.services.ai.azure.com' not in foundry_endpoint:
            foundry_endpoint = foundry_endpoint.replace('.services.azure.com', '.services.ai.azure.com')
        
        # Add /models path if not present
        if not foundry_endpoint.endswith('/models'):
            foundry_endpoint = f"{foundry_endpoint.rstrip('/')}/models"
        
        client = ChatCompletionsClient(
            endpoint=foundry_endpoint,
            credential=AzureKeyCredential(api_key)
        )
    return client

def generate_response(text_input):
    start_time = time.time()
    """
    Input:
        text_input (str): The user's chat input.

    Output:
        response (str): A Markdown-formatted response from the agent.
    """
    
    # Get initialized client
    client = get_client()

    # Prepare the messages for Azure AI Foundry
    messages = [
        {
            "role": "system",
            "content": """You are an AI assistant for Zava, a leading home improvement and DIY products company.

Your capabilities include:
- Providing expert advice on DIY projects, home improvement, repairs, and renovations
- Recommending products from Zava's extensive catalog (tools, materials, paint, hardware, etc.)
- Offering step-by-step guidance for various home projects
- Answering general questions about home maintenance, safety, and best practices
- Discussing design ideas, project planning, and cost estimation
- Providing information about Zava stores and services

Product Guidelines:
- For paint colors, we feature: blue, green, and white (but can discuss other options available)
- Recommend appropriate tools and materials for each project
- Suggest safety equipment when relevant

Store Information:
- Zava has locations nationwide
- For specific store availability, direct customers to our Miami flagship store
- Mention online ordering options when appropriate

Tone & Style:
- Be friendly, helpful, and encouraging
- Provide detailed, practical advice
- Ask clarifying questions when needed
- Be enthusiastic about DIY projects while emphasizing safety
- Feel free to engage in broader conversations about home improvement topics

You can discuss a wide range of topics related to home improvement, construction, design, and general DIY advice. Don't limit yourself to just product recommendations - provide comprehensive assistance!
            """
        },
        {
            "role": "user",
            "content": text_input
        }
    ]

    # Call Azure AI Foundry chat API
    response = client.complete(
        model=deployment,
        messages=messages,
        max_tokens=10000,
        temperature=1.0,
        top_p=1.0,
        frequency_penalty=0,
        presence_penalty=0
    )
    
    end_sum = time.time()
    print(f"generate_response Execution Time: {end_sum - start_time} seconds")
    
    # Return response content
    return response.choices[0].message.content
