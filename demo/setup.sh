#!/bin/bash
# Set up a dolt repo with interesting state for the madolt demo.
#
# Creates a history with:
#   - Multiple commits on main (employees, departments)
#   - A tag (v0.1)
#   - A feature branch that diverges from main with conflicting changes
#   - Extra commits on main after divergence (for non-ff merge + graph)
#   - A "fix typo" commit suitable for squashing during rebase demo
#   - Working state: staged + unstaged + untracked tables
#
# The resulting state supports all demo scenes:
#   - Inline diff expansion (unstaged employees changes)
#   - Stash (unstaged changes before merge)
#   - Stage + commit (employees + tasks table)
#   - Log with graph (diverged branches)
#   - Merge with conflict (departments budget on both branches)
#   - Conflict resolution
#   - Interactive rebase (squash fix-typo, reorder)
#   - Blame, SQL query, SQL server, refs, branch creation

set -e

DEMO_DIR="${1:-/tmp/madolt-demo-db}"

rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

dolt init

# ============================================================
# Commit 1: Initial schema — employees and departments
# ============================================================
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

# ============================================================
# Commit 2: Add more employees
# ============================================================
dolt sql -q "INSERT INTO employees VALUES
  (4, 'Diana Lopez',   'diana@example.com', 'Sales',       'Account Executive', 68000.00, '2024-02-20', 'Chicago',       '555-0104'),
  (5, 'Erik Johnson',  'erik@example.com',  'Engineering', 'Principal Engineer',110000.00, '2020-11-05', 'San Francisco', '555-0105')"
dolt add .
dolt commit -m "Add new hires Diana and Erik"

# ============================================================
# Tag v0.1 — first milestone
# ============================================================
dolt tag v0.1 -m "First milestone"

# ============================================================
# Feature branch: diverges here, adds projects + modifies departments
# ============================================================
dolt checkout -b feature/projects

# Feature commit 1: Add projects table
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
dolt add .
dolt commit -m "Add projects table"

# Feature commit 2: Increase Engineering budget (CONFLICTS with main)
dolt sql -q "UPDATE departments SET budget = 700000.00, head_count = 15 WHERE name = 'Engineering'"
dolt add .
dolt commit -m "Increase Engineering budget for new projects"

# ============================================================
# Back to main: add commits after divergence (non-ff merge, graph)
# ============================================================
dolt checkout main

# Commit 3: Update Engineering budget differently (CONFLICTS with feature)
dolt sql -q "UPDATE departments SET budget = 600000.00 WHERE name = 'Engineering'"
dolt add .
dolt commit -m "Q2 budget adjustment for Engineering"

# Commit 4: Promote Alice (good data for blame + inline diff)
dolt sql -q "UPDATE employees SET salary = 105000.00, title = 'Staff Engineer' WHERE name = 'Alice Chen'"
dolt add .
dolt commit -m "Promote Alice Chen to Staff Engineer"

# Commit 5: Fix a typo — intentionally small for rebase squash demo
dolt sql -q "UPDATE employees SET email = 'alice.chen@example.com' WHERE name = 'Alice Chen'"
dolt add .
dolt commit -m "Fix typo in Alice's email"

# Commit 6: Add Sales headcount — another small commit for rebase reorder
dolt sql -q "UPDATE departments SET head_count = 10 WHERE name = 'Sales'"
dolt add .
dolt commit -m "Update Sales headcount"

# ============================================================
# Working state for the demo opening
# ============================================================

# Unstaged: salary raises for two employees (Scene 3 diff expansion)
dolt sql -q "UPDATE employees SET salary = 115000.00, title = 'Senior Staff Engineer' WHERE name = 'Carol Williams'"
dolt sql -q "UPDATE employees SET salary = 75000.00 WHERE name = 'Bob Martinez'"

# Unstaged: departments changes (persist after Scene 4 commit, used for
# stash demo in Scene 6 and must be stashed before merge in Scene 7)
dolt sql -q "UPDATE departments SET budget = 250000.00, head_count = 8 WHERE name = 'Marketing'"

# Untracked: new tasks table (Scene 4 staging)
dolt sql -q "CREATE TABLE tasks (
  id INT PRIMARY KEY,
  title VARCHAR(200),
  assignee_id INT,
  status VARCHAR(20),
  priority VARCHAR(10),
  created DATE
)"
dolt sql -q "INSERT INTO tasks VALUES
  (1, 'Set up CI pipeline',     5, 'in_progress', 'high',   '2025-03-01'),
  (2, 'Write onboarding docs',  2, 'open',        'medium', '2025-03-05'),
  (3, 'Database backup script',  3, 'open',        'high',   '2025-03-10')"

# Configure a remote for the refs display
dolt remote add origin aspiers/madolt-demo-db

echo "Demo repo ready at $DEMO_DIR"
echo ""
dolt status
