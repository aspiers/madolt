#!/bin/bash
# Set up a dolt repo with interesting state for the madolt demo
set -e

DEMO_DIR="${1:-/tmp/madolt-demo-db}"

rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

dolt init

# Create initial tables and commit
dolt sql -q "CREATE TABLE employees (
  id INT PRIMARY KEY,
  name VARCHAR(100),
  department VARCHAR(50),
  salary DECIMAL(10,2)
)"
dolt sql -q "INSERT INTO employees VALUES
  (1, 'Alice Chen', 'Engineering', 95000.00),
  (2, 'Bob Martinez', 'Marketing', 72000.00),
  (3, 'Carol Williams', 'Engineering', 105000.00)"

dolt sql -q "CREATE TABLE departments (
  id INT PRIMARY KEY,
  name VARCHAR(50),
  budget DECIMAL(12,2)
)"
dolt sql -q "INSERT INTO departments VALUES
  (1, 'Engineering', 500000.00),
  (2, 'Marketing', 200000.00),
  (3, 'Sales', 150000.00)"

dolt add .
dolt commit -m "Initial schema with employees and departments"

# Second commit - add more data
dolt sql -q "INSERT INTO employees VALUES
  (4, 'Diana Lopez', 'Sales', 68000.00),
  (5, 'Erik Johnson', 'Engineering', 110000.00)"
dolt add .
dolt commit -m "Add new hires Diana and Erik"

# Third commit
dolt sql -q "UPDATE departments SET budget = 550000.00 WHERE name = 'Engineering'"
dolt add .
dolt commit -m "Increase Engineering budget"

# Now create the interesting working state for the demo:

# 1. Stage a modification to employees (salary raise)
dolt sql -q "UPDATE employees SET salary = 100000.00 WHERE name = 'Alice Chen'"
dolt sql -q "UPDATE employees SET salary = 115000.00 WHERE name = 'Carol Williams'"
dolt add employees

# 2. Make unstaged changes to departments
dolt sql -q "UPDATE departments SET budget = 250000.00 WHERE name = 'Marketing'"
dolt sql -q "INSERT INTO departments VALUES (4, 'Research', 300000.00)"

# 3. Create an untracked table
dolt sql -q "CREATE TABLE projects (
  id INT PRIMARY KEY,
  name VARCHAR(100),
  lead_id INT,
  status VARCHAR(20)
)"
dolt sql -q "INSERT INTO projects VALUES
  (1, 'Database Migration', 3, 'active'),
  (2, 'New Website', 2, 'planning'),
  (3, 'API Redesign', 5, 'active')"

echo "Demo repo ready at $DEMO_DIR"
echo ""
dolt status
