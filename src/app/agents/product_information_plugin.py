"""
Product Information Plugin - Allows agents to look up product information from predefined list

This plugin provides functionality for agents to access specific product information
and perform particular tasks using factual data from a predefined product catalog.
"""
import logging
from typing import Dict, List, Optional, Any
from datetime import datetime

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class ProductInformationPlugin:
    """
    Plugin that encapsulates product lookup functionality from a predefined list
    
    This plugin allows agents to access factual product information rather than
    generating responses based solely on instructions.
    """
    
    def __init__(self):
        """Initialize with predefined product catalog"""
        self.product_catalog = self._initialize_product_catalog()
        logger.info(f"ProductInformationPlugin initialized with {len(self.product_catalog)} products")
    
    def _initialize_product_catalog(self) -> List[Dict[str, Any]]:
        """Initialize predefined product catalog with factual information"""
        
        catalog = [
            {
                "id": "SOFA-001",
                "name": "ModernComfort Sectional Sofa",
                "category": "Living Room",
                "subcategory": "Sofas",
                "price": 1299.99,
                "description": "3-piece sectional sofa with premium fabric upholstery",
                "specifications": {
                    "dimensions": "108W x 85D x 36H inches",
                    "material": "High-grade fabric with foam cushioning",
                    "color_options": ["Charcoal Gray", "Navy Blue", "Beige"],
                    "weight_capacity": "300 lbs per seat",
                    "assembly_required": True
                },
                "availability": {
                    "in_stock": True,
                    "stock_level": 15,
                    "next_shipment": "2025-12-10",
                    "estimated_delivery": "3-5 business days"
                },
                "reviews": {
                    "average_rating": 4.3,
                    "total_reviews": 89,
                    "rating_breakdown": {"5_star": 45, "4_star": 28, "3_star": 12, "2_star": 3, "1_star": 1}
                },
                "features": ["Removable cushions", "Stain-resistant fabric", "2-year warranty"],
                "tags": ["modern", "sectional", "comfortable", "family-friendly"]
            },
            {
                "id": "TABLE-001", 
                "name": "Rustic Oak Coffee Table",
                "category": "Living Room",
                "subcategory": "Tables",
                "price": 449.99,
                "description": "Solid oak coffee table with rustic finish and storage drawer",
                "specifications": {
                    "dimensions": "48W x 24D x 18H inches", 
                    "material": "Solid oak wood with natural finish",
                    "color_options": ["Natural Oak", "Dark Walnut"],
                    "weight_capacity": "75 lbs",
                    "assembly_required": True
                },
                "availability": {
                    "in_stock": True,
                    "stock_level": 8,
                    "next_shipment": "2025-12-15",
                    "estimated_delivery": "5-7 business days"
                },
                "reviews": {
                    "average_rating": 4.7,
                    "total_reviews": 156,
                    "rating_breakdown": {"5_star": 98, "4_star": 42, "3_star": 12, "2_star": 3, "1_star": 1}
                },
                "features": ["Storage drawer", "Solid wood construction", "Rustic finish", "5-year warranty"],
                "tags": ["rustic", "oak", "storage", "durable"]
            },
            {
                "id": "CHAIR-001",
                "name": "Ergonomic Office Chair Pro",
                "category": "Office", 
                "subcategory": "Chairs",
                "price": 329.99,
                "description": "Professional ergonomic office chair with lumbar support",
                "specifications": {
                    "dimensions": "26W x 26D x 40-44H inches (adjustable)",
                    "material": "Mesh back with cushioned seat",
                    "color_options": ["Black", "Gray", "Blue"],
                    "weight_capacity": "250 lbs",
                    "assembly_required": True
                },
                "availability": {
                    "in_stock": True,
                    "stock_level": 22,
                    "next_shipment": "2025-12-08",
                    "estimated_delivery": "2-4 business days"
                },
                "reviews": {
                    "average_rating": 4.5,
                    "total_reviews": 203,
                    "rating_breakdown": {"5_star": 122, "4_star": 58, "3_star": 18, "2_star": 4, "1_star": 1}
                },
                "features": ["Adjustable height", "Lumbar support", "360-degree swivel", "5-wheel base", "3-year warranty"],
                "tags": ["ergonomic", "office", "adjustable", "professional"]
            },
            {
                "id": "LAMP-001",
                "name": "Contemporary Floor Lamp",
                "category": "Lighting",
                "subcategory": "Floor Lamps", 
                "price": 189.99,
                "description": "Modern floor lamp with adjustable brightness and USB charging port",
                "specifications": {
                    "dimensions": "12W x 12D x 58H inches",
                    "material": "Metal base with fabric shade",
                    "color_options": ["Brushed Steel", "Matte Black", "Antique Brass"],
                    "wattage": "60W LED compatible",
                    "assembly_required": False
                },
                "availability": {
                    "in_stock": True,
                    "stock_level": 31,
                    "next_shipment": "2025-12-12",
                    "estimated_delivery": "1-3 business days"
                },
                "reviews": {
                    "average_rating": 4.1,
                    "total_reviews": 67,
                    "rating_breakdown": {"5_star": 32, "4_star": 21, "3_star": 10, "2_star": 3, "1_star": 1}
                },
                "features": ["Adjustable brightness", "USB charging port", "Touch controls", "Energy efficient LED", "1-year warranty"],
                "tags": ["contemporary", "adjustable", "USB", "LED"]
            },
            {
                "id": "DESK-001",
                "name": "Executive Standing Desk",
                "category": "Office",
                "subcategory": "Desks",
                "price": 899.99,
                "description": "Height-adjustable standing desk with memory settings and cable management",
                "specifications": {
                    "dimensions": "60W x 30D x 28-48H inches (adjustable)",
                    "material": "Engineered wood top with steel frame",
                    "color_options": ["Espresso", "White Oak", "Gray"],
                    "weight_capacity": "200 lbs",
                    "assembly_required": True
                },
                "availability": {
                    "in_stock": False,
                    "stock_level": 0,
                    "next_shipment": "2025-12-20",
                    "estimated_delivery": "7-10 business days after restock"
                },
                "reviews": {
                    "average_rating": 4.6,
                    "total_reviews": 134,
                    "rating_breakdown": {"5_star": 89, "4_star": 32, "3_star": 9, "2_star": 3, "1_star": 1}
                },
                "features": ["Electric height adjustment", "Memory settings", "Cable management", "Anti-collision", "5-year warranty"],
                "tags": ["standing", "adjustable", "executive", "ergonomic"]
            }
        ]
        
        return catalog
    
    def lookup_product_by_id(self, product_id: str) -> Optional[Dict[str, Any]]:
        """Look up specific product by ID"""
        
        for product in self.product_catalog:
            if product["id"] == product_id:
                logger.info(f"Product found: {product['name']} (ID: {product_id})")
                return product
        
        logger.warning(f"Product not found: {product_id}")
        return None
    
    def search_products_by_name(self, name_query: str) -> List[Dict[str, Any]]:
        """Search products by name (partial match)"""
        
        name_query = name_query.lower()
        matching_products = []
        
        for product in self.product_catalog:
            if name_query in product["name"].lower():
                matching_products.append(product)
        
        logger.info(f"Name search for '{name_query}' found {len(matching_products)} products")
        return matching_products
    
    def filter_products_by_category(self, category: str, subcategory: str = None) -> List[Dict[str, Any]]:
        """Filter products by category and optionally subcategory"""
        
        filtered_products = []
        
        for product in self.product_catalog:
            if product["category"].lower() == category.lower():
                if subcategory is None or product["subcategory"].lower() == subcategory.lower():
                    filtered_products.append(product)
        
        logger.info(f"Category filter for '{category}' found {len(filtered_products)} products")
        return filtered_products
    
    def filter_products_by_price_range(self, min_price: float, max_price: float) -> List[Dict[str, Any]]:
        """Filter products by price range"""
        
        filtered_products = []
        
        for product in self.product_catalog:
            if min_price <= product["price"] <= max_price:
                filtered_products.append(product)
        
        logger.info(f"Price filter ${min_price}-${max_price} found {len(filtered_products)} products")
        return filtered_products
    
    def get_product_availability(self, product_id: str) -> Optional[Dict[str, Any]]:
        """Get availability information for a specific product"""
        
        product = self.lookup_product_by_id(product_id)
        if product:
            return product["availability"]
        
        return None
    
    def get_product_reviews_summary(self, product_id: str) -> Optional[Dict[str, Any]]:
        """Get reviews summary for a specific product"""
        
        product = self.lookup_product_by_id(product_id)
        if product:
            return product["reviews"]
        
        return None
    
    def search_products_by_tags(self, tags: List[str]) -> List[Dict[str, Any]]:
        """Search products by tags"""
        
        matching_products = []
        
        for product in self.product_catalog:
            product_tags = [tag.lower() for tag in product["tags"]]
            if any(tag.lower() in product_tags for tag in tags):
                matching_products.append(product)
        
        logger.info(f"Tag search for {tags} found {len(matching_products)} products")
        return matching_products
    
    def get_all_categories(self) -> List[str]:
        """Get list of all available categories"""
        
        categories = list(set(product["category"] for product in self.product_catalog))
        return sorted(categories)
    
    def get_product_summary(self, product_id: str) -> Optional[str]:
        """Get a formatted summary of product information"""
        
        product = self.lookup_product_by_id(product_id)
        if not product:
            return None
        
        availability_status = "In Stock" if product["availability"]["in_stock"] else "Out of Stock"
        
        summary = f"""
Product: {product['name']} ({product['id']})
Category: {product['category']} > {product['subcategory']}
Price: ${product['price']:.2f}
Rating: {product['reviews']['average_rating']}/5 ({product['reviews']['total_reviews']} reviews)
Availability: {availability_status}
Key Features: {', '.join(product['features'])}
Description: {product['description']}
        """.strip()
        
        return summary

# Example usage and testing functions
def demo_product_plugin():
    """Demonstrate the Product Information Plugin functionality"""
    
    plugin = ProductInformationPlugin()
    
    print("=== Product Information Plugin Demo ===")
    
    # Test product lookup by ID
    print("\\n1. Lookup product by ID:")
    sofa = plugin.lookup_product_by_id("SOFA-001")
    if sofa:
        print(f"Found: {sofa['name']} - ${sofa['price']}")
    
    # Test search by name
    print("\\n2. Search by name:")
    chairs = plugin.search_products_by_name("chair")
    for chair in chairs:
        print(f"  - {chair['name']}")
    
    # Test filter by category
    print("\\n3. Filter by category:")
    office_products = plugin.filter_products_by_category("Office")
    for product in office_products:
        print(f"  - {product['name']} (${product['price']})")
    
    # Test price range filter
    print("\\n4. Filter by price range ($200-$500):")
    mid_range = plugin.filter_products_by_price_range(200, 500)
    for product in mid_range:
        print(f"  - {product['name']} (${product['price']})")
    
    # Test product summary
    print("\\n5. Product summary:")
    summary = plugin.get_product_summary("LAMP-001")
    print(summary)

if __name__ == "__main__":
    demo_product_plugin()