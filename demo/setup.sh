#!/bin/bash
# Set up a dolt repo with interesting state for the madolt demo
set -e

DEMO_DIR="${1:-/tmp/madolt-demo-db}"

rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

dolt init

# Create initial tables and commit
# employees: 9 columns to showcase wide-table width allocation
dolt sql -q "CREATE TABLE employees (
  id INT PRIMARY KEY,
  name VARCHAR(100),
  email VARCHAR(100),
  department VARCHAR(50),
  title VARCHAR(80),
  salary DECIMAL(10,2),
  hire_date DATE,
  location VARCHAR(50),
  phone VARCHAR(20)
)"
dolt sql -q "INSERT INTO employees VALUES
  (1, 'Alice Chen',      'alice@example.com',  'Engineering', 'Senior Engineer',    95000.00, '2022-03-15', 'San Francisco', '555-0101'),
  (2, 'Bob Martinez',    'bob@example.com',    'Marketing',   'Marketing Manager',  72000.00, '2023-01-10', 'New York',      '555-0102'),
  (3, 'Carol Williams',  'carol@example.com',  'Engineering', 'Staff Engineer',    105000.00, '2021-06-01', 'San Francisco', '555-0103')"

# departments: 7 columns
dolt sql -q "CREATE TABLE departments (
  id INT PRIMARY KEY,
  name VARCHAR(50),
  budget DECIMAL(12,2),
  head_count INT,
  location VARCHAR(50),
  floor INT,
  founded DATE
)"
dolt sql -q "INSERT INTO departments VALUES
  (1, 'Engineering', 500000.00, 12, 'San Francisco', 3, '2019-01-01'),
  (2, 'Marketing',   200000.00,  6, 'New York',      5, '2019-06-15'),
  (3, 'Sales',       150000.00,  8, 'Chicago',       2, '2020-03-01')"

dolt add .
dolt commit -m "Initial schema with employees and departments"

# Second commit - add more data
dolt sql -q "INSERT INTO employees VALUES
  (4, 'Diana Lopez',   'diana@example.com', 'Sales',       'Account Executive', 68000.00, '2024-02-20', 'Chicago',       '555-0104'),
  (5, 'Erik Johnson',  'erik@example.com',  'Engineering', 'Principal Engineer',110000.00, '2020-11-05', 'San Francisco', '555-0105')"
dolt add .
dolt commit -m "Add new hires Diana and Erik"

# Third commit
dolt sql -q "UPDATE departments SET budget = 550000.00 WHERE name = 'Engineering'"
dolt add .
dolt commit -m "Increase Engineering budget"

# Now create the interesting working state for the demo:

# 1. Stage a modification to employees (salary raise + title change)
dolt sql -q "UPDATE employees SET salary = 100000.00, title = 'Staff Engineer' WHERE name = 'Alice Chen'"
dolt sql -q "UPDATE employees SET salary = 115000.00 WHERE name = 'Carol Williams'"
dolt add employees

# 2. Make unstaged changes to departments
dolt sql -q "UPDATE departments SET budget = 250000.00, head_count = 8 WHERE name = 'Marketing'"
dolt sql -q "INSERT INTO departments VALUES (4, 'Research', 300000.00, 3, 'Boston', 4, '2025-01-15')"

# 3. Create an untracked table (9 columns)
dolt sql -q "CREATE TABLE projects (
  id INT PRIMARY KEY,
  name VARCHAR(100),
  lead_id INT,
  status VARCHAR(20),
  start_date DATE,
  end_date DATE,
  budget DECIMAL(10,2),
  priority VARCHAR(10),
  category VARCHAR(30)
)"
dolt sql -q "INSERT INTO projects VALUES
  (1, 'Database Migration', 3, 'active',   '2025-01-10', '2025-06-30', 150000.00, 'high',   'Infrastructure'),
  (2, 'New Website',        2, 'planning', '2025-03-01', '2025-09-15',  80000.00, 'medium', 'Marketing'),
  (3, 'API Redesign',       5, 'active',   '2025-02-01', '2025-08-01', 120000.00, 'high',   'Engineering')"

# 4. Configure a remote
dolt remote add origin aspiers/madolt-demo-db

echo "Demo repo ready at $DEMO_DIR"
echo ""
dolt status
