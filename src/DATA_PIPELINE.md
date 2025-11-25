# Data Pipeline Automation - Overview 

Costa Rica

[![GitHub](https://img.shields.io/badge/--181717?logo=github&logoColor=ffffff)](https://github.com/)
[brown9804](https://github.com/brown9804)

Last updated: 2025-11-24

----------

> This automation handles the complete data pipeline setup for the Azure AI Shopping application.

<details>
<summary><b>Table of Content</b> (Click to expand)</summary>

- [Usage](#usage)
- [Data Files](#data-files)
- [Scripts](#scripts)
- [Troubleshooting](#troubleshooting)
- [Configuration](#configuration)
- [Environment Variable Reference](#environment-variable-reference)
- [Verification](#verification)
- [Check Cosmos DB](#check-cosmos-db)
- [Check Search Index](#check-search-index)
- [Query Search Index](#query-search-index)
- [Next Steps](#next-steps)

</details>

> [!NOTE]
> What It Does? The data pipeline automation performs the following tasks:
>
> 1. **Creates Python Virtual Environment**: Sets up an isolated Python environment with all required dependencies
> 2. **Imports Data to Cosmos DB**: Loads product catalog data from CSV into Cosmos DB container
> 3. **Creates Azure AI Search Index**: Sets up a search index with vector search capabilities
> 4. **Imports Data to Search**: Populates the search index from Cosmos DB using an indexer

<details>
<summary><b> Prerequisites: </b> (Click to expand)</summary>

> - Python 3.8 or higher installed and available in PATH
> - Product catalog CSV file at `src/data/updated_product_catalog(in).csv` (demo)

</details>

> Automated by Terraform:

- Cosmos DB account and database
- Azure AI Search service
- Azure OpenAI model deployments
- Environment variables in `src/.env`

## Usage

> Option 1: Run Automatically with Terraform → Enable data pipeline automation in `terraform.tfvars`:

```hcl
enable_data_pipeline = true
```

Then run:

```bash
terraform apply -auto-approve
```

This will:

- Deploy all Azure resources
- Create AI model deployments
- Generate `.env` file
- **Automatically run the complete data pipeline**

> Option 2: Run Manually → If you prefer to run the data pipeline manually or separately:

1. **Ensure `.env` file exists** (created by Terraform):

   ```bash
   cd terraform-infrastructure
   terraform apply -auto-approve
   ```

2. **Navigate to src directory**:

   ```bash
   cd ../src
   ```

3. **Create virtual environment and install dependencies**:

   ```powershell
   python -m venv venv
   .\venv\Scripts\Activate.ps1
   pip install --upgrade pip
   pip install -r requirements.txt
   ```

4. **Run pipeline scripts in order**:

   ```powershell
   # Step 1: Import data to Cosmos DB
   python pipelines/ingest_to_cosmos.py
   
   # Step 2: Create Azure AI Search index
   python pipelines/create_search_index.py
   
   # Step 3: Upload data to search index
   python pipelines/upload_to_search.py
   ```

## Data Files

> Product Catalog CSV → The product catalog data should be placed at:

```
src/data/updated_product_catalog(in).csv
```

> Expected columns:

- `ProductID`: Unique product identifier
- `ProductName`: Product name
- `ProductCategory`: Product category
- `ProductDescription`: Product description
- `ProductPrice`: Product price
- `ProductImageURL`: URL to product image

> Download Data → If you don't have the data file, you can download it from the reference repository [TechWorkshop-L300-AI-Apps-and-agents](https://github.com/microsoft/TechWorkshop-L300-AI-Apps-and-agents/tree/main), please feel free to follow the guide as well [Guide - TechWorkshop L300: AI Apps and Agents](https://microsoft.github.io/TechWorkshop-L300-AI-Apps-and-agents/):

```bash
# Download the product catalog data
curl -o src/data/updated_product_catalog(in).csv https://raw.githubusercontent.com/microsoft/TechWorkshop-L300-AI-Apps-and-agents/main/src/data/updated_product_catalog(in).csv
```

## Scripts

<details>
<summary><b> pipelines/ingest_to_cosmos.py </b> (Click to expand)</summary>

- Reads CSV data with product catalog
- Connects to Cosmos DB (uses AAD or key-based auth)
- Creates database and container if they don't exist
- Imports all products with upsert operations
- Creates `content_for_vector` field for semantic search
- **Smart Skip Logic**: 
  - By default (`COSMOS_SKIP_IF_EXISTS=true`), checks if container already has data
  - If data exists, skips import to avoid duplicates and save time
  - Set `COSMOS_FORCE_INGEST=true` to force re-import even if data exists
  - Set `COSMOS_SKIP_IF_EXISTS=false` to always import (legacy behavior)

</details>

<details>
<summary><b> pipelines/create_search_index.py </b> (Click to expand)</summary>

- Creates Azure AI Search index with vector search
- Configures HNSW algorithm for vector search
- Sets up Azure OpenAI vectorizer
- Defines searchable and filterable fields

</details>

<details>
<summary><b> pipelines/create_search_index.py </b> (Click to expand)</summary>

- Creates Azure AI Search index with vector search capabilities
- Configures HNSW algorithm for efficient vector similarity search
- Sets up Azure OpenAI vectorizer with text-embedding-3-small model
- Defines searchable, filterable, and vector fields
- Supports hybrid search (keyword + semantic)

</details>

<details>
<summary><b>  pipelines/create_search_index.py </b> (Click to expand)</summary>

- Creates Azure AI Search index with vector search
- Configures HNSW algorithm for vector search
- Sets up Azure OpenAI vectorizer
- Defines searchable and filterable fields

</details>

<details>
<summary><b>  pipelines/upload_to_search.py  </b> (Click to expand)</summary>

- Reads all documents from Cosmos DB container
- Authenticates using AAD or key-based auth (auto-fallback)
- Maps Cosmos DB fields to Azure AI Search index schema
- Uploads documents in batches to Azure AI Search
- Provides detailed success/failure reporting
- **Note**: This script replaces the traditional indexer approach to avoid managed identity complexity when Cosmos DB local auth is disabled

</details>

## Troubleshooting

> For detailed troubleshooting guidance, see [TROUBLESHOOTING.md](../TROUBLESHOOTING.md). Quick Reference: 

- **Python Not Found**: Install Python 3.8+ from <https://www.python.org/downloads/>
- **CSV File Not Found**: Download the product catalog CSV file and place it in `src/data/` directory
- **Authentication Errors**: Run `az login` and ensure you have proper permissions. See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#azure-authentication-issues) for detailed solutions.
- **Virtual Environment Issues**: Delete `venv` folder and recreate. See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#python-environment-issues) for details.

## Configuration

> All configuration is pulled from the `.env` file created by Terraform:

```bash
COSMOS_DB_ENDPOINT=...
COSMOS_DB_KEY=...
COSMOS_DB_NAME=...
COSMOS_DB_CONTAINER_NAME=products
COSMOS_SKIP_IF_EXISTS=true          # Skip import if data already exists
COSMOS_FORCE_INGEST=false           # Force re-import even if data exists
SEARCH_SERVICE_ENDPOINT=...
SEARCH_SERVICE_KEY=...
SEARCH_INDEX_NAME=products-index
AZURE_OPENAI_ENDPOINT=...
AZURE_OPENAI_API_KEY=...
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
```

## Environment Variable Reference

| Variable                   | Default | Description                                           |
|----------------------------|---------|-------------------------------------------------------|
| `COSMOS_SKIP_IF_EXISTS`    | `true`  | Skip import if container already has data            |
| `COSMOS_FORCE_INGEST`      | `false` | Force re-import even if data exists (overrides skip) |
| `COSMOS_DB_ENDPOINT`       | -       | Cosmos DB account endpoint URL                       |
| `COSMOS_DB_KEY`            | -       | Cosmos DB account key (optional if using AAD)        |
| `COSMOS_DB_NAME`          | -       | Database name                                        |
| `COSMOS_DB_CONTAINER_NAME` | -       | Container name for product catalog                   |

## Verification

> After running the pipeline, verify data was imported:

## Check Cosmos DB

```powershell
az cosmosdb sql container show \
  --account-name <cosmos-account> \
  --database-name zava \
  --name products \
  --resource-group <rg-name>
```

## Check Search Index

```powershell
az search index show \
  --index-name products-index \
  --service-name <search-service> \
  --resource-group <rg-name>
```

## Query Search Index

```powershell
az search index show-statistics \
  --index-name products-index \
  --service-name <search-service> \
  --resource-group <rg-name>
```

## Next Steps

> After the data pipeline completes:

1. Your Cosmos DB container is populated with product data
2. Azure AI Search index is created with vector search enabled
3. Search index is populated from Cosmos DB
4. You can now build AI agents that query this data
5. Use the search index for hybrid search (keyword + semantic)

<!-- START BADGE -->
<div align="center">
  <img src="https://img.shields.io/badge/Total%20views-1543-limegreen" alt="Total views">
  <p>Refresh Date: 2025-11-25</p>
</div>
<!-- END BADGE -->
