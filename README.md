# Demo: Zava AI Shopping Assistant <br/> Multi-Agent Architecture with A2A Protocol - Overview 

Costa Rica

[![GitHub](https://img.shields.io/badge/--181717?logo=github&logoColor=ffffff)](https://github.com/)
[brown9804](https://github.com/brown9804)

Last updated: 2026-02-02

----------

> [!IMPORTANT]
> Disclaimer: This repository contains a demo of `Zava AI Shopping Assistant`, a multi-agent system implementing Agent-to-Agent (A2A) protocol for e-commerce. It features a fully automated `"Zero-Touch" deployment` pipeline orchestrated by Terraform, which `provisions infrastructure, ingests data, creates specialized AI agents with delegation patterns in MSFT Foundry, and deploys the complete A2A application stack.` Feel free to modify this as needed, it's just a reference. Please refer [TechWorkshop L300: AI Apps and Agents](https://microsoft.github.io/TechWorkshop-L300-AI-Apps-and-agents/), and if needed contact Microsoft directly: [Microsoft Sales and Support](https://support.microsoft.com/contactus?ContactUsExperienceEntryPointAssetId=S.HP.SMC-HOME) for more guidance. There are tons of free resources out there, all eager to support!

<details>
<summary><b>List of References</b> (Click to expand)</summary>
  
- [Microsoft Foundry SDKs and Endpoints](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/sdk-overview?view=foundry&pivots=programming-language-python)
  
</details>

> E.g 

<div align="center">
  <img width="950" alt="image" src="https://github.com/user-attachments/assets/886cca9f-9630-4d5f-aca1-b4d37a42fa2d" style="border: 2px solid #4CAF50; border-radius: 5px; padding: 5px;"/>
</div>
  
> [!IMPORTANT]
> The deployment process typically takes 15-20 minutes
>
> 1. Adjust [terraform.tfvars](./terraform-infrastructure/terraform.tfvars) values 
> 2. Initialize terraform with `terraform init`. Click here to [understand more about the deployment process](./terraform-infrastructure/README.md)
> 3. Run `terraform apply`, you can also leverage `terraform apply -auto-approve`. 

## Key Features

- **Multi-agent chat orchestration (default runtime)**: WebSocket `/ws` chat app orchestrates multiple agents in a single conversation flow (routing + multi-step handoffs)
- **6-Agent Architecture (real Azure AI Foundry agents)**:
  - **Cora (Shopper)**: Front-facing assistant for general customer queries
  - **Interior Design Specialist**: Design expertise and style recommendations
  - **Inventory Manager**: Stock availability + product lookup coordination
  - **Customer Loyalty**: Rewards and discount-related queries
  - **Cart Manager**: Cart operations and checkout-oriented help
  - **Product Management Specialist**: Handles product-centric workflows and coordinates lookups across services
- **Intent routing + handoff planning**: Classifies user intent and plans a multi-step sequence of agent calls (instead of a single “one agent answers everything” flow)
- **Factual data integration**: Uses **Azure AI Search** (vector/keyword retrieval) and **Azure Cosmos DB** (catalog/state) during workflows
- **Real persistent agents**: Uses Azure AI Foundry Agents with saved runtime IDs (OpenAI-style `asst_*`) provisioned during deployment
- **Zero-touch deployment**: `terraform apply` provisions infra, ingests data, creates/updates agents, wires secrets/config, and deploys the Container Apps revision
- **UI-visible diagnostics**: Correlated `error_id` responses and optional tracebacks via `A2A_DEBUG=true` for faster troubleshooting
- **Optional A2A server included**: `src/a2a/` contains an A2A-style server framework, but it is not the default Container Apps entrypoint unless you deploy it explicitly

## About A2A Protocol

`A2A (Agent-to-Agent) Protocol is a standardized communication framework that enables multiple AI agents to collaborate and coordinate tasks seamlessly.` Like a communication pattern for coordinating multiple agents through structured messages, delegation, and (optionally) event-driven workflows.

This repo contains **two multi-agent implementations**:

- **Default deployed chat runtime (what the Dockerfile runs)**: WebSocket `/ws` in `src/chat_app_multi_agent.py`, which routes requests and orchestrates **real Azure AI Foundry Agents** in a multi-step handoff sequence.
- **Optional A2A server implementation**: an A2A-style server under `src/a2a/` (routers, coordinator, event/task framework). Use this only if you deploy/run that entrypoint.

> What is A2A Protocol?

- **Agent-to-Agent Communication**: structured messaging between multiple agents
- **Task Coordination**: agents can delegate tasks to specialized agents
- **Event-Driven Architecture (optional)**: event handling for asynchronous workflows
- **Agent Discovery (optional)**: enumerate/register available agents
- **Protocol Standardization**: consistent message formats and APIs

> How this repo implements multi-agent collaboration (default deployment)

- **WebSocket chat interface**: `/ws` endpoint served by `src/chat_app_multi_agent.py`
- **Intent routing**: classifies the user request and selects the primary domain (`src/services/handoff_service.py`)
- **Handoff planning**: builds a multi-step sequence of which agents to call (`src/chat_app_multi_agent.py`)
- **Remote agent execution**: calls Azure AI Foundry Agents using the saved `asst_*` IDs (`src/app/agents/agent_processor.py`)
- **Factual lookups**: uses Azure AI Search and Cosmos DB during workflows (called from the app runtime)

> A2A components included in this repo (optional server)

- **A2A server entrypoint**: `src/a2a/main.py`
- **A2A API routers**: `src/a2a/api/`
- **Agent execution framework**: `src/a2a/server/agent_execution.py`
- **Event system**: `src/a2a/server/events/`
- **Task coordination**: `src/a2a/server/tasks.py`
- **Request handlers**: `src/a2a/server/request_handlers.py`
- **Coordinator**: `src/a2a/agent/coordinator.py`
- **Agent implementations (examples)**: `src/app/agents/`
- **Product catalog helper/plugin (if used)**: `src/app/agents/product_information_plugin.py`

> [!IMPORTANT]
> A2A vs the default deployed chat runtime
>
> - **A2A server path**: event/task oriented framework under `src/a2a/` (only available if you deploy/run that server)
> - **Default path**: `/ws` WebSocket chat + routing + sequential handoffs to real Foundry agents (no event queue required for the default flow)

## Architecture

```mermaid
graph TD
    User[User] <--> UI[Chat Interface]
    UI <--> App[FastAPI Application]
    App <--> A2A[A2A Protocol Server]
    A2A <--> EventQueue[Event Queue]
    A2A <--> Coordinator[A2A Coordinator]
    
    Coordinator -->|A2A Protocol| Router{Agent Router}
    Router -->|Task Delegation| Cora[Cora Agent]
    Router -->|Design Tasks| Design[Interior Design Agent]
    Router -->|Inventory Events| Inventory[Inventory Agent]
    Router -->|Loyalty Tasks| Loyalty[Loyalty Agent]
    Router -->|Cart Events| Cart[Cart Agent]
    Router -->|Product Tasks| ProductMgr[Product Manager]
    
    ProductMgr -->|Marketing Tasks| Marketing[Marketing Agent]
    ProductMgr -->|Ranking Tasks| Ranker[Ranker Agent]
    ProductMgr -->|Factual Data| Plugin[Product Info Plugin]
    
    subgraph "A2A Communication"
        EventQueue <--> Cora
        EventQueue <--> Design
        EventQueue <--> Inventory
        EventQueue <--> Loyalty
        EventQueue <--> Cart
        EventQueue <--> ProductMgr
        EventQueue <--> Marketing
        EventQueue <--> Ranker
    end
    
    Inventory -->|Query| Search[Azure AI Search]
    Inventory -->|Lookup| Cosmos[Cosmos DB]
    Plugin -->|Catalog| PredefinedData[Product Catalog Data]
```

## What Happens Under the Hood?

> When you run `terraform apply`, the following automated sequence occurs:

1. **Infrastructure Provisioning**:
   - Creates Resource Group, Cosmos DB, MSFT Foundry, AI Search, Storage Account, Key Vault, and Container Registry (ACR).
   - Deploys AI Models (`gpt-4o-mini`, `text-embedding-3-small`).
   - Sets up A2A protocol infrastructure including event queues and monitoring.

      > E.g 
      
       <img width="1859" height="900" alt="image" src="https://github.com/user-attachments/assets/cd24ab7f-5ddd-46de-b266-0d0a24c45803" />

2. **A2A Framework Deployment**:
   - Initializes the Agent-to-Agent protocol server components.
   - Sets up event queue system for inter-agent communication.
   - Configures agent discovery and registration services.
   - Deploys A2A monitoring and automation frameworks.

3. **Data Pipeline Execution**:
   - Sets up a Python virtual environment.
   - Ingests `product_catalog.csv` into Cosmos DB with A2A event notifications.

        > E.g 

        <https://github.com/user-attachments/assets/41bf0976-0ca8-47fe-a2fa-8750bcc6f848>
   
   - Creates and populates an Azure AI Search index with vector embeddings through A2A coordination.

        > E.g 
        
        <https://github.com/user-attachments/assets/37c4a8cd-73e1-4392-8755-fb018481d8cb>

4. **Enhanced Agent Creation & A2A Registration**:
   - Installs the Azure AI SDKs (`azure-ai-projects` + `azure-ai-agents`) and authenticates via Entra ID.
   - Connects to MSFT Foundry / Agents API for agent hosting.
   - Provisions 6 specialized agents with enhanced A2A-style routing:
     - Core shopping agents (5) plus Product Management Specialist
     - Marketing Agent and Ranker Agent with delegation patterns
     - Product Information Plugin with predefined catalog data
   - Registers all agents with the enhanced A2A discovery service.
   - Configures delegation relationships between Product Manager and specialized agents.
   - Saves the unique runtime Agent IDs (OpenAI-style `asst_*`), endpoints, and configuration to the `.env` file.

      > E.g `Classic UI`
      
      <img width="1881" height="1000" alt="image" src="https://github.com/user-attachments/assets/59a9dcaf-9291-403c-b8b0-1195c1375aac" />

      > E.g `New Platform`:

      <img width="1887" height="606" alt="image" src="https://github.com/user-attachments/assets/02f9e726-6274-490e-8db7-111885a13871" />

5. **Application Deployment**:
   - Builds the Docker container with A2A protocol support in the cloud (ACR Build).
   - Deploys the container to Azure Container Apps (default) with the generated Agent IDs, endpoints, and credentials.
   - Updates the running revision so the app picks up the latest agent IDs and configuration.

## Verification

> After deployment completes, verify the system:

1. **Check the App**:
   - The Terraform output will provide the `chat_application_url`.
   - Visit `https://<your-app-name>.azurecontainerapps.io`.
   - You should see the Zava chat interface with multi-agent routing enabled.

      > E.g `Classic UI`
      
       <https://github.com/user-attachments/assets/a1139528-6b37-4ac2-a1cb-771788ff45a4>

2. **Verify A2A Protocol Endpoints**:
   - Check A2A Chat API: `https://<your-app-name>.azurecontainerapps.io/a2a/chat`
   - Check A2A Server API: `https://<your-app-name>.azurecontainerapps.io/a2a/api/docs`
   - Verify agent discovery: `https://<your-app-name>.azurecontainerapps.io/a2a/server/agents`

3. **Verify Enhanced Agent Architecture**:
   - Go to the [MSFT Foundry Portal](https://ai.azure.com).
   - Navigate to your project -> **Build** -> **Agents**.
   - You should see all 6 agents listed with enhanced A2A protocol integration:
     - Core agents: Cora, Interior Design, Inventory, Loyalty, Cart Manager
     - Product Management Specialist with delegation capabilities

      > E.g `Classic UI`
      
      <https://github.com/user-attachments/assets/3c562ccd-cff3-4a30-b9f8-44111fb71113>

4. **Test Multi-Agent Routing (UI)**: `Adjust as needed, this is just a base`. For example:
    - **General**: “Hi, who are you?” (Routed to **Cora**)
    - **Inventory**: “Do you have the classic leather sofa in stock?” (Routed to **Inventory Manager**)
    - **Design**: “What colors of green paint do you have?” (Routed to **Interior Design Specialist**)
    - **Product Recommendations**: “Recommend modern furniture for my living room” (Routed to **Product Management Specialist**; may consult catalog/search depending on its prompt/tools)
    - **Product Comparisons**: “Compare sectional sofas” (Routed to **Product Management Specialist**; comparison is handled within that agent)
    - **Product Details**: “What are the specifications of product SOFA-001?” (Routed to **Product Management Specialist**; details are handled within that agent)
    - **Multi-Agent**: “Find a sofa, then verify my loyalty points, and add it to my cart” (Coordinated across **Product Management → Customer Loyalty → Cart Manager** via the app’s multi-step routing)
      
<!-- START BADGE -->
<div align="center">
  <img src="https://img.shields.io/badge/Total%20views-1416-limegreen" alt="Total views">
  <p>Refresh Date: 2026-02-02</p>
</div>
<!-- END BADGE -->
