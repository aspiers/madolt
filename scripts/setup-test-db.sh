#!/usr/bin/env bash
#
# Setup a test Dolt database for madolt interactive QA testing.
#
# Usage: scripts/setup-test-db.sh [DIR] [NUM_COMMITS]
#
#   DIR          Target directory (default: tmp/test-dolt)
#   NUM_COMMITS  Number of commits to generate (default: 10, minimum: 4)
#
# The resulting database has:
#   - Multiple tables (users, orders, products)
#   - The specified number of commits with realistic data
#   - A feature branch diverging from partway through history
#   - Some staged changes (ready to commit)
#   - Some unstaged changes (working tree modifications)

set -euo pipefail

DIR="${1:-tmp/test-dolt}"
NUM_COMMITS="${2:-10}"

if [ "$NUM_COMMITS" -lt 4 ]; then
    echo "Error: NUM_COMMITS must be at least 4 (got $NUM_COMMITS)" >&2
    exit 1
fi

echo "Setting up test Dolt database in $DIR with $NUM_COMMITS commits..."

# Clean slate
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

dolt init

# --- Commit 1: Create users table ---
dolt sql -q "CREATE TABLE users (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(200) NOT NULL,
    role VARCHAR(50) DEFAULT 'user',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
)"
dolt sql -q "INSERT INTO users (id, name, email, role) VALUES
    (1, 'Alice Johnson', 'alice@example.com', 'admin'),
    (2, 'Bob Smith', 'bob@example.com', 'user')"
dolt add .
dolt commit -m "Create users table with initial data"

# --- Commit 2: Create orders table ---
dolt sql -q "CREATE TABLE orders (
    id INT PRIMARY KEY AUTO_INCREMENT,
    user_id INT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
)"
dolt sql -q "INSERT INTO orders (id, user_id, amount, status) VALUES
    (1, 1, 99.99, 'completed'),
    (2, 2, 45.50, 'pending')"
dolt add .
dolt commit -m "Add orders table with sample orders"

# --- Commit 3: Add more users ---
dolt sql -q "INSERT INTO users (id, name, email) VALUES
    (3, 'Charlie Brown', 'charlie@example.com'),
    (4, 'Diana Prince', 'diana@example.com')"
dolt add .
dolt commit -m "Add Charlie and Diana to users"

# --- Create feature branch here (partway through history) ---
dolt checkout -b feature-branch
dolt checkout main

# --- Commit 4: Create products table ---
dolt sql -q "CREATE TABLE products (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(200) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    category VARCHAR(100),
    in_stock BOOLEAN DEFAULT TRUE
)"
dolt sql -q "INSERT INTO products (id, name, price, category) VALUES
    (1, 'Widget', 19.99, 'gadgets'),
    (2, 'Gizmo', 34.99, 'gadgets'),
    (3, 'Thingamajig', 9.99, 'misc')"
dolt add .
dolt commit -m "Add products table with inventory"

# --- Generate remaining commits with varied data changes ---
# Names and emails for generating realistic data
NAMES=("Eve Torres" "Frank Castle" "Grace Hopper" "Hank Pym" "Iris West"
       "Jack Reacher" "Kate Bishop" "Leo Fitz" "Maya Lopez" "Nick Fury"
       "Olivia Pope" "Peter Parker" "Quinn Hughes" "Rosa Diaz" "Sam Wilson"
       "Tina Fey" "Uma Thurman" "Vic Stone" "Wanda Maximoff" "Xena Warrior")

PRODUCTS=("Doohickey" "Whatchamacallit" "Contraption" "Apparatus" "Mechanism"
          "Implement" "Utensil" "Instrument" "Appliance" "Gadget Pro"
          "Widget Plus" "Gizmo Max" "Super Tool" "Mega Device" "Ultra Kit")

CATEGORIES=("gadgets" "tools" "misc" "electronics" "accessories")

COMMIT_MESSAGES=(
    "Update user profiles"
    "Add new orders"
    "Expand product catalog"
    "Fix user email addresses"
    "Add bulk order data"
    "Update product pricing"
    "Add new team members"
    "Process pending orders"
    "Reorganize product categories"
    "Update inventory status"
    "Add premium users"
    "Fulfill outstanding orders"
    "Add seasonal products"
    "Update user roles"
    "Add international orders"
    "Refresh product catalog"
)

user_id=5
order_id=3
product_id=4

for i in $(seq 5 "$NUM_COMMITS"); do
    # Cycle through different types of changes
    case $(( (i - 1) % 4 )) in
        0)
            # Add a user
            name_idx=$(( (i - 5) % ${#NAMES[@]} ))
            name="${NAMES[$name_idx]}"
            email=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '.' | sed 's/$/@example.com/')
            dolt sql -q "INSERT INTO users (id, name, email) VALUES ($user_id, '$name', '$email')"
            user_id=$((user_id + 1))
            ;;
        1)
            # Add an order
            uid=$(( (i % (user_id - 1)) + 1 ))
            amount=$(( (RANDOM % 500) + 10 )).$(( RANDOM % 100 ))
            status=$([ $(( i % 3 )) -eq 0 ] && echo "completed" || echo "pending")
            dolt sql -q "INSERT INTO orders (id, user_id, amount, status) VALUES ($order_id, $uid, $amount, '$status')"
            order_id=$((order_id + 1))
            ;;
        2)
            # Add a product
            prod_idx=$(( (i - 5) % ${#PRODUCTS[@]} ))
            prod_name="${PRODUCTS[$prod_idx]}"
            price=$(( (RANDOM % 200) + 5 )).$(( RANDOM % 100 ))
            cat_idx=$(( i % ${#CATEGORIES[@]} ))
            dolt sql -q "INSERT INTO products (id, name, price, category) VALUES ($product_id, '$prod_name', $price, '${CATEGORIES[$cat_idx]}')"
            product_id=$((product_id + 1))
            ;;
        3)
            # Modify existing data
            dolt sql -q "UPDATE users SET role = 'moderator' WHERE id = $(( (i % 3) + 1 )) AND role = 'user'"
            dolt sql -q "UPDATE orders SET status = 'completed' WHERE id = $(( (i % order_id) + 1 )) AND status = 'pending'"
            ;;
    esac

    msg_idx=$(( (i - 5) % ${#COMMIT_MESSAGES[@]} ))
    dolt add .
    dolt commit -m "${COMMIT_MESSAGES[$msg_idx]}"
done

# --- Add some commits on the feature branch ---
dolt checkout feature-branch
dolt sql -q "INSERT INTO users (id, name, email, role) VALUES
    ($user_id, 'Feature User', 'feature@example.com', 'beta')"
dolt add .
dolt commit -m "Add beta tester on feature branch"

dolt sql -q "ALTER TABLE users ADD COLUMN bio TEXT"
dolt sql -q "UPDATE users SET bio = 'Original beta tester' WHERE email = 'feature@example.com'"
dolt add .
dolt commit -m "Add bio column to users table"

# --- Switch back to main ---
dolt checkout main

# --- Create staged changes (not yet committed) ---
dolt sql -q "INSERT INTO users (id, name, email) VALUES
    ($((user_id + 1)), 'Staged User', 'staged@example.com')"
dolt sql -q "INSERT INTO orders (id, user_id, amount, status) VALUES
    ($order_id, 1, 199.99, 'pending')"
dolt add users

# --- Create unstaged changes (working tree only) ---
dolt sql -q "UPDATE products SET price = price * 1.1 WHERE category = 'gadgets'"
dolt sql -q "INSERT INTO products (id, name, price, category) VALUES
    ($((product_id + 1)), 'Unstaged Widget', 29.99, 'new')"

echo ""
echo "Test database created in $DIR"
echo "  - $NUM_COMMITS commits on main"
echo "  - 2 commits on feature-branch"
echo "  - Staged: users table (new user added)"
echo "  - Unstaged: products table (price updates + new product)"
echo "  - Unstaged: orders table (new order)"
